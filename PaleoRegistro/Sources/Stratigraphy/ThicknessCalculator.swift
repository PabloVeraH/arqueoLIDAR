import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F6 — ThicknessCalculator: potencia aparente → potencia real.
//
// La potencia NO se mide con geometría sola. Los límites de estrato son líneas
// de intersección del plano del estrato con la pared de corte, marcados por el
// operador sobre la orto-imagen 2D. La potencia aparente (a lo largo de la
// máxima pendiente de la pared) sobreestima la real cuando la pared no es
// perpendicular al rumbo del estrato. La corrección trigonométrica usa el
// ángulo diedro entre la pared y el plano del estrato, derivado de las normales:
//
//     t_real = |(p2 − p1) · n_s|                         (perpendicular, invariante)
//     t_aparente = t_real / |d · n_s|                     (a lo largo de d)
//
// donde n_s = normal del plano del estrato (ajustada por mínimos cuadrados
// sobre todos los puntos de todos los límites, que son planos paralelos) y
// d = dirección de máxima pendiente de la pared (proyección de −up).
//
// dip/dipDirection se derivan de n_s en marco de sitio ENU (+X Este, +Y Arriba,
// −Z Norte):
//     dip = arccos(n_s · up)         (0 = horizontal, 90 = vertical)
//     dipDirection = atan2(−n_s.x, n_s.z) mod 360°   (azimut del descenso)
//
// Incertidumbre: banda = sqrt(σ_plano² + σ_pixel²) donde σ_plano = RMS de
// residuos del ajuste del plano del estrato y σ_pixel = 1/resolución (m/px).
// ═══════════════════════════════════════════════════════════════════════════════

/// Grupo de marcas 3D para un mismo límite (boundaryID).
private struct BoundaryGroup {
    var id: UUID
    var points: [SIMD3<Float>]
}

/// Calcula potencias (real y aparente) entre límites consecutivos, con banda de
/// incertidumbre propagada desde el ruido del plano y la resolución de la
/// orto-imagen. Determinista (sin RNG): mismos píxeles → misma potencia bit a bit.
public struct ThicknessCalculator: Sendable {
    public static var algorithmVersion: String { "1.0.0" }

    public init() {}

    /// Mide las potencias entre límites consecutivos.
    ///
    /// El plano del estrato (normal del bedding) se requiere explícitamente: no se
    /// puede recuperar de una sola pared vertical (todos los límites son
    /// coplanares con la pared). Provendrá del ajuste de la cara de estrato
    /// expuesta, de un segundo corte, o de la medición con clínometro. La pared
    /// de corte (vertical) define la dirección de máxima pendiente y la potencia
    /// aparente.
    ///
    /// - Parameters:
    ///   - boundaries: límites marcados (múltiples puntos por boundaryID,
    ///     agrupados automáticamente; cada grupo debe tener ≥2 puntos).
    ///   - wallPlane: plano de la pared de corte (de WallProfileBuilder).
    ///   - stratumPlane: plano del estrato (normal del bedding).
    ///   - pixelResolution: resolución de la orto-imagen en px/m (para σ_pixel).
    /// - Returns: un StratumThickness por par de límites consecutivos, ordenados
    ///   de abajo hacia arriba (por proyección sobre n_s).
    public func measure(
        boundaries: [StratumBoundary],
        wallPlane: Plane,
        stratumPlane: Plane,
        pixelResolution: Float
    ) throws(StratigraphyError) -> [StratumThickness] {
        // Agrupar por boundaryID, preservando el orden de aparición.
        var groups: [BoundaryGroup] = []
        var indexByID: [UUID: Int] = [:]
        for b in boundaries {
            if let i = indexByID[b.boundaryID] {
                groups[i].points.append(b.position)
            } else {
                indexByID[b.boundaryID] = groups.count
                groups.append(BoundaryGroup(id: b.boundaryID, points: [b.position]))
            }
        }
        guard groups.count >= 2 else { throw .invalidBoundaryOrder }
        for g in groups where g.points.count < 2 {
            throw .invalidBoundaryOrder
        }

        // Normal del estrato con componente y ≥ 0 (apuntando "hacia arriba").
        var n_s = stratumPlane.normal
        if n_s.y < 0 { n_s = -n_s }

        // dip y dipDirection en marco ENU (+X Este, +Y Arriba, −Z Norte).
        let up = SIMD3<Float>(0, 1, 0)
        let cos_dip = max(-1.0, min(1.0, Double(n_s.y)))
        let dipDeg = acos(cos_dip) * 180.0 / Double.pi
        let dip = Float(dipDeg)
        var dipDir: Float = 0
        let hLen = sqrt(Double(n_s.x) * Double(n_s.x) + Double(n_s.z) * Double(n_s.z))
        if hLen > 1e-6 {
            let deg = atan2(-Double(n_s.x), Double(n_s.z)) * 180.0 / Double.pi
            let norm = deg < 0 ? deg + 360.0 : deg
            dipDir = Float(norm)
        }

        // Ordenar límites por proyección sobre n_s (de abajo hacia arriba).
        groups.sort { a, b in
            let ca = centroid(a.points)
            let cb = centroid(b.points)
            return vecDot(ca, n_s) < vecDot(cb, n_s)
        }

        // Dirección de máxima pendiente de la pared: proyección de −up sobre el
        // plano de la pared (d ⊥ n_w). Para pared vertical: d = −up.
        let n_w = wallPlane.normal
        let d = vecNormalize(-up + n_w * vecDot(up, n_w))

        // σ_plane: estimada como dispersión de los puntos de cada límite a lo
        // largo de n_s (residuos de la marcación a la perpendicular del estrato).
        var sumSq: Double = 0
        var countPts: Int = 0
        for g in groups {
            let c = centroid(g.points)
            for p in g.points {
                let r = Double(vecDot(p - c, n_s))
                sumSq += r * r
                countPts += 1
            }
        }
        let sigma_plane = countPts > 0 ? sqrt(sumSq / Double(countPts)) : 0
        // σ_pixel: tamaño de píxel en metros. Factor conservador 0.5 (centro).
        let sigma_pixel = Double(1.0 / max(pixelResolution, 1.0)) * 0.5
        let band = sqrt(sigma_plane * sigma_plane + sigma_pixel * sigma_pixel)

        var results: [StratumThickness] = []
        var k = 0
        while k < groups.count - 1 {
            let ptsA = groups[k].points
            let ptsB = groups[k + 1].points
            let cA = centroid(ptsA)
            let cB = centroid(ptsB)
            let trueT = abs(Double(vecDot(cB - cA, n_s)))
            let denom = abs(Double(vecDot(d, n_s)))
            let appT: Double
            if denom < 1e-6 {
                appT = trueT
            } else {
                appT = trueT / denom
            }
            results.append(StratumThickness(
                boundaryA: groups[k].id,
                boundaryB: groups[k + 1].id,
                trueThickness: trueT,
                apparentThickness: appT,
                uncertainty: band,
                dip: dip,
                dipDirection: dipDir,
                method: .correctedTrue,
                algorithmVersion: Self.algorithmVersion
            ))
            k += 1
        }
        return results
    }

    /// Centroide de una lista de puntos (no vacía).
    private func centroid(_ pts: [SIMD3<Float>]) -> SIMD3<Float> {
        var sum = SIMD3<Float>(0, 0, 0)
        for p in pts { sum += p }
        return sum / Float(pts.count)
    }
}
