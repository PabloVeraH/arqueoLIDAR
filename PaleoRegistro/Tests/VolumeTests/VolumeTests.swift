import Testing
import Foundation
import Domain
import Mesh
@testable import Volume

// ═══════════════════════════════════════════════════════════════════════════════
// F5 — Criterios de aceptación: verdad sintética con fórmula analítica.
// ═══════════════════════════════════════════════════════════════════════════════

/// Generadores de mallas sintéticas con volumen analítico conocido.
/// Réplica de los generadores validados en StockIA (`SyntheticMeshGenerators.swift`).
enum VolFixtures {

    /// Cono de base circular (radio R) apoyado en y=0, ápice en (0, H, 0).
    /// V = (1/3)·π·R²·H.
    static func cone(radius R: Float, height H: Float, rings: Int, segments: Int) -> Mesh {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        var rim: [UInt32] = []
        for s in 0..<segments {
            let theta = Float(2 * Double.pi) * Float(s) / Float(segments)
            rim.append(UInt32(vertices.count))
            vertices.append(SIMD3(R * cos(theta), 0, R * sin(theta)))
        }
        var layers: [[UInt32]] = [rim]
        for r in 1...rings {
            let h = H * Float(r) / Float(rings + 1)
            let rad = R * (1 - h / H)
            var layer: [UInt32] = []
            for s in 0..<segments {
                let theta = Float(2 * Double.pi) * Float(s) / Float(segments)
                layer.append(UInt32(vertices.count))
                vertices.append(SIMD3(rad * cos(theta), h, rad * sin(theta)))
            }
            layers.append(layer)
        }
        let apex = UInt32(vertices.count)
        vertices.append(SIMD3(0, H, 0))

        for l in 0..<(layers.count - 1) {
            let cur = layers[l]
            let nxt = layers[l + 1]
            for s in 0..<segments {
                let a = cur[s]
                let b = cur[(s + 1) % segments]
                let c = nxt[s]
                let d = nxt[(s + 1) % segments]
                indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        let top = layers[layers.count - 1]
        for s in 0..<segments {
            let a = top[s]
            let b = top[(s + 1) % segments]
            indices.append(contentsOf: [a, b, apex])
        }
        return Mesh(vertices: vertices, indices: indices)
    }

    /// Pirámide truncada: base cuadrada lado `A` en y=0, tapa lado `a` a altura H.
    /// V = (H/3)·(A² + A·a + a²).
    static func frustum(baseSide A: Float, topSide a: Float, height H: Float, rings: Int, perSide: Int) -> Mesh {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        func capGrid(lado: Float, y: Float) -> (rows: [[UInt32]], center: UInt32) {
            let h2 = lado / 2
            let corners: [(Float, Float)] = [(h2, -h2), (h2, h2), (-h2, h2), (-h2, -h2)]
            var border: [(Float, Float)] = []
            for side in 0..<4 {
                let (x0, z0) = corners[side]
                let (x1, z1) = corners[(side + 1) % 4]
                for k in 0..<perSide {
                    let t = Float(k) / Float(perSide)
                    border.append((x0 + (x1 - x0) * t, z0 + (z1 - z0) * t))
                }
            }
            var rows: [[UInt32]] = []
            var row: [UInt32] = [UInt32(vertices.count)]
            for (x, z) in border {
                vertices.append(SIMD3(x, y, z))
                row.append(UInt32(vertices.count - 1))
            }
            rows.append(row)
            for r in 1...rings {
                let f = Float(r) / Float(rings + 1)
                var row: [UInt32] = [UInt32(vertices.count)]
                for (x, z) in border {
                    vertices.append(SIMD3(x * (1 - f), y, z * (1 - f)))
                    row.append(UInt32(vertices.count - 1))
                }
                rows.append(row)
            }
            let center = UInt32(vertices.count)
            vertices.append(SIMD3(0, y, 0))
            return (rows, center)
        }

        func fanTriangulate(rows: [[UInt32]], center: UInt32) {
            for r in 0..<(rows.count - 1) {
                let lo = rows[r]
                let hi = rows[r + 1]
                for s in 0..<(lo.count - 1) {
                    let a = lo[s]
                    let b = lo[s + 1]
                    let c = hi[s]
                    let d = hi[s + 1]
                    indices.append(contentsOf: [a, b, c, b, d, c])
                }
            }
            let last = rows[rows.count - 1]
            for s in 0..<(last.count - 1) {
                indices.append(contentsOf: [last[s], last[s + 1], center])
            }
        }

        let base = capGrid(lado: A, y: 0)
        let top = capGrid(lado: a, y: H)
        fanTriangulate(rows: base.rows, center: base.center)
        fanTriangulate(rows: top.rows, center: top.center)

        let nBase = base.rows[0].count - 1
        for s in 0..<nBase {
            let s1 = (s + 1) % nBase
            let b0 = base.rows[0][s]
            let b1 = base.rows[0][s1]
            let t0 = top.rows[0][s]
            let t1 = top.rows[0][s1]
            indices.append(contentsOf: [b0, b1, t1, b0, t1, t0])
        }
        return Mesh(vertices: vertices, indices: indices)
    }

    /// Esfera de radio r alrededor del origen (caras orientadas hacia afuera).
    static func sphere(radius r: Float, latDiv: Int = 24, lonDiv: Int = 48) -> Mesh {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        vertices.append(SIMD3(0, -r, 0))
        vertices.append(SIMD3(0, r, 0))
        let south = UInt32(0)
        let north = UInt32(1)
        for i in 1..<latDiv {
            let phi = Float.pi * Float(i) / Float(latDiv)
            for j in 0..<lonDiv {
                let theta = 2 * Float.pi * Float(j) / Float(lonDiv)
                vertices.append(SIMD3(r * sin(phi) * cos(theta), r * cos(phi), r * sin(phi) * sin(theta)))
            }
        }
        func idx(_ ring: Int, _ sector: Int) -> UInt32 {
            if ring == 0 { return south }
            if ring == latDiv { return north }
            return UInt32(2 + (ring - 1) * lonDiv + sector)
        }
        for j in 0..<lonDiv {
            let j2 = (j + 1) % lonDiv
            indices.append(contentsOf: [south, idx(1, j), idx(1, j2)])
            indices.append(contentsOf: [north, idx(latDiv - 1, j2), idx(latDiv - 1, j)])
        }
        for i in 1..<(latDiv - 1) {
            for j in 0..<lonDiv {
                let j2 = (j + 1) % lonDiv
                indices.append(contentsOf: [idx(i, j), idx(i + 1, j), idx(i + 1, j2)])
                indices.append(contentsOf: [idx(i, j), idx(i + 1, j2), idx(i, j2)])
            }
        }
        var flipped: [UInt32] = []
        flipped.reserveCapacity(indices.count)
        for t in stride(from: 0, to: indices.count, by: 3) {
            flipped.append(contentsOf: [indices[t], indices[t + 2], indices[t + 1]])
        }
        return outwardOriented(Mesh(vertices: vertices, indices: flipped))
    }

    /// Toro de radio mayor R y radio menor r en el plano XZ, orientado hacia afuera.
    /// V = 2·π²·R·r².
    static func torus(major R: Float, minor r: Float, segMajor: Int = 48, segMinor: Int = 24) -> Mesh {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0..<segMajor {
            let u = 2 * Float.pi * Float(i) / Float(segMajor)
            for j in 0..<segMinor {
                let v = 2 * Float.pi * Float(j) / Float(segMinor)
                let x = (R + r * cos(v)) * cos(u)
                let y = r * sin(v)
                let z = (R + r * cos(v)) * sin(u)
                vertices.append(SIMD3(x, y, z))
            }
        }
        for i in 0..<segMajor {
            let i2 = (i + 1) % segMajor
            for j in 0..<segMinor {
                let j2 = (j + 1) % segMinor
                let a = UInt32(i * segMinor + j)
                let b = UInt32(i * segMinor + j2)
                let c = UInt32(i2 * segMinor + j)
                let d = UInt32(i2 * segMinor + j2)
                indices.append(contentsOf: [b, a, c])
                indices.append(contentsOf: [d, b, c])
            }
        }
        return outwardOriented(Mesh(vertices: vertices, indices: indices))
    }

    /// "Hongo": cilindro (radio a, altura H) coronado por un plato (radio b > a,
    /// espesor t) con voladizo. Volumen real = π·a²·H + π·b²·t. Malla cerrada.
    static func mushroom(pedestalRadius a: Float, pedestalHeight H: Float, capRadius b: Float, capThickness t: Float, segments: Int = 64) -> Mesh {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        // Anillo del pedestal en y=0.
        var baseRing: [UInt32] = []
        for s in 0..<segments {
            let theta = 2 * Float.pi * Float(s) / Float(segments)
            baseRing.append(UInt32(vertices.count))
            vertices.append(SIMD3(a * cos(theta), 0, a * sin(theta)))
        }
        // Anillo del pedestal en y=H.
        var pedTop: [UInt32] = []
        for s in 0..<segments {
            let theta = 2 * Float.pi * Float(s) / Float(segments)
            pedTop.append(UInt32(vertices.count))
            vertices.append(SIMD3(a * cos(theta), H, a * sin(theta)))
        }
        // Anillo del plato en y=H (borde exterior).
        var capBot: [UInt32] = []
        for s in 0..<segments {
            let theta = 2 * Float.pi * Float(s) / Float(segments)
            capBot.append(UInt32(vertices.count))
            vertices.append(SIMD3(b * cos(theta), H, b * sin(theta)))
        }
        // Anillo del plato en y=H+t.
        var capTop: [UInt32] = []
        for s in 0..<segments {
            let theta = 2 * Float.pi * Float(s) / Float(segments)
            capTop.append(UInt32(vertices.count))
            vertices.append(SIMD3(b * cos(theta), H + t, b * sin(theta)))
        }

        // Tapa inferior (y=0).
        let baseCenter = UInt32(vertices.count)
        vertices.append(SIMD3(0, 0, 0))
        for s in 0..<segments {
            let s2 = (s + 1) % segments
            indices.append(contentsOf: [baseCenter, baseRing[s2], baseRing[s]])
        }
        // Pared lateral del pedestal.
        for s in 0..<segments {
            let s2 = (s + 1) % segments
            indices.append(contentsOf: [baseRing[s], baseRing[s2], pedTop[s2]])
            indices.append(contentsOf: [baseRing[s], pedTop[s2], pedTop[s]])
        }
        // Anillo plano del borde del plato (y=H): de a a b.
        for s in 0..<segments {
            let s2 = (s + 1) % segments
            indices.append(contentsOf: [capBot[s2], capBot[s], pedTop[s]])
            indices.append(contentsOf: [pedTop[s2], capBot[s2], pedTop[s]])
        }
        // Pared lateral del plato.
        for s in 0..<segments {
            let s2 = (s + 1) % segments
            indices.append(contentsOf: [capBot[s], capTop[s2], capTop[s]])
            indices.append(contentsOf: [capBot[s], capBot[s2], capTop[s2]])
        }
        // Tapa superior (y=H+t).
        let capCenter = UInt32(vertices.count)
        vertices.append(SIMD3(0, H + t, 0))
        for s in 0..<segments {
            let s2 = (s + 1) % segments
            indices.append(contentsOf: [capCenter, capTop[s], capTop[s2]])
        }
        return outwardOriented(Mesh(vertices: vertices, indices: indices))
    }

    /// Cubo de lado `size` centrado en `center` con esquinas `divisions` por arista.
    static func cube(center: SIMD3<Float>, size: Float) -> Mesh {
        let h = size / 2
        func v(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
            SIMD3(center.x + x * h, center.y + y * h, center.z + z * h)
        }
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (v(-1, -1, 1), v(1, -1, 1), v(1, 1, 1), v(-1, 1, 1)),
            (v(1, -1, -1), v(-1, -1, -1), v(-1, 1, -1), v(1, 1, -1)),
            (v(-1, -1, -1), v(-1, -1, 1), v(-1, 1, 1), v(-1, 1, -1)),
            (v(1, -1, 1), v(1, -1, -1), v(1, 1, -1), v(1, 1, 1)),
            (v(-1, -1, -1), v(1, -1, -1), v(1, -1, 1), v(-1, -1, 1)),
            (v(-1, 1, 1), v(1, 1, 1), v(1, 1, -1), v(-1, 1, -1)),
        ]
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for (a, b, c, d) in faces {
            let ia = UInt32(vertices.count); vertices.append(a)
            let ib = UInt32(vertices.count); vertices.append(b)
            let ic = UInt32(vertices.count); vertices.append(c)
            let id = UInt32(vertices.count); vertices.append(d)
            indices.append(contentsOf: [ia, ib, ic, ia, ic, id])
        }
        return Mesh(vertices: vertices, indices: indices)
    }

    /// Grilla de campo de alturas: superficie y(x,z) sobre el footprint
    /// `[-half, half]²`, con `grid` divisiones por lado. Malla de cara única.
    static func heightField(
        half: Float,
        grid: Int,
        y: (Float, Float) -> Float
    ) -> Mesh {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let n = grid + 1
        var rows: [[UInt32]] = []
        for i in 0...grid {
            let x = -half + Float(i) * (2 * half) / Float(grid)
            var row: [UInt32] = []
            for j in 0...grid {
                let z = -half + Float(j) * (2 * half) / Float(grid)
                row.append(UInt32(vertices.count))
                vertices.append(SIMD3(x, y(x, z), z))
            }
            rows.append(row)
        }
        for i in 0..<grid {
            for j in 0..<grid {
                let a = rows[i][j]
                let b = rows[i][j + 1]
                let c = rows[i + 1][j]
                let d = rows[i + 1][j + 1]
                indices.append(contentsOf: [a, c, b])
                indices.append(contentsOf: [b, c, d])
            }
        }
        return Mesh(vertices: vertices, indices: indices)
    }

    /// Superficie plana a y = h (prior intacto).
    static func flatSurface(half: Float, grid: Int, height h: Float) -> Mesh {
        heightField(half: half, grid: grid) { _, _ in h }
    }

    /// Superficie con un mordisco hemisférico de radio `r` centrado en
    /// `(biteCenterX, h, biteCenterZ)`.
    static func surfaceWithHemisphericalBite(
        half: Float, grid: Int, height h: Float,
        biteRadius r: Float,
        biteCenter: SIMD3<Float>
    ) -> Mesh {
        heightField(half: half, grid: grid) { x, z in
            let d = SIMD3<Float>(x - biteCenter.x, 0, z - biteCenter.z)
            let dist = vecLength(d)
            if dist < r {
                let depth = (r * r - dist * dist).squareRoot()
                return h - depth
            }
            return h
        }
    }

    /// Hemisferio superior abierto de radio r (para el test de malla no estanca).
    static func openUpperHemisphere(radius r: Float, latDiv: Int = 24, lonDiv: Int = 48) -> Mesh {
        let full = sphere(radius: r, latDiv: latDiv, lonDiv: lonDiv)
        var keep = [Bool](repeating: false, count: full.triangleCount)
        for (i, t) in stride(from: 0, to: full.indices.count, by: 3).enumerated() {
            let ys = [full.indices[t], full.indices[t + 1], full.indices[t + 2]].map { full.vertices[Int($0)].y }
            keep[i] = ys.allSatisfy { $0 >= -0.001 }
        }
        var newVertices: [SIMD3<Float>] = []
        var remap: [UInt32: UInt32] = [:]
        var newIndices: [UInt32] = []
        func mapped(_ old: UInt32) -> UInt32 {
            if let n = remap[old] { return n }
            let n = UInt32(newVertices.count)
            newVertices.append(full.vertices[Int(old)])
            remap[old] = n
            return n
        }
        for (i, t) in stride(from: 0, to: full.indices.count, by: 3).enumerated() where keep[i] {
            newIndices.append(mapped(full.indices[t]))
            newIndices.append(mapped(full.indices[t + 1]))
            newIndices.append(mapped(full.indices[t + 2]))
        }
        return Mesh(vertices: newVertices, indices: newIndices)
    }

    /// Concatena dos mallas remapeando índices.
    static func combine(_ a: Mesh, _ b: Mesh) -> Mesh {
        let base = UInt32(a.vertices.count)
        return Mesh(
            vertices: a.vertices + b.vertices,
            indices: a.indices + b.indices.map { $0 + base }
        )
    }

    /// Volumen por divergencia (teorema de Gauss).
    static func closedVolume(_ mesh: Mesh) -> Double {
        var v: Double = 0
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[t])]
            let b = mesh.vertices[Int(mesh.indices[t + 1])]
            let c = mesh.vertices[Int(mesh.indices[t + 2])]
            v += Double(vecDot(vecCross(a, b), c))
        }
        return v / 6
    }

    /// Garantiza orientación hacia afuera: si el volumen firmado es negativo,
    /// invierte el winding de todos los triángulos.
    static func outwardOriented(_ mesh: Mesh) -> Mesh {
        guard closedVolume(mesh) < 0 else { return mesh }
        var flipped: [UInt32] = []
        flipped.reserveCapacity(mesh.indices.count)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            flipped.append(contentsOf: [mesh.indices[t], mesh.indices[t + 2], mesh.indices[t + 1]])
        }
        return Mesh(vertices: mesh.vertices, indices: flipped)
    }
}

@Suite("F5 Volume: height field")
struct HeightFieldTests {

    private func planeY0() throws -> Plane {
        try Plane(point: SIMD3<Float>(0, 0, 0), normal: SIMD3(0, 1, 0))
    }

    @Test("Cono: error < 2% en tres resoluciones y decrece monótonamente")
    func coneErrorDecreases() throws {
        let R: Float = 1
        let H: Float = 1
        let trueVolume = Double.pi * 1.0 * 1.0 * 1.0 / 3.0
        let mesh = VolFixtures.cone(radius: R, height: H, rings: 24, segments: 384)
        let ref = ReferenceSurface.plane(try planeY0())

        let integ = SignedHeightFieldIntegrator()
        var errors: [Double] = []
        for cell in [Float(0.025), 0.0125, 0.00625] {
            let result = try integ.integrate(mesh: mesh, reference: ref, cellSize: cell, emptyCells: .ignore)
            let error = abs(result.positive - trueVolume) / trueVolume
            errors.append(error)
            #expect(error < 0.02, "cono cell=\(cell): error \(error)")
        }
        #expect(errors[2] <= errors[1])
        #expect(errors[1] <= errors[0])
    }

    @Test("Pirámide truncada: error < 2%")
    func frustumVolume() throws {
        let trueVolume = 7.0 / 3.0
        let mesh = VolFixtures.frustum(baseSide: 2, topSide: 1, height: 1, rings: 8, perSide: 16)
        let ref = ReferenceSurface.plane(try planeY0())
        let integ = SignedHeightFieldIntegrator()
        for cell in [Float(0.05), 0.025] {
            let result = try integ.integrate(mesh: mesh, reference: ref, cellSize: cell, emptyCells: .ignore)
            let error = abs(result.positive - trueVolume) / trueVolume
            #expect(error < 0.02, "frustum cell=\(cell): error \(error)")
        }
    }

    @Test("Volumen negativo: cono invertido da magnitud igual y signo negativo")
    func invertedCone() throws {
        let R: Float = 1
        let H: Float = 1
        let trueVolume = Double.pi / 3.0
        // Depresión cónica: una cavidad en el suelo con la misma forma del cono.
        // Superficie y(r) = -(H)·(1 - r/R) con 0 ≤ r ≤ R.
        let inverted = VolFixtures.heightField(half: R, grid: 96) { x, z in
            let d = (x * x + z * z).squareRoot()
            return d <= R ? -H * (1 - d / R) : 0
        }
        let ref = ReferenceSurface.plane(try planeY0())
        let integ = SignedHeightFieldIntegrator()
        let result = try integ.integrate(mesh: inverted, reference: ref, cellSize: 0.0125, emptyCells: .ignore)

        // Debe tener `negative > 0` y `positive ≈ 0` (el test falla si se aplica max(0,h)).
        #expect(result.negative > 0)
        #expect(result.positive < trueVolume * 0.01)
        let error = abs(result.negative - trueVolume) / trueVolume
        #expect(error < 0.01, "cono invertido: negative=\(result.negative) vs \(trueVolume), error \(error)")
    }

    @Test("Escena mixta: positivo y negativo reportados por separado")
    func mixedScene() throws {
        // Montículo (cono sobre y=0) + zanja (depresión rectangular) adyacentes.
        let mound = VolFixtures.cone(radius: 0.6, height: 0.6, rings: 24, segments: 384)
        let moundVol = Double.pi * 0.6 * 0.6 * 0.6 / 3.0
        // Zanja: excavación rectangular de 0.5×0.5 de huella y 0.5 de profundidad,
        // centrada en x=-1.2. Cubo que atraviesa el plano y=0: cara superior en y=0,
        // inferior en y=-0.5 → el integrador mide `negative` exacto.
        let trenchDepth: Float = 0.5
        let trenchMesh = VolFixtures.cube(center: SIMD3<Float>(-1.2, -trenchDepth / 2, 0), size: trenchDepth)
        let trenchVol = Double(0.5 * 0.5 * trenchDepth)
        let scene = VolFixtures.combine(mound, trenchMesh)

        let ref = ReferenceSurface.plane(try planeY0())
        let integ = SignedHeightFieldIntegrator()
        let result = try integ.integrate(mesh: scene, reference: ref, cellSize: 0.0125, emptyCells: .ignore)

        // Debe reportar ambos por separado.
        #expect(result.positive > 0)
        #expect(result.negative > 0)
        let posErr = abs(result.positive - moundVol) / moundVol
        let negErr = abs(result.negative - trenchVol) / trenchVol
        #expect(posErr < 0.02, "montículo: error \(posErr)")
        #expect(negErr < 0.02, "zanja: error \(negErr)")
        // Y el neto es la diferencia.
        let net = result.positive - result.negative
        #expect(abs(net - result.net) < 1e-9)
    }

    @Test("Determinismo: dos corridas dan el mismo Double bit a bit")
    func determinism() throws {
        let mesh = VolFixtures.cone(radius: 1, height: 1, rings: 16, segments: 256)
        let ref = ReferenceSurface.plane(try planeY0())
        let integ = SignedHeightFieldIntegrator()
        let a = try integ.integrate(mesh: mesh, reference: ref, cellSize: 0.025, emptyCells: .fillInteriorHoles)
        let b = try integ.integrate(mesh: mesh, reference: ref, cellSize: 0.025, emptyCells: .fillInteriorHoles)
        #expect(a.positive.bitPattern == b.positive.bitPattern)
        #expect(a.negative.bitPattern == b.negative.bitPattern)
        #expect(a.coveredArea.bitPattern == b.coveredArea.bitPattern)
    }
}

@Suite("F5 Volume: closed mesh y enrutado")
struct ClosedMeshTests {

    @Test("Esfera y toro: error < 1% por divergencia")
    func sphereAndTorus() throws {
        let sphereMesh = VolFixtures.sphere(radius: 0.5, latDiv: 64, lonDiv: 128)
        let sphereTrue = 4.0 / 3.0 * Double.pi * 0.5 * 0.5 * 0.5
        let ref = ReferenceSurface.closedSolid
        let integ = ClosedMeshIntegrator()
        let sphereResult = try integ.integrate(mesh: sphereMesh, reference: ref, cellSize: 0, emptyCells: .ignore)
        #expect(abs(sphereResult.positive - sphereTrue) / sphereTrue < 0.01)

        let torusMesh = VolFixtures.torus(major: 0.5, minor: 0.2, segMajor: 64, segMinor: 32)
        let torusTrue = 2.0 * Double.pi * Double.pi * 0.5 * 0.2 * 0.2
        let torusResult = try integ.integrate(mesh: torusMesh, reference: ref, cellSize: 0, emptyCells: .ignore)
        #expect(abs(torusResult.positive - torusTrue) / torusTrue < 0.01, "toro: \(torusResult.positive) vs \(torusTrue)")
    }

    @Test("Malla no estanca: falla con error tipado")
    func notClosedThrows() throws {
        let open = VolFixtures.openUpperHemisphere(radius: 0.5)
        let integ = ClosedMeshIntegrator()
        #expect(throws: VolumeError.self) {
            try integ.integrate(mesh: open, reference: .closedSolid, cellSize: 0, emptyCells: .ignore)
        }
    }

    @Test("Hongo con voladizo: height field yerra > 20%, closed mesh acierta < 2%")
    func mushroomRouting() throws {
        let a: Float = 0.3
        let H: Float = 1.0
        let b: Float = 1.0
        let t: Float = 0.2
        let mesh = VolFixtures.mushroom(pedestalRadius: a, pedestalHeight: H, capRadius: b, capThickness: t)
        let trueVolume = Double.pi * Double(a) * Double(a) * Double(H) + Double.pi * Double(b) * Double(b) * Double(t)
        // Verificar watertight de la malla.
        let w = MeshOps().watertightness(mesh)
        #expect(w.isWatertight)

        let plane = try Plane(point: SIMD3<Float>(0, 0, 0), normal: SIMD3(0, 1, 0))
        let hf = SignedHeightFieldIntegrator()
        let hfResult = try hf.integrate(mesh: mesh, reference: .plane(plane), cellSize: 0.01, emptyCells: .fillInteriorHoles)
        // El height field integra la "columna" de aire bajo el alero → sobreestima.
        let hfError = abs(hfResult.positive - trueVolume) / trueVolume
        #expect(hfError > 0.2, "height field NO debería funcionar con voladizo; error \(hfError)")

        let cm = ClosedMeshIntegrator()
        let cmResult = try cm.integrate(mesh: mesh, reference: .closedSolid, cellSize: 0, emptyCells: .ignore)
        let cmError = abs(cmResult.positive - trueVolume) / trueVolume
        #expect(cmError < 0.02, "closed mesh error \(cmError)")
    }

    @Test("Enrutador: propósito → integrador correcto")
    func policyRouting() {
        #expect(VolumePolicy.route(for: .baseline) == .heightField)
        #expect(VolumePolicy.route(for: .postIntervention) == .heightField)
        #expect(VolumePolicy.route(for: .monitoring) == .heightField)
        #expect(VolumePolicy.route(for: .damageAssessment) == .cavity)
        #expect(VolumePolicy.route(for: .specimenInventory) == .closedMesh)
    }
}

@Suite("F5 Volume: cavity con trazabilidad")
struct CavityTests {

    private let half: Float = 0.5
    private let grid = 48
    private let h: Float = 1.0
    private let biteR: Float = 0.3
    private var expectedHemisphere: Double { 2.0 / 3.0 * Double.pi * Double(biteR) * Double(biteR) * Double(biteR) }

    @Test("Nivel 1: diff contra previo → cavidad < 2%, isInferred == false")
    func cavityAgainstPrior() throws {
        let prior = VolFixtures.flatSurface(half: half, grid: grid, height: h)
        let damaged = VolFixtures.surfaceWithHemisphericalBite(
            half: half, grid: grid, height: h,
            biteRadius: biteR, biteCenter: SIMD3<Float>(0, h, 0)
        )
        let integ = CavityIntegrator()
        let result = try integ.integrate(
            mesh: damaged,
            reference: .priorScan(prior, alignment: .identity),
            cellSize: 0.005,
            emptyCells: .ignore
        )
        #expect(result.isInferred == false)
        #expect(result.method == .cavityDiff)
        let error = abs(result.negative - expectedHemisphere) / expectedHemisphere
        #expect(error < 0.02, "cavity prior: \(result.negative) vs \(expectedHemisphere), error \(error)")
    }

    @Test("Nivel 2: anillo intacto → superficie ajustada, isInferred == true")
    func cavityRimFit() throws {
        let damaged = VolFixtures.surfaceWithHemisphericalBite(
            half: half, grid: grid, height: h,
            biteRadius: biteR, biteCenter: SIMD3<Float>(0, h, 0)
        )
        // Superficie de referencia: el plano de la cara superior intacta (y=1).
        let rimPlane = try Plane(point: SIMD3<Float>(0, 1.0, 0), normal: SIMD3(0, 1, 0))
        let integ = CavityIntegrator()
        let result = try integ.integrate(
            mesh: damaged,
            reference: .plane(rimPlane),
            cellSize: 0.005,
            emptyCells: .ignore
        )
        #expect(result.isInferred == true)
        #expect(result.method == .cavityRimFit)
        let error = abs(result.negative - expectedHemisphere) / expectedHemisphere
        #expect(error < 0.02, "cavity rim: \(result.negative) vs \(expectedHemisphere), error \(error)")
    }

    @Test("Nivel 3: simetría → isInferred == true y método reportado")
    func cavityMirror() throws {
        // Pieza simétrica respecto a X=0 con un mordisco en el lado +X. El mordisco
        // debe caber completo dentro del footprint de la superficie (half=0.5).
        let mirrorBiteR: Float = 0.2
        let biteCenterX: Float = 0.25
        let expectedMirror = 2.0 / 3.0 * Double.pi * Double(mirrorBiteR) * Double(mirrorBiteR) * Double(mirrorBiteR)
        let damaged = VolFixtures.surfaceWithHemisphericalBite(
            half: half, grid: grid, height: h,
            biteRadius: mirrorBiteR, biteCenter: SIMD3<Float>(biteCenterX, h, 0)
        )
        // El plano de simetría bilateral.
        let mirrorPlane = try Plane(point: SIMD3<Float>(0, 0, 0), normal: SIMD3(1, 0, 0))
        // El mordisco está todo en el lado +X: el lado sano reflejado (-X) lo
        // reconstruye. Volumen del mordisco completo.
        let integ = CavityIntegrator()
        let result = try integ.integrate(
            mesh: damaged,
            reference: .mirror(plane: mirrorPlane),
            cellSize: 0.005,
            emptyCells: .ignore
        )
        #expect(result.isInferred == true)
        #expect(result.method == .mirrorSymmetry)
        let error = abs(result.negative - expectedMirror) / expectedMirror
        #expect(error < 0.1, "cavity mirror: \(result.negative) vs \(expectedMirror), error \(error)")
    }

    @Test("isInferred poblado correctamente en los tres niveles (guardián legal)")
    func inferredFlagGuard() throws {
        let prior = VolFixtures.flatSurface(half: half, grid: grid, height: h)
        let damaged = VolFixtures.surfaceWithHemisphericalBite(
            half: half, grid: grid, height: h,
            biteRadius: biteR, biteCenter: SIMD3<Float>(0, h, 0)
        )
        let rimPlane = try Plane(point: SIMD3<Float>(0, 1.0, 0), normal: SIMD3(0, 1, 0))
        let mirrorPlane = try Plane(point: SIMD3<Float>(0, 0, 0), normal: SIMD3(1, 0, 0))
        let integ = CavityIntegrator()

        let level1 = try integ.integrate(mesh: damaged, reference: .priorScan(prior, alignment: .identity), cellSize: 0.01, emptyCells: .ignore)
        #expect(level1.isInferred == false)

        let level2 = try integ.integrate(mesh: damaged, reference: .plane(rimPlane), cellSize: 0.01, emptyCells: .ignore)
        #expect(level2.isInferred == true)

        let level3 = try integ.integrate(mesh: damaged, reference: .mirror(plane: mirrorPlane), cellSize: 0.01, emptyCells: .ignore)
        #expect(level3.isInferred == true)
    }
}
