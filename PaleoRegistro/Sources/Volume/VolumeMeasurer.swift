import Foundation
import Domain
import Mesh
import Geometry

// ═══════════════════════════════════════════════════════════════════════════════
// F5/F14 — VolumeMeasurer: la medición de volumen que ve el operador en la ficha.
// Recorta la malla a la caja (ROIFilter), ajusta la referencia a la franja
// exterior de la caja y elige el integrador según el propósito (VolumePolicy).
//
// Medido vs. inferido (plan §2.C.2), decidido aquí y no en la UI:
//   - campo de alturas sobre el suelo             → medido
//   - sólido cerrado, la malla ya era estanca     → medido
//   - sólido cerrado, hubo que tapar bordes       → INFERIDO (la base no se vio)
//   - cavidad contra superficie ajustada al borde → INFERIDO (la original no existe)
// ═══════════════════════════════════════════════════════════════════════════════

/// Lo que se guarda en `measurements/MSR-….json` y se sella.
public struct VolumeMeasurement: Sendable, Codable, Equatable {
    public var measurementID: UUID
    public var scanID: UUID
    public var measuredAt: Date
    /// Caja usada para recortar la malla (marco de mundo de la captura, +Y arriba).
    public var region: OrientedBox
    /// Suelo o superficie intacta ajustada a la franja exterior de la caja.
    public var reference: Plane?
    public var result: VolumeResult
    /// Lo que se informa; cada valor con su propio `isInferred`.
    public var measurements: [Measurement]

    public var isInferred: Bool { measurements.contains { $0.isInferred } }
}

public enum VolumeMeasurer {

    public static let algorithmVersion = "1.0.0"

    /// Franja exterior de la caja (fracción de la semi-extensión horizontal) donde
    /// se busca el suelo o la superficie intacta.
    public static let rimFraction: Float = 0.7

    /// - Parameter region: caja alineada con la gravedad: `axes[1]` es la vertical;
    ///   `axes[0]` y `axes[2]` son horizontales.
    public static func measure(
        mesh: Mesh,
        region: OrientedBox,
        purpose: ScanPurpose,
        scanID: UUID,
        cellSize: Float = 0.01,
        clock: Date = Date()
    ) throws(VolumeError) -> VolumeMeasurement {
        let roi = ROIFilter().filter(mesh: mesh, to: region)
        guard roi.triangleCount > 0 else {
            throw .notEnoughData("No hay malla dentro de la caja.")
        }
        let (rim, inner) = splitRim(roi.vertices, region: region)

        func volume(_ value: Double, _ label: String, inferred: Bool, _ result: VolumeResult,
                    _ assumptions: [String]) -> Measurement {
            Measurement(scanID: scanID, kind: .volume, value: value, unit: "m3",
                        method: "\(result.method.rawValue) \(result.algorithmVersion), medidor \(algorithmVersion)",
                        isInferred: inferred, uncertainty: result.uncertainty,
                        assumptions: assumptions, label: label)
        }

        switch VolumePolicy.route(for: purpose) {
        case .heightField:
            let ground = try groundPlane(rim)
            let r = try SignedHeightFieldIntegrator().integrate(
                mesh: roi, reference: .plane(ground), cellSize: cellSize, emptyCells: .ignore)
            let note = ["Referencia: plano del suelo ajustado a la franja exterior de la caja.",
                        "Las zonas sin malla no se rellenan: si faltan partes, el volumen queda corto."]
            return VolumeMeasurement(
                measurementID: UUID(), scanID: scanID, measuredAt: clock, region: region, reference: ground,
                result: r, measurements: [
                    volume(r.positive, "Volumen sobre el suelo", inferred: false, r, note),
                    volume(r.negative, "Volumen bajo el suelo", inferred: false, r, note),
                ])

        case .closedMesh:
            let before = MeshOps().watertightness(roi)
            var solid = roi
            var assumptions: [String] = []
            var ground: Plane?
            if !before.isWatertight {
                let plane = try groundPlane(rim)
                ground = plane
                do { solid = try MeshCloser().close(mesh: roi, against: plane).mesh }
                catch { throw .meshNotClosed }
                assumptions.append("La malla tenía \(before.boundaryEdges) aristas abiertas (por ejemplo, la cara apoyada en el suelo, que la cámara no ve). Se taparon contra el plano del suelo: el volumen supone esa forma.")
            }
            let r = try ClosedMeshIntegrator().integrate(
                mesh: solid, reference: .closedSolid, cellSize: cellSize, emptyCells: .ignore)
            return VolumeMeasurement(
                measurementID: UUID(), scanID: scanID, measuredAt: clock, region: region, reference: ground,
                result: r, measurements: [
                    // El signo depende de la orientación de las caras, no del objeto.
                    volume(abs(r.positive), "Volumen del objeto", inferred: !before.isWatertight, r, assumptions),
                ])

        case .cavity:
            let rimSurface = try intactSurface(rim, inner: inner)
            let r = try CavityIntegrator().integrate(
                mesh: roi, reference: .plane(rimSurface), cellSize: cellSize, emptyCells: .ignore)
            return VolumeMeasurement(
                measurementID: UUID(), scanID: scanID, measuredAt: clock, region: region, reference: rimSurface,
                result: r, measurements: [
                    volume(r.negative, "Volumen faltante (daño)", inferred: true, r, [
                        "La superficie original no existe: se supuso plana, ajustada a la franja exterior de la caja (zona intacta alrededor del daño).",
                    ]),
                ])
        }
    }

    // MARK: - Referencias

    /// Separa los vértices de la franja exterior horizontal de la caja (`rim`)
    /// de los del centro (`inner`).
    static func splitRim(_ points: [SIMD3<Float>], region: OrientedBox)
        -> (rim: [SIMD3<Float>], inner: [SIMD3<Float>]) {
        let h = region.halfExtents
        guard h.x > 0, h.z > 0 else { return ([], points) }
        var rim: [SIMD3<Float>] = [], inner: [SIMD3<Float>] = []
        for p in points {
            let d = p - region.center
            let u = abs(vecDot(d, region.axes[0])) / h.x
            let w = abs(vecDot(d, region.axes[2])) / h.z
            if max(u, w) >= rimFraction { rim.append(p) } else { inner.append(p) }
        }
        return (rim, inner)
    }

    /// Suelo: plano casi horizontal (≤ 20°) con la normal hacia arriba.
    static func groundPlane(_ rim: [SIMD3<Float>]) throws(VolumeError) -> Plane {
        let plane = try fit(rim, constraint: .horizontal(maxTiltDegrees: 20),
                            missing: "No se encontró el suelo en el borde de la caja. Agrándala para que incluya una franja de suelo alrededor del objeto.")
        return plane.normal.y < 0 ? flipped(plane) : plane
    }

    /// Superficie intacta alrededor del daño, orientada hacia afuera: el interior
    /// (donde falta material) queda en promedio por debajo del plano.
    static func intactSurface(_ rim: [SIMD3<Float>], inner: [SIMD3<Float>]) throws(VolumeError) -> Plane {
        let plane = try fit(rim, constraint: .none,
                            missing: "No se encontró superficie intacta en el borde de la caja. Agrándala para que el daño quede rodeado de superficie sana.")
        let sum = inner.reduce(0.0) { $0 + Double(vecDot($1 - plane.point, plane.normal)) }
        return sum > 0 ? flipped(plane) : plane
    }

    private static func fit(_ points: [SIMD3<Float>], constraint: OrientationConstraint,
                            missing: String) throws(VolumeError) -> Plane {
        guard points.count >= 3 else { throw .notEnoughData(missing) }
        let options = PlaneFitOptions(inlierDistance: 0.02, minInliers: min(50, max(3, points.count / 4)),
                                      constraint: constraint)
        do { return try RANSACPlaneFitter().fit(points: points, normals: nil, options: options) }
        catch { throw .notEnoughData(missing) }
    }

    private static func flipped(_ plane: Plane) -> Plane {
        (try? Plane(point: plane.point, normal: -plane.normal,
                    inlierRMS: plane.inlierRMS, inlierCount: plane.inlierCount)) ?? plane
    }
}
