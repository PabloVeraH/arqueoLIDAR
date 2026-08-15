import Testing
import Foundation
import Domain
@testable import Geometry
@testable import Stratigraphy

// ═══════════════════════════════════════════════════════════════════════════════
// F6 — Criterios de aceptación: verdad sintética, sin dispositivo.
//
// Pared sintética con manteo 25° y dirección de manteo 130°, estratos de
// potencia real conocida de 12.0 cm: marcando los límites sobre la orto-imagen
// rectificada, la potencia real se recupera dentro de 2 mm, y dip/dipDirection
// recuperados quedan dentro de 1°. Calcular potencia aparente en vez de real
// da 13.2 cm (el error que se está evitando). Corte oblicuo: la real se
// recupera igual (invariante), la aparente no. Estrato horizontal en pared
// vertical: aparente = real (atrapa errores de signo). Reproducible bit a bit.
// ═══════════════════════════════════════════════════════════════════════════════

/// Generador de verdad sintética para estratigrafía. Marco ENU: +X Este,
/// +Y Arriba, −Z Norte. Azimut medido desde el Norte en sentido horario.
enum StratFixtures {
    /// Vector horizontal unitario a un azimut (grados, 0=N, 90=E).
    static func horizontalUnit(azimuth degrees: Float) -> SIMD3<Float> {
        let r = degrees * .pi / 180
        return SIMD3<Float>(sin(r), 0, -cos(r))
    }

    /// Normal del plano del estrato (y ≥ 0) dado dip y dipDirection.
    /// n_s = (−sin(φ)·sin(θ), cos(θ), cos(φ)·sin(θ)).
    static func stratumNormal(dip: Float, dipDirection: Float) -> SIMD3<Float> {
        let th = dip * .pi / 180
        let phi = dipDirection * .pi / 180
        let nx = -sin(phi) * sin(th)
        let ny = cos(th)
        let nz = cos(phi) * sin(th)
        return SIMD3<Float>(nx, ny, nz)
    }

    /// Plane del estrato a partir de dip y dipDirection, pasando por `center`.
    static func stratumPlane(dip: Float, dipDirection: Float, center: SIMD3<Float>) -> Plane {
        try! Plane(point: center, normal: stratumNormal(dip: dip, dipDirection: dipDirection))
    }

    /// Puntos sobre un plano de pared vertical con normal horizontal n_w.
    static func wallPoints(
        wallCenter: SIMD3<Float>,
        n_w: SIMD3<Float>,
        width: Float,
        height: Float,
        gridU: Int,
        gridV: Int,
        noiseSigma: Float = 0,
        seed: UInt64 = 1
    ) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: seed)
        // Ejes del plano de la pared: horizontal u = strike de pared, v = up.
        let up = SIMD3<Float>(0, 1, 0)
        // Ejes del plano de la pared: u = strike horizontal de la pared,
        // v = dirección de máxima pendiente (perpendicular a n_w en el plano
        // vertical que contiene a n_w). Para pared vertical, v = up.
        let u = normalize(cross(up, n_w))
        let v = normalize(cross(u, n_w))
        var pts: [SIMD3<Float>] = []
        pts.reserveCapacity(gridU * gridV)
        for i in 0..<gridU {
            for j in 0..<gridV {
                let sU = (Float(i) + 0.5) / Float(gridU) - 0.5
                let sV = (Float(j) + 0.5) / Float(gridV) - 0.5
                let g = gaussianNoise(rng: &rng) * noiseSigma
                let p = wallCenter
                    + u * (sU * width)
                    + v * (sV * height)
                    + n_w * g
                pts.append(p)
            }
        }
        return pts
    }

    /// Línea de intersección del plano del estrato (normal n_s, pasa por p_s)
    /// con el plano de la pared (normal n_w, pasa por p_w). Devuelve N puntos
    /// sobre la línea dentro del extent ± extHalf a lo largo de la dirección
    /// horizontal del strike de la pared.
    static func boundaryLine(
        n_s: SIMD3<Float>,
        p_s: SIMD3<Float>,
        n_w: SIMD3<Float>,
        p_w: SIMD3<Float>,
        extHalf: Float,
        sampleCount: Int
    ) -> [SIMD3<Float>] {
        // Dirección de la línea = n_s × n_w.
        let dir = normalize(cross(n_s, n_w))
        // Resolver el punto de la línea: la línea está en ambos planos.
        // p = p_w + α·u_w + β·v_w, con n_s·p = n_s·p_s.
        // u_w = strike horizontal de la pared; v_w = máxima pendiente de la
        // pared (perpendicular a u_w y a n_w).
        let up = SIMD3<Float>(0, 1, 0)
        let u_w = normalize(cross(up, n_w))  // strike horizontal de la pared
        let v_w = normalize(cross(u_w, n_w)) // máxima pendiente de la pared
        // n_s·(p_w + β·v_w) = n_s·p_s  =>  β = (n_s·p_s − n_s·p_w) / (n_s·v_w)
        let denom = dot(n_s, v_w)
        let num = dot(n_s, p_s - p_w)
        let beta = abs(denom) > 1e-9 ? num / denom : 0
        // Punto base sobre la línea, en x-w lateral = 0 (α=0).
        let base = p_w + v_w * beta
        var pts: [SIMD3<Float>] = []
        for k in 0..<sampleCount {
            let t = extHalf * (2.0 * Float(k) / Float(sampleCount - 1) - 1.0)
            pts.append(base + dir * t)
        }
        return pts
    }

    /// Ruido gaussiano (Box–Muller) determinista.
    static func gaussianNoise(rng: inout SplitMix64) -> Float {
        var u1: Float = 0
        var u2: Float = 0
        repeat {
            u1 = Float.random(in: 1e-6...1, using: &rng)
            u2 = Float.random(in: 0...1, using: &rng)
        } while u1 <= 0
        let mag = sqrt(-2.0 * log(u1))
        return mag * cos(2.0 * .pi * u2)
    }

    private static func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let l = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        guard l > 1e-9 else { return v }
        return v / l
    }

    private static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    private static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }
}

@Suite("F6 Stratigraphy: perfil de pared y potencias")
struct StratigraphyTests {

    // ────────────────────────────────────────────────────────────────────
    // TEST 1 — Potencia real recuperada y aparente = 13.2 cm (error evitado).
    // Pared vertical perpendicular al rumbo; estrato manteo 25° dir 130°.
    // ────────────────────────────────────────────────────────────────────
    @Test("Pared ⊥ rumbo: potencia real en 2 mm, aparente 13.2 cm, dip/dipDir en 1°")
    func perpendicularCutTrueVsApparent() throws {
        let dip: Float = 25
        let dipDir: Float = 130
        let n_s = StratFixtures.stratumNormal(dip: dip, dipDirection: dipDir)
        let n_w = StratFixtures.horizontalUnit(azimuth: dipDir)  // pared mira al descenso

        // Pared: 1.5 m ancho × 1.0 m alto, grilla 60×40, sin ruido (exacta).
        let p_w = SIMD3<Float>(0, 0.5, 0)
        let wallPts = StratFixtures.wallPoints(
            wallCenter: p_w, n_w: n_w,
            width: 1.5, height: 1.0, gridU: 60, gridV: 40
        )

        let builder = WallProfileBuilder(resolution: 500)
        let profile = try builder.build(points: wallPts)

        try #require(abs(profile.plane.inlierRMS ?? 0) < 0.001)

        // Tres límites separados perpendicularmente 12 cm. El límite central
        // pasa por p_w; los otros dos a ±12 cm a lo largo de n_s.
        let t: Float = 0.12  // 12 cm
        let pB0 = p_w + n_s * t
        let pB1 = p_w
        let pB2 = p_w - n_s * t

        // Tomar muestras a lo largo de cada línea sobre la pared (±0.6 m).
        let b0 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB0, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 5)
        let b1 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB1, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 5)
        let b2 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB2, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 5)

        // Convertir a píxeles sobre la orto-imagen (simula marcas del operador).
        let picker = StratumBoundaryPicker()
        let id0 = UUID(); let id1 = UUID(); let id2 = UUID()
        var marks: [PixelMark] = []
        for p in b0 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id0, col: px.0, row: px.1)) } }
        for p in b1 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id1, col: px.0, row: px.1)) } }
        for p in b2 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id2, col: px.0, row: px.1)) } }

        let boundaries = try picker.pick(marks: marks, in: profile.orthoImage)

        let calc = ThicknessCalculator()
        let stratumPlane = StratFixtures.stratumPlane(dip: dip, dipDirection: dipDir, center: p_w)
        let results = try calc.measure(
            boundaries: boundaries,
            wallPlane: profile.plane,
            stratumPlane: stratumPlane,
            pixelResolution: profile.orthoImage.resolution
        )

        // Dos pares consecutivos, cada uno deben dar 12 cm real.
        #expect(results.count == 2)
        for r in results {
            #expect(abs(r.trueThickness - 0.12) < 0.002)              // 2 mm
            #expect(abs(r.apparentThickness - 0.132) < 0.005)         // ~13.2 cm
            #expect(abs(r.dip - dip) < 1.0)                          // 1°
            #expect(dipDirectionClose(r.dipDirection, dipDir, tol: 1.0))
        }
    }

    // ────────────────────────────────────────────────────────────────────
    // TEST 2 — El error evitado, afirmado explícitamente: aparente ≠ real.
    // ────────────────────────────────────────────────────────────────────
    @Test("Aparente y real son distintos: la corrección existe por una razón")
    func apparentIsNotReal() throws {
        let dip: Float = 25
        let n_s = StratFixtures.stratumNormal(dip: dip, dipDirection: 130)
        let n_w = StratFixtures.horizontalUnit(azimuth: 130)
        let p_w = SIMD3<Float>(0, 0.5, 0)
        let wallPts = StratFixtures.wallPoints(wallCenter: p_w, n_w: n_w, width: 1.5, height: 1.0, gridU: 40, gridV: 30)

        let profile = try WallProfileBuilder(resolution: 500).build(points: wallPts)
        let pB0 = p_w + n_s * 0.12
        let pB1 = p_w
        let b0 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB0, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 4)
        let b1 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB1, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 4)

        let id0 = UUID(); let id1 = UUID()
        var marks: [PixelMark] = []
        for p in b0 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id0, col: px.0, row: px.1)) } }
        for p in b1 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id1, col: px.0, row: px.1)) } }

        let boundaries = try StratumBoundaryPicker().pick(marks: marks, in: profile.orthoImage)
        let stratumPlane = StratFixtures.stratumPlane(dip: dip, dipDirection: 130, center: p_w)
        let results = try ThicknessCalculator().measure(boundaries: boundaries, wallPlane: profile.plane, stratumPlane: stratumPlane, pixelResolution: profile.orthoImage.resolution)

        #expect(results.count == 1)
        let r = results[0]
        // El aparente sobreestima: afirmamos que la diferencia es grande (~1.2 cm).
        #expect(r.apparentThickness > r.trueThickness)
        #expect(r.apparentThickness - r.trueThickness > 0.01)  // > 1 cm de sobreestimación
    }

    // ────────────────────────────────────────────────────────────────────
    // TEST 3 — Corte oblicuo al rumbo: la real es invariante, la aparente cambia.
    // ────────────────────────────────────────────────────────────────────
    @Test("Corte oblicuo: real invariante, aparente distinta del caso ⊥")
    func obliqueCutInvariance() throws {
        let dip: Float = 25
        let dipDir: Float = 130
        let n_s = StratFixtures.stratumNormal(dip: dip, dipDirection: dipDir)
        let p_w = SIMD3<Float>(0, 0.5, 0)

        // Caso perpendicular (referencia).
        let n_w_perp = StratFixtures.horizontalUnit(azimuth: dipDir)
        let wallPerp = StratFixtures.wallPoints(wallCenter: p_w, n_w: n_w_perp, width: 1.5, height: 1.0, gridU: 40, gridV: 30)
        let profilePerp = try WallProfileBuilder(resolution: 500).build(points: wallPerp)
        let pB0c = p_w + n_s * 0.12
        let pB1c = p_w
        let b0c = StratFixtures.boundaryLine(n_s: n_s, p_s: pB0c, n_w: n_w_perp, p_w: p_w, extHalf: 0.6, sampleCount: 4)
        let b1c = StratFixtures.boundaryLine(n_s: n_s, p_s: pB1c, n_w: n_w_perp, p_w: p_w, extHalf: 0.6, sampleCount: 4)
        let id0c = UUID(); let id1c = UUID()
        var marksC: [PixelMark] = []
        for p in b0c { if let px = pixelOf(p, in: profilePerp.orthoImage) { marksC.append(PixelMark(boundaryID: id0c, col: px.0, row: px.1)) } }
        for p in b1c { if let px = pixelOf(p, in: profilePerp.orthoImage) { marksC.append(PixelMark(boundaryID: id1c, col: px.0, row: px.1)) } }
        let boundsC = try StratumBoundaryPicker().pick(marks: marksC, in: profilePerp.orthoImage)
        let stratumPlaneC = StratFixtures.stratumPlane(dip: dip, dipDirection: dipDir, center: p_w)
        let resC = try ThicknessCalculator().measure(boundaries: boundsC, wallPlane: profilePerp.plane, stratumPlane: stratumPlaneC, pixelResolution: profilePerp.orthoImage.resolution)

        // Caso oblicuo: pared rotada 40° en azimut respecto al perpendicular
        // Y levemente inclinada (10° de vertical) para que su dirección de
        // máxima pendiente difiera de la vertical y la aparente cambie.
        let n_w_obl = tiltFromVertical(azimuth: dipDir + 40, tiltDeg: 10)
        let wallObl = StratFixtures.wallPoints(wallCenter: p_w, n_w: n_w_obl, width: 1.5, height: 1.0, gridU: 40, gridV: 30)
        let profileObl = try WallProfileBuilder(resolution: 500).build(points: wallObl)
        let b0o = StratFixtures.boundaryLine(n_s: n_s, p_s: pB0c, n_w: n_w_obl, p_w: p_w, extHalf: 0.6, sampleCount: 4)
        let b1o = StratFixtures.boundaryLine(n_s: n_s, p_s: pB1c, n_w: n_w_obl, p_w: p_w, extHalf: 0.6, sampleCount: 4)
        let id0o = UUID(); let id1o = UUID()
        var marksO: [PixelMark] = []
        for p in b0o { if let px = pixelOf(p, in: profileObl.orthoImage) { marksO.append(PixelMark(boundaryID: id0o, col: px.0, row: px.1)) } }
        for p in b1o { if let px = pixelOf(p, in: profileObl.orthoImage) { marksO.append(PixelMark(boundaryID: id1o, col: px.0, row: px.1)) } }
        let boundsO = try StratumBoundaryPicker().pick(marks: marksO, in: profileObl.orthoImage)
        let stratumPlaneO = StratFixtures.stratumPlane(dip: dip, dipDirection: dipDir, center: p_w)
        let resO = try ThicknessCalculator().measure(boundaries: boundsO, wallPlane: profileObl.plane, stratumPlane: stratumPlaneO, pixelResolution: profileObl.orthoImage.resolution)

        #expect(resC.count == 1)
        #expect(resO.count == 1)
        // La real se recupera igual en ambos (invariante al ángulo de corte).
        let trueErrO = abs(resO[0].trueThickness - 0.12)
        #expect(trueErrO < 0.003)
        #expect(abs(resO[0].trueThickness - resC[0].trueThickness) < 0.002)
        // La aparente cambia con el ángulo de corte.
        #expect(abs(resO[0].apparentThickness - resC[0].apparentThickness) > 0.005)
    }

    // ────────────────────────────────────────────────────────────────────
    // TEST 4 — Estrato horizontal en pared vertical: aparente = real.
    // (Caso trivial que atrapa errores de signo en la trigonometría.)
    // ────────────────────────────────────────────────────────────────────
    @Test("Estrato horizontal en pared vertical: aparente = real")
    func horizontalStratumApparentEqualsReal() throws {
        let n_s = SIMD3<Float>(0, 1, 0)  // estrato horizontal, dip = 0
        let n_w = StratFixtures.horizontalUnit(azimuth: 90)
        let p_w = SIMD3<Float>(0, 0.5, 0)
        let wallPts = StratFixtures.wallPoints(wallCenter: p_w, n_w: n_w, width: 1.5, height: 1.0, gridU: 40, gridV: 30)
        let profile = try WallProfileBuilder(resolution: 500).build(points: wallPts)

        // Límites horizontales (líneas en la pared a distintas alturas).
        let pB0 = p_w + n_s * 0.12
        let pB1 = p_w
        let b0 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB0, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 4)
        let b1 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB1, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 4)

        let id0 = UUID(); let id1 = UUID()
        var marks: [PixelMark] = []
        for p in b0 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id0, col: px.0, row: px.1)) } }
        for p in b1 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id1, col: px.0, row: px.1)) } }

        let boundaries = try StratumBoundaryPicker().pick(marks: marks, in: profile.orthoImage)
        let stratumPlane = try Plane(point: p_w, normal: SIMD3<Float>(0, 1, 0))
        let results = try ThicknessCalculator().measure(boundaries: boundaries, wallPlane: profile.plane, stratumPlane: stratumPlane, pixelResolution: profile.orthoImage.resolution)

        #expect(results.count == 1)
        let r = results[0]
        // aparente ≈ real (factor de corrección = 1 para manteo 0).
        #expect(abs(r.trueThickness - r.apparentThickness) < 0.001)
        #expect(abs(r.trueThickness - 0.12) < 0.002)
        // dip recuperado ≈ 0.
        #expect(abs(r.dip) < 1.0)
    }

    // ────────────────────────────────────────────────────────────────────
    // TEST 5 — Incertidumbre: al duplicar el ruido, la banda crece.
    // ────────────────────────────────────────────────────────────────────
    @Test("Duplicar el ruido inyectado aumenta la banda de incertidumbre")
    func uncertaintyGrowsWithNoise() throws {
        let dip: Float = 25
        let n_s = StratFixtures.stratumNormal(dip: dip, dipDirection: 130)
        let n_w = StratFixtures.horizontalUnit(azimuth: 130)
        let p_w = SIMD3<Float>(0, 0.5, 0)

        // Límites con ruido gaussiano en la normal del estrato.
        func runWithNoise(_ sigma: Float, seed: UInt64) throws -> Double {
            // Puntos de pared (sigue siendo plana, no importa el σ aquí).
            let wallPts = StratFixtures.wallPoints(wallCenter: p_w, n_w: n_w, width: 1.5, height: 1.0, gridU: 40, gridV: 30)
            let profile = try WallProfileBuilder(resolution: 500).build(points: wallPts)

            let pB0 = p_w + n_s * 0.12
            let pB1 = p_w
            let b0 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB0, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 5)
            let b1 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB1, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 5)

            // Inyectar ruido a lo largo de n_s (simula error de marcación).
            var rng = SplitMix64(seed: seed)
            let nois0 = b0.map { $0 + n_s * (StratFixtures.gaussianNoise(rng: &rng) * sigma) }
            let nois1 = b1.map { $0 + n_s * (StratFixtures.gaussianNoise(rng: &rng) * sigma) }

            let id0 = UUID(); let id1 = UUID()
            var marks: [PixelMark] = []
            for p in nois0 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id0, col: px.0, row: px.1)) } }
            for p in nois1 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id1, col: px.0, row: px.1)) } }

        let boundaries = try StratumBoundaryPicker().pick(marks: marks, in: profile.orthoImage)
        let stratumPlane = StratFixtures.stratumPlane(dip: dip, dipDirection: 130, center: p_w)
        let results = try ThicknessCalculator().measure(boundaries: boundaries, wallPlane: profile.plane, stratumPlane: stratumPlane, pixelResolution: profile.orthoImage.resolution)
            return results[0].uncertainty
        }

        let bandSmall = try runWithNoise(0.002, seed: 7)
        let bandBig = try runWithNoise(0.004, seed: 7)
        // Al duplicar el ruido (2mm → 4mm), la banda estrictamente crece.
        #expect(bandBig > bandSmall)
    }

    // ────────────────────────────────────────────────────────────────────
    // TEST 6 — Reproducibilidad: mismos píxeles → misma potencia bit a bit.
    // ────────────────────────────────────────────────────────────────────
    @Test("Reproducibilidad: mismas marcas producen la misma potencia bit a bit")
    func reproducibilityBitForBit() throws {
        let n_s = StratFixtures.stratumNormal(dip: 25, dipDirection: 130)
        let n_w = StratFixtures.horizontalUnit(azimuth: 130)
        let p_w = SIMD3<Float>(0, 0.5, 0)
        let wallPts = StratFixtures.wallPoints(wallCenter: p_w, n_w: n_w, width: 1.5, height: 1.0, gridU: 40, gridV: 30)
        let profile = try WallProfileBuilder(resolution: 500).build(points: wallPts)

        let pB0 = p_w + n_s * 0.12
        let pB1 = p_w
        let b0 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB0, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 4)
        let b1 = StratFixtures.boundaryLine(n_s: n_s, p_s: pB1, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 4)

        let id0 = UUID(); let id1 = UUID()
        var marks: [PixelMark] = []
        for p in b0 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id0, col: px.0, row: px.1)) } }
        for p in b1 { if let px = pixelOf(p, in: profile.orthoImage) { marks.append(PixelMark(boundaryID: id1, col: px.0, row: px.1)) } }

        let calc = ThicknessCalculator()
        let stratumPlane = StratFixtures.stratumPlane(dip: 25, dipDirection: 130, center: p_w)
        let r1 = try calc.measure(
            boundaries: try StratumBoundaryPicker().pick(marks: marks, in: profile.orthoImage),
            wallPlane: profile.plane,
            stratumPlane: stratumPlane,
            pixelResolution: profile.orthoImage.resolution)
        let r2 = try calc.measure(
            boundaries: try StratumBoundaryPicker().pick(marks: marks, in: profile.orthoImage),
            wallPlane: profile.plane,
            stratumPlane: stratumPlane,
            pixelResolution: profile.orthoImage.resolution)

        // Bit a bit idéntico.
        #expect(r1 == r2)
    }
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers locales (no usar `simd` que no está en Linux).
// ────────────────────────────────────────────────────────────────────────────
private func pixelOf(_ p: SIMD3<Float>, in image: RectifiedOrthoImage) -> (Int, Int)? {
    let rect = Rectifier(resolution: image.resolution)
    return rect.pixel(for: p, in: image)
}

/// Normal de pared rotada `tiltDeg` desde la vertical hacia un azimut dado:
/// n_w = cos(tilt)·hArr(azimut) − sin(tilt)·up. ( tiltDeg=0 → horizontal ).
private func tiltFromVertical(azimuth: Float, tiltDeg: Float) -> SIMD3<Float> {
    let h = StratFixtures.horizontalUnit(azimuth: azimuth)
    let up = SIMD3<Float>(0, 1, 0)
    let r = tiltDeg * .pi / 180
    return h * cos(r) - up * sin(r)
}

private func dipDirectionClose(_ a: Float, _ b: Float, tol: Float) -> Bool {
    var d = a - b
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return abs(d) < tol
}
