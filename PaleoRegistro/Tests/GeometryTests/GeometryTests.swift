import Testing
import Foundation
import Domain

@testable import Geometry

// ═══════════════════════════════════════════════════════════════════════════════
// F2 — Criterios de aceptación: todo con verdad sintética, sin dispositivo.
// ═══════════════════════════════════════════════════════════════════════════════

/// Generadores de verdad sintética para Geometry.
enum SyntheticGeometry {
    /// Puntos sobre un plano con ruido gaussiano isotrópico.
    static func planePoints(
        center: SIMD3<Float>,
        normal: SIMD3<Float>,
        uExtent: Float,
        vExtent: Float,
        count: Int,
        noiseSigma: Float = 0,
        seed: UInt64 = 1
    ) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: seed)
        let basis = Rectifier.makeBasis(plane: try! Plane(point: center, normal: normal))
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let ru = Float.random(in: -0.5...0.5, using: &rng)
            let rv = Float.random(in: -0.5...0.5, using: &rng)
            let g = gaussianNoise(rng: &rng)
            let p = center
                + basis.u * (ru * uExtent)
                + basis.v * (rv * vExtent)
                + normal * (g * noiseSigma)
            result.append(p)
        }
        return result
    }

    /// Ruido gaussiano (Box–Muller) a partir de un RNG determinista.
    static func gaussianNoise(rng: inout SplitMix64) -> Float {
        let u1 = Float.random(in: 0.0001...1, using: &rng)
        let u2 = Float.random(in: 0.0001...1, using: &rng)
        return (-2 * Foundation.log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// Caja de esquinas centradas, sin rotación, con resolución de muestreo.
    static func boxPoints(half: SIMD3<Float>, perEdge: Int = 4) -> [SIMD3<Float>] {
        var pts: [SIMD3<Float>] = []
        let corners = [
            SIMD3<Float>(-1,-1,-1), SIMD3<Float>(1,-1,-1), SIMD3<Float>(1,1,-1), SIMD3<Float>(-1,1,-1),
            SIMD3<Float>(-1,-1,1), SIMD3<Float>(1,-1,1), SIMD3<Float>(1,1,1), SIMD3<Float>(-1,1,1),
        ]
        let edges: [(Int, Int)] = [
            (0,1),(1,2),(2,3),(3,0),
            (4,5),(5,6),(6,7),(7,4),
            (0,4),(1,5),(2,6),(3,7),
        ]
        var seen = Set<Int>()
        func add(_ idx: Int) {
            guard !seen.contains(idx) else { return }
            seen.insert(idx)
            pts.append(corners[idx] * half)
        }
        for (a, b) in edges {
            add(a); add(b)
            for k in 1..<perEdge {
                let t = Float(k) / Float(perEdge)
                pts.append((corners[a] + (corners[b] - corners[a]) * t) * half)
            }
        }
        return pts
    }

    /// Aplica una rotación de yaw (alrededor de Y) y pitch (alrededor de X).
    static func rotate(_ points: [SIMD3<Float>], yawDegrees: Float, pitchDegrees: Float) -> [SIMD3<Float>] {
        let r = rotationMatrix(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees)
        return points.map { r * $0 }
    }

    /// Matriz de rotación (columnas = ejes rotados de la base canónica).
    static func rotationMatrix(yawDegrees: Float, pitchDegrees: Float) -> Matrix3x3 {
        let yaw = yawDegrees * .pi / 180
        let pitch = pitchDegrees * .pi / 180
        let cy = cos(yaw); let sy = sin(yaw)
        let cp = cos(pitch); let sp = sin(pitch)
        return Matrix3x3(
            SIMD3(cy, 0, -sy),
            SIMD3(sy * sp, cp, cy * sp),
            SIMD3(sy * cp, -sp, cy * cp)
        )
    }
}

@Suite("F2 Geometry: ajuste de planos")
struct PlaneFittingTests {

    @Test("Test crítico: restricción vertical gana al muro aunque el piso tenga más puntos")
    func verticalConstraintPicksWall() throws {
        // Piso horizontal: 800 puntos. Muro vertical: 300 puntos.
        let piso = SyntheticGeometry.planePoints(
            center: SIMD3<Float>(0, 0, 0), normal: SIMD3<Float>(0, 1, 0),
            uExtent: 4, vExtent: 4, count: 800, noiseSigma: 0.003, seed: 7
        )
        let muro = SyntheticGeometry.planePoints(
            center: SIMD3<Float>(0, 0, 0), normal: SIMD3<Float>(1, 0, 0),
            uExtent: 4, vExtent: 4, count: 300, noiseSigma: 0.003, seed: 11
        )
        let nube = piso + muro

        let fitter = RANSACPlaneFitter()
        let plane = try fitter.fit(
            points: nube,
            normals: nil,
            options: PlaneFitOptions(
                maxIterations: 4000,
                inlierDistance: 0.01,
                minInliers: 200,
                constraint: .vertical(maxTiltDegrees: 5),
                scoring: .msac,
                rngSeed: 42
            )
        )

        // Debe ser el muro (normal ≈ X), no el piso (normal ≈ Y).
        let angle = acos(abs(vecDot(plane.normal, SIMD3<Float>(1, 0, 0))))
        #expect(angle * 180 / .pi < 0.5)
        #expect(abs(vecDot(plane.normal, SIMD3<Float>(0, 1, 0))) < 0.05)

        // Offset al origen del muro < 5 mm.
        let offset = abs(vecDot(plane.point, plane.normal))
        #expect(offset < 0.005)
    }

    @Test("Plano inclinado con 20% de outliers en un segundo plano")
    func inclinedPlaneWithOutliers() throws {
        let trueNormal = vecNormalize(SIMD3<Float>(0.3, 0.9, 0.2))
        let main = SyntheticGeometry.planePoints(
            center: SIMD3<Float>(0, 1, 0), normal: trueNormal,
            uExtent: 3, vExtent: 3, count: 800, noiseSigma: 0.002, seed: 5
        )
        let outliers = SyntheticGeometry.planePoints(
            center: SIMD3<Float>(0, -2, 0), normal: SIMD3<Float>(0, 0, 1),
            uExtent: 2, vExtent: 2, count: 200, noiseSigma: 0.002, seed: 9
        )
        let nube = main + outliers

        let fitter = RANSACPlaneFitter()
        let plane = try fitter.fit(
            points: nube,
            normals: nil,
            options: PlaneFitOptions(
                maxIterations: 4000,
                inlierDistance: 0.01,
                minInliers: 300,
                constraint: .nearNormal(trueNormal, toleranceDegrees: 8),
                scoring: .msac,
                rngSeed: 99
            )
        )

        let angle = acos(abs(vecDot(plane.normal, trueNormal)))
        #expect(angle * 180 / .pi < 0.5)
        let offset = abs(vecDot(plane.point - SIMD3(0, 1, 0), trueNormal))
        #expect(offset < 0.005)
    }

    @Test("Determinismo: 50 corridas con misma semilla idénticas bit a bit")
    func determinismSameSeed() throws {
        let points = SyntheticGeometry.planePoints(
            center: SIMD3<Float>(0, 2, 0), normal: SIMD3<Float>(0, 1, 0),
            uExtent: 3, vExtent: 2, count: 500, noiseSigma: 0.004, seed: 13
        )
        let fitter = RANSACPlaneFitter()
        let options = PlaneFitOptions(
            maxIterations: 1000, inlierDistance: 0.01, minInliers: 200,
            constraint: .none, scoring: .msac, rngSeed: 0xDEADBEEF
        )

        var firstCanonical: Data?
        for _ in 0..<50 {
            let plane = try fitter.fit(points: points, normals: nil, options: options)
            let canonical = Self.canonicalPlaneBytes(plane)
            if let firstCanonical {
                #expect(canonical == firstCanonical)
            } else {
                firstCanonical = canonical
            }
        }
    }

    /// Serialización canónica del plano: bits de cada campo en orden fijo.
    private static func canonicalPlaneBytes(_ p: Plane) -> Data {
        var data = Data()
        for v in [p.point.x, p.point.y, p.point.z, p.normal.x, p.normal.y, p.normal.z] {
            withUnsafeBytes(of: v.bitPattern) { data.append(contentsOf: $0) }
        }
        let rms = p.inlierRMS ?? -Float.infinity
        let count = p.inlierCount ?? -1
        withUnsafeBytes(of: rms.bitPattern) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: count) { data.append(contentsOf: $0) }
        return data
    }

    @Test("Semillas distintas producen resultados que difieren menos que la tolerancia")
    func differentSeedsWithinTolerance() throws {
        let trueNormal = SIMD3<Float>(0, 1, 0)
        let points = SyntheticGeometry.planePoints(
            center: SIMD3<Float>(0, 2, 0), normal: trueNormal,
            uExtent: 3, vExtent: 2, count: 500, noiseSigma: 0.004, seed: 13
        )
        let fitter = RANSACPlaneFitter()
        var fits: [Plane] = []
        for seed: UInt64 in [1, 2, 3, 4, 5, 6, 7] {
            let plane = try fitter.fit(
                points: points, normals: nil,
                options: PlaneFitOptions(
                    maxIterations: 1000, inlierDistance: 0.01, minInliers: 200,
                    constraint: .none, scoring: .msac, rngSeed: seed
                )
            )
            fits.append(plane)
        }
        for a in fits {
            for b in fits {
                let angle = acos(min(1, abs(vecDot(a.normal, b.normal))))
                let offset = abs(vecDot(a.point - b.point, a.normal))
                #expect(angle * 180 / .pi < 0.5)
                #expect(offset < 0.005)
            }
        }
        _ = trueNormal
    }

    @Test("Puntos sobre una esfera: sin consenso, error tipado")
    func sphereNoConsensus() {
        var rng = SplitMix64(seed: 1)
        var sphere: [SIMD3<Float>] = []
        for _ in 0..<400 {
            let u = Float.random(in: 0...1, using: &rng)
            let v = Float.random(in: 0...1, using: &rng)
            let theta = 2 * .pi * u
            let phi = acos(2 * v - 1)
            sphere.append(SIMD3(
                sin(phi) * cos(theta),
                cos(phi),
                sin(phi) * sin(theta)
            ))
        }
        let fitter = RANSACPlaneFitter()
        #expect(throws: GeometryError.noConsensus) {
            _ = try fitter.fit(
                points: sphere, normals: nil,
                options: PlaneFitOptions(
                    maxIterations: 200, inlierDistance: 0.02, minInliers: 80,
                    constraint: .none, scoring: .msac, rngSeed: 7
                )
            )
        }
    }

    @Test("Puntos colineales: error tipado colinearPoints")
    func colinearError() {
        var rng = SplitMix64(seed: 3)
        var line: [SIMD3<Float>] = []
        for _ in 0..<50 {
            let t = Float.random(in: -1...1, using: &rng)
            line.append(SIMD3(t, 2 * t, 3 * t))
        }
        let fitter = RANSACPlaneFitter()
        #expect(throws: GeometryError.colinearPoints) {
            _ = try fitter.fit(
                points: line, normals: nil,
                options: PlaneFitOptions(
                    maxIterations: 200, inlierDistance: 0.02, minInliers: 5,
                    constraint: .none, scoring: .msac, rngSeed: 7
                )
            )
        }
    }
}

@Suite("F2 Geometry: OBB por PCA")
struct OBBTests {

    @Test("Caja 0.30×0.20×0.10 rotada por yaw 37° y pitch 12°")
    func rotatedBoxRecovered() throws {
        let half = SIMD3<Float>(0.15, 0.10, 0.05)
        let corners = SyntheticGeometry.boxPoints(half: half, perEdge: 6)
        let rotated = SyntheticGeometry.rotate(corners, yawDegrees: 37, pitchDegrees: 12)

        let fitter = PCAOBBFitter()
        let obb = try fitter.fit(points: rotated, gravityAlignedUpAxis: false)

        // Dimensiones dentro de 1 mm (permutación de ejes aceptada).
        let fittedDims = [obb.halfExtents.x * 2, obb.halfExtents.y * 2, obb.halfExtents.z * 2].sorted()
        let expectedDims = [0.10 as Float, 0.20, 0.30].sorted()
        for i in 0..<3 {
            #expect(abs(fittedDims[i] - expectedDims[i]) < 0.001)
        }

        // Ejes dentro de 1° (permutación y signo aceptados).
        let col0 = vecNormalize(obb.axes[0])
        let col1 = vecNormalize(obb.axes[1])
        let col2 = vecNormalize(obb.axes[2])
        let fittedAxes = [col0, col1, col2]

        // Ejes esperados: columnas de la misma matriz de rotación del generador.
        let expected = SyntheticGeometry.rotationMatrix(yawDegrees: 37, pitchDegrees: 12)
        let expectedAxes = [expected[0], expected[1], expected[2]]

        // Cada eje ajustado debe estar a menos de 1° de algún eje esperado.
        for ax in fittedAxes {
            var best = Float.greatestFiniteMagnitude
            for e in expectedAxes {
                best = min(best, acos(min(1, abs(vecDot(ax, vecNormalize(e))))))
            }
            #expect(best * 180 / .pi < 1.0)
        }
    }

    @Test("Caso degenerado: nube casi plana, semieje menor tiende a 0 sin NaN")
    func degenerateFlatCloud() throws {
        var rng = SplitMix64(seed: 21)
        var flat: [SIMD3<Float>] = []
        for _ in 0..<200 {
            let x = Float.random(in: -0.5...0.5, using: &rng)
            let y = Float.random(in: -0.5...0.5, using: &rng)
            let z = Float.random(in: -0.0005...0.0005, using: &rng)
            flat.append(SIMD3(x, y, z))
        }
        let fitter = PCAOBBFitter()
        let obb = try fitter.fit(points: flat, gravityAlignedUpAxis: false)

        let dims = [obb.halfExtents.x * 2, obb.halfExtents.y * 2, obb.halfExtents.z * 2].sorted()
        #expect(dims[0] < 0.01) // semieje menor ~0
        #expect(obb.halfExtents.x.isFinite)
        #expect(obb.halfExtents.y.isFinite)
        #expect(obb.halfExtents.z.isFinite)
        #expect(!obb.halfExtents.x.isNaN)
        #expect(!obb.halfExtents.y.isNaN)
        #expect(!obb.halfExtents.z.isNaN)
    }
}

@Suite("F2 Geometry: Rectifier")
struct RectifierTests {

    @Test("Damero de nodos de 5 cm sobre plano inclinado")
    func checkerboardMetric() throws {
        let normal = vecNormalize(SIMD3<Float>(0.2, 0.95, -0.15))
        let plane = try Plane(point: SIMD3(0, 1, 0), normal: normal)
        let basis = Rectifier.makeBasis(plane: plane)

        // Nodos de un damero 10×10 con espaciado 5 cm, sobre la base del plano.
        var nodes: [SIMD3<Float>] = []
        for i in 0..<10 {
            for j in 0..<10 {
                let p = plane.point + basis.u * (Float(i) * 0.05) + basis.v * (Float(j) * 0.05)
                nodes.append(p)
            }
        }

        let rectifier = Rectifier(resolution: 400)
        let image = try rectifier.rectify(points: nodes, plane: plane)

        // La orto-imagen es no vacía y el espaciado se recupera métricamente.
        #expect(image.width > 0)
        #expect(image.height > 0)
        #expect(image.resolution == 400)

        // Distancia entre nodos adyacentes en el marco rectificado dentro de 1 mm.
        // nodes[1] está a lo largo de v; nodes[10] a lo largo de u.
        let originLocal = Rectifier.localCoordinates(nodes[0], plane: plane)
        let alongV = Rectifier.localCoordinates(nodes[1], plane: plane)
        let alongU = Rectifier.localCoordinates(nodes[10], plane: plane)
        let distV = sqrt((alongV.x - originLocal.x) * (alongV.x - originLocal.x)
                       + (alongV.y - originLocal.y) * (alongV.y - originLocal.y))
        let distU = sqrt((alongU.x - originLocal.x) * (alongU.x - originLocal.x)
                       + (alongU.y - originLocal.y) * (alongU.y - originLocal.y))
        #expect(abs(distV - 0.05) < 0.001)
        #expect(abs(distU - 0.05) < 0.001)

        // Líneas del damero paralelas a los ejes de la imagen dentro de 0.3°:
        // el nodo a lo largo de u debe tener desviación en v ~ 0, y viceversa.
        let angleU = atan2(abs(alongU.y - originLocal.y), abs(alongU.x - originLocal.x))
        let angleV = atan2(abs(alongV.x - originLocal.x), abs(alongV.y - originLocal.y))
        #expect(angleU * 180 / .pi < 0.3)
        #expect(angleV * 180 / .pi < 0.3)
    }
}