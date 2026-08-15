import Foundation
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// F5 — CavityIntegrator: cuantificación de daño = "volumen faltante respecto de la
// superficie original". Tres niveles de referencia, con trazabilidad distinta y
// `isInferred` poblado correctamente en cada uno:
//   1. priorScan  → diff contra escaneo previo de la pieza intacta  (medición).
//   2. plane/quadric → superficie de referencia ajustada al anillo intacto
//      (inferencia).
//   3. mirror     → completado por simetría bilateral                  (inferencia).
// Presentar una inferencia como medición es el mayor riesgo legal del módulo:
// `isInferred` es el guardián.
// ═══════════════════════════════════════════════════════════════════════════════

public struct CavityIntegrator: VolumeIntegrating {
    public static var algorithmVersion: String { "1.0.0" }

    /// Método de inferencia usado. Poblado por el enrutador y reportado en el
    /// `VolumeResult`.
    public enum InferenceSource: String, Sendable {
        case none
        case rimFit
        case mirrorSymmetry
    }

    public init() {}

    public func integrate(
        mesh: Mesh,
        reference: ReferenceSurface,
        cellSize: Float,
        emptyCells: EmptyCellStrategy
    ) throws(VolumeError) -> VolumeResult {
        guard !mesh.isEmpty else { throw .emptyMesh }
        guard cellSize > 0, cellSize.isFinite else { throw .invalidCellSize(cellSize) }

        switch reference {
        case .priorScan(let prior, let alignment):
            return try integrateAgainstPrior(
                damaged: mesh, prior: prior, alignment: alignment, cellSize: cellSize
            )

        case .plane(let plane):
            // Anillo intacto: superficie de referencia plana ajustada a la corona.
            return try integrateAgainstSurface(
                damaged: mesh, plane: plane, cellSize: cellSize, method: .cavityRimFit
            )

        case .quadric(let quadric):
            return try integrateAgainstQuadric(
                damaged: mesh, quadric: quadric, cellSize: cellSize, method: .cavityRimFit
            )

        case .mirror(let plane):
            return try integrateByMirror(
                damaged: mesh, plane: plane, cellSize: cellSize
            )

        case .closedSolid:
            throw .invalidReferenceSurface("cavity requiere una referencia exterior")
        }
    }

    // MARK: - Nivel 1: diff contra escaneo previo (medición)

    /// El escaneo previo se alinea con `alignment` (la pose del daño respecto del
    /// registro preventivo) y se calcula la diferencia de alturas firmada por celda.
    /// Positivo = material acumulado; negativo = material faltante (la cavidad).
    private func integrateAgainstPrior(
        damaged: Mesh,
        prior: Mesh,
        alignment: Matrix4x4,
        cellSize: Float
    ) throws(VolumeError) -> VolumeResult {
        guard !prior.isEmpty else { throw .notEnoughData("escaneo previo vacío") }

        // Plano de apoyo: el plano dominante del prior (nube intacta).
        let points = Array(prior.vertices.prefix(min(prior.vertices.count, 2000)))
        guard points.count >= 3 else { throw .notEnoughData("prior sin vértices suficientes") }
        let mean = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let normal = Self.bestFitNormal(points, mean)

        let plane: Plane
        do {
            plane = try Plane(point: mean, normal: normal)
        } catch {
            throw .invalidReferenceSurface("plano de apoyo degenerado")
        }
        let u = Self.orthonormalBasis(plane.normal).0
        let v = Self.orthonormalBasis(plane.normal).1
        let n = plane.normal

        // Grilla de alturas del prior (intacto) y del dañado, alineado.
        let priorEnv = Self.rasterize(prior, plane: plane, cellSize: cellSize)
        var priorUpper = priorEnv.upper
        let damagedTransformed = Mesh(
            vertices: damaged.vertices.map { alignment.applyAffine($0) },
            indices: damaged.indices
        )
        let damagedEnv = Self.rasterize(damagedTransformed, plane: plane, cellSize: cellSize)
        var damagedUpper = damagedEnv.upper
        var damagedLower = damagedEnv.lower

        // Cavidad = celdas donde el intacto supera al dañado.
        var cavityVolume: Double = 0
        var positiveVolume: Double = 0
        var covered = Set<Int64>()
        for (key, priorH) in priorUpper {
            covered.insert(key)
            let damagedH = damagedUpper[key] ?? damagedLower[key] ?? 0
            let diff = priorH - damagedH
            if diff > 0 {
                cavityVolume += diff
            } else {
                positiveVolume += -diff
            }
        }
        // Celdas donde el daño extiende bajo la huella del prior (p. ej. desbordes).
        for key in damagedLower.keys where priorUpper[key] == nil {
            covered.insert(key)
            cavityVolume += -damagedLower[key]!
        }
        let cellArea = Double(cellSize) * Double(cellSize)

        return VolumeResult(
            positive: positiveVolume * cellArea,
            negative: cavityVolume * cellArea,
            coveredArea: Double(covered.count) * cellArea,
            filledCellRatio: 1,
            uncertainty: 0,
            method: .cavityDiff,
            isInferred: false,
            algorithmVersion: Self.algorithmVersion
        )
    }

    // MARK: - Nivel 2: superficie de referencia plana/cuádrica al anillo intacto

    private func integrateAgainstSurface(
        damaged: Mesh,
        plane: Plane,
        cellSize: Float,
        method: VolumeMethod
    ) throws(VolumeError) -> VolumeResult {
        // La cavidad es el volumen entre la superficie intacta (plano) y la malla dañada.
        let env = Self.rasterize(damaged, plane: plane, cellSize: cellSize)
        let upper = env.upper
        let lower = env.lower

        // Inferencia: el anillo intacto define el nivel original (aquí el plano).
        // La cavidad es `-lower` (material que falta bajo la superficie original).
        var cavity: Double = 0
        var positive: Double = 0
        var covered = Set<Int64>()
        for (key, h) in lower {
            covered.insert(key)
            cavity += -h
        }
        for (key, h) in upper {
            covered.insert(key)
            positive += h
        }
        let cellArea = Double(cellSize) * Double(cellSize)
        return VolumeResult(
            positive: positive * cellArea,
            negative: cavity * cellArea,
            coveredArea: Double(covered.count) * cellArea,
            filledCellRatio: 1,
            uncertainty: Double(cellSize) * 0.5,
            method: method,
            isInferred: true,
            algorithmVersion: Self.algorithmVersion
        )
    }

    private func integrateAgainstQuadric(
        damaged: Mesh,
        quadric: QuadricSurface,
        cellSize: Float,
        method: VolumeMethod
    ) throws(VolumeError) -> VolumeResult {
        // Frame local de la cuádrica: transformar vértices a su sistema (u,v,h).
        let frame = quadric.frame
        let inv = frame.rigidInverse()
        let c = quadric.coefficients
        let uAxis = inv[0].xyz
        let vAxis = inv[1].xyz

        var lower: [Int64: Double] = [:]
        for p in damaged.vertices {
            let local = inv.applyAffine(p)
            let key = Self.cellKey(vecDot(local, uAxis), vecDot(local, vAxis), cellSize)
            let u = Double(vecDot(local, uAxis))
            let vv = Double(vecDot(local, vAxis))
            let surfaceH = c[0] * u * u + c[1] * vv * vv + c[2] * u * vv + c[3] * u + c[4] * vv + c[5]
            let h = Double(local.y) - surfaceH
            if h < 0 {
                lower[key] = min(lower[key] ?? 0, h)
            }
        }
        var cavity: Double = 0
        for (_, h) in lower {
            cavity += -h
        }
        let cellArea = Double(cellSize) * Double(cellSize)
        return VolumeResult(
            positive: 0,
            negative: cavity * cellArea,
            coveredArea: Double(lower.count) * cellArea,
            filledCellRatio: 1,
            uncertainty: Double(cellSize) * 0.5,
            method: method,
            isInferred: true,
            algorithmVersion: Self.algorithmVersion
        )
    }

    // MARK: - Nivel 3: completado por simetría

    /// Completa por simetría bilateral. El plano de apoyo de la superficie (no el
    /// plano de simetría) define la grilla: la cavidad se mide como la altura que
    /// falta entre la reconstrucción especular y la superficie dañada, celda a
    /// celda sobre el footprint común. Un diff negativo (el espejo muestra el
    /// mordisco pero el real está intacto) es un artefacto y se ignora.
    private func integrateByMirror(
        damaged: Mesh,
        plane: Plane,
        cellSize: Float
    ) throws(VolumeError) -> VolumeResult {
        // Reflejar la malla dañada sobre el plano de simetría: reconstruye el lado sano.
        var mirrored: [SIMD3<Float>] = []
        mirrored.reserveCapacity(damaged.vertices.count)
        for p in damaged.vertices {
            let off = p - plane.point
            let h = vecDot(off, plane.normal)
            let reflected = p - 2 * h * plane.normal
            mirrored.append(reflected)
        }
        let mirroredMesh = Mesh(vertices: mirrored, indices: damaged.indices)

        // Plano de apoyo: el plano dominante de la superficie dañada (footprint).
        let points = Array(damaged.vertices.prefix(min(damaged.vertices.count, 2000)))
        guard points.count >= 3 else { throw .notEnoughData("superficie sin vértices suficientes") }
        let mean = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        let normal = Self.bestFitNormal(points, mean)
        let support: Plane
        do {
            support = try Plane(point: mean, normal: normal)
        } catch {
            throw .invalidReferenceSurface("plano de apoyo degenerado")
        }

        // Grilla de alturas de la reconstrucción especular y de la superficie dañada.
        let healthyEnv = Self.rasterize(mirroredMesh, plane: support, cellSize: cellSize)
        let damagedEnv = Self.rasterize(damaged, plane: support, cellSize: cellSize)

        // Altura de superficie por celda: la envolvente superior si está sobre el
        // plano de apoyo, la inferior si está bajo él (p. ej. el mordisco).
        var healthyH = healthyEnv.upper
        for (key, h) in healthyEnv.lower { healthyH[key] = min(healthyH[key] ?? 0, h) }
        var damagedH = damagedEnv.upper
        for (key, h) in damagedEnv.lower { damagedH[key] = min(damagedH[key] ?? 0, h) }

        // Cavidad = material que falta: lo que la reconstrucción tiene y el dañado no.
        var cavity: Double = 0
        var covered = Set<Int64>()
        for (key, hh) in healthyH {
            covered.insert(key)
            let dh = damagedH[key] ?? 0
            let diff = hh - dh
            if diff > 0 { cavity += diff }
        }
        let cellArea = Double(cellSize) * Double(cellSize)
        return VolumeResult(
            positive: 0,
            negative: cavity * cellArea,
            coveredArea: Double(covered.count) * cellArea,
            filledCellRatio: 1,
            uncertainty: Double(cellSize) * 0.5,
            method: .mirrorSymmetry,
            isInferred: true,
            algorithmVersion: Self.algorithmVersion
        )
    }

    // MARK: - Helpers

    /// Clave de celda a partir de dos coordenadas en el plano.
    private static func cellKey(_ u: Float, _ v: Float, _ cellSize: Float) -> Int64 {
        let i = Int64(floor(Double(u) / Double(cellSize)))
        let j = Int64(floor(Double(v) / Double(cellSize)))
        return (i << 21) ^ j
    }

    private static func orthonormalBasis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let ref: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = vecNormalize(vecCross(ref, n))
        let v = vecNormalize(vecCross(n, u))
        return (u, v)
    }

    /// Rasteriza la malla sobre el plano de referencia: devuelve las envolventes
    /// superior e inferior (alturas firmadas, ±). Interpola la altura firmada sobre
    /// el footprint 2D de cada triángulo para no perder cobertura cuando `cellSize`
    /// es más fino que la densidad de vértices.
    private static func rasterize(
        _ mesh: Mesh,
        plane: Plane,
        cellSize: Float
    ) -> (upper: [Int64: Double], lower: [Int64: Double]) {
        var upper: [Int64: Double] = [:]
        var lower: [Int64: Double] = [:]
        let u = Self.orthonormalBasis(plane.normal).0
        let v = Self.orthonormalBasis(plane.normal).1
        let n = plane.normal
        let origin = plane.point

        // 1) Vértices.
        for p in mesh.vertices {
            let off = p - origin
            let h = Double(vecDot(off, n))
            let key = Self.cellKey(vecDot(off, u), vecDot(off, v), cellSize)
            if h >= 0 {
                upper[key] = max(upper[key] ?? 0, h)
            } else {
                lower[key] = min(lower[key] ?? 0, h)
            }
        }

        // 2) Triángulos: interpolar la altura firmada sobre la celda.
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[t])
            let ib = Int(mesh.indices[t + 1])
            let ic = Int(mesh.indices[t + 2])
            guard ia < mesh.vertices.count, ib < mesh.vertices.count, ic < mesh.vertices.count else {
                continue
            }
            let a = Self.proj(mesh.vertices[ia], origin: origin, u: u, v: v, n: n, cellSize: cellSize)
            let b = Self.proj(mesh.vertices[ib], origin: origin, u: u, v: v, n: n, cellSize: cellSize)
            let c = Self.proj(mesh.vertices[ic], origin: origin, u: u, v: v, n: n, cellSize: cellSize)

            let loI = min(a.i, min(b.i, c.i))
            let hiI = max(a.i, max(b.i, c.i))
            let loJ = min(a.j, min(b.j, c.j))
            let hiJ = max(a.j, max(b.j, c.j))

            for i in loI...hiI {
                for j in loJ...hiJ {
                    let cx = (Double(i) + 0.5) * Double(cellSize)
                    let cy = (Double(j) + 0.5) * Double(cellSize)
                    guard Self.pointInTriangle(cx, cy, a, b, c) else { continue }
                    let h = Self.interpolatedHeight(cx, cy, a, b, c)
                    let key = Self.cellKey(Float(cx), Float(cy), cellSize)
                    if h >= 0 {
                        upper[key] = max(upper[key] ?? 0, h)
                    } else {
                        lower[key] = min(lower[key] ?? 0, h)
                    }
                }
            }
        }
        return (upper, lower)
    }

    private struct P {
        let i: Int64
        let j: Int64
        let u: Double
        let v: Double
        let h: Double
    }

    private static func proj(_ p: SIMD3<Float>, origin: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>, cellSize: Float) -> P {
        let off = p - origin
        let uu = Double(vecDot(off, u))
        let vv = Double(vecDot(off, v))
        let h = Double(vecDot(off, n))
        return P(i: Int64(floor(uu / Double(cellSize))), j: Int64(floor(vv / Double(cellSize))), u: uu, v: vv, h: h)
    }

    private static func interpolatedHeight(_ px: Double, _ py: Double, _ a: P, _ b: P, _ c: P) -> Double {
        let d = (b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u)
        guard abs(d) > 1e-12 else { return 0 }
        let A = ((b.h - a.h) * (c.v - a.v) - (b.v - a.v) * (c.h - a.h)) / d
        let B = ((b.u - a.u) * (c.h - a.h) - (b.h - a.h) * (c.u - a.u)) / d
        let C = a.h - A * a.u - B * a.v
        return A * px + B * py + C
    }

    private static func pointInTriangle(_ px: Double, _ py: Double, _ a: P, _ b: P, _ c: P) -> Bool {        func sign(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x3: Double, _ y3: Double) -> Double {
            (x1 - x3) * (y2 - y3) - (x2 - x3) * (y1 - y3)
        }
        let d1 = sign(px, py, a.u, a.v, b.u, b.v)
        let d2 = sign(px, py, b.u, b.v, c.u, c.v)
        let d3 = sign(px, py, c.u, c.v, a.u, a.v)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }

    /// Normal dominante por PCA de la nube de puntos. Iteración inversa para el
    /// autovector **menor** (la normal de la superficie): la iteración de potencias
    /// estándar converge al mayor (una dirección tangencial), lo que rompería el
    /// plano de apoyo.
    private static func bestFitNormal(_ points: [SIMD3<Float>], _ mean: SIMD3<Float>) -> SIMD3<Float> {
        var cov = [Double](repeating: 0, count: 9)
        for p in points {
            let d = p - mean
            cov[0] += Double(d.x * d.x)
            cov[1] += Double(d.x * d.y)
            cov[2] += Double(d.x * d.z)
            cov[4] += Double(d.y * d.y)
            cov[5] += Double(d.y * d.z)
            cov[8] += Double(d.z * d.z)
        }
        cov[3] = cov[1]
        cov[6] = cov[2]
        cov[7] = cov[5]

        // Invertir la matriz de covarianza con un pequeño shift y aplicar iteración
        // inversa: (M + εI)^-1 amplifica la dirección de menor varianza.
        let epsilon = 1e-6
        var m = cov
        for k in 0..<3 { m[k * 3 + k] += epsilon }

        var v = SIMD3<Double>(0, 1, 0)
        for _ in 0..<40 {
            let x = Self.solve3x3(m, v)
            let len = (x.x * x.x + x.y * x.y + x.z * x.z).squareRoot()
            if len > 1e-12 { v = x / len }
        }
        return SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
    }

    /// Resuelve `A · x = b` para una matriz 3×3 por Cramer.
    private static func solve3x3(_ a: [Double], _ b: SIMD3<Double>) -> SIMD3<Double> {
        let det = a[0] * (a[4] * a[8] - a[5] * a[7])
            - a[1] * (a[3] * a[8] - a[5] * a[6])
            + a[2] * (a[3] * a[7] - a[4] * a[6])
        guard abs(det) > 1e-18 else { return b }
        let ax = SIMD3<Double>(a[0], a[3], a[6])
        let ay = SIMD3<Double>(a[1], a[4], a[7])
        let az = SIMD3<Double>(a[2], a[5], a[8])
        let bxc = SIMD3<Double>(ay.y * az.z - ay.z * az.y, ay.z * az.x - ay.x * az.z, ay.x * az.y - ay.y * az.x)
        return SIMD3<Double>(dot3(b, bxc) / det, dot3(ax, cross3(b, az)) / det, dot3(ax, cross3(ay, b)) / det)
    }

    private static func dot3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross3(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}