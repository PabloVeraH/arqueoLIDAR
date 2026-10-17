import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F13 — Apoyo puro del visor: rango de una escala de color que no satura en
// silencio, y simplificación de mallas grandes solo para mirarlas.
// ═══════════════════════════════════════════════════════════════════════════════

/// Rango de colores de un campo escalar (altura, distancia…). Usa percentiles
/// para que unos pocos puntos extremos no aplasten la escala, pero cuenta cuántos
/// quedan fuera para que la leyenda lo diga (plan, Fase 13).
public struct ScalarRange: Sendable, Equatable {
    public var low: Float
    public var high: Float
    public var belowCount: Int
    public var aboveCount: Int
    public var total: Int

    public var clippedFraction: Double { total > 0 ? Double(belowCount + aboveCount) / Double(total) : 0 }

    /// 0…1 dentro de la escala; los valores fuera quedan en el extremo.
    public func normalized(_ value: Float) -> Float {
        guard high > low else { return 0.5 }
        return min(max((value - low) / (high - low), 0), 1)
    }

    public static func robust(_ values: [Float], lowerQuantile: Double = 0.02,
                              upperQuantile: Double = 0.98) -> ScalarRange {
        let finite = values.filter(\.isFinite).sorted()
        guard let first = finite.first, let last = finite.last else {
            return ScalarRange(low: 0, high: 0, belowCount: 0, aboveCount: 0, total: 0)
        }
        func quantile(_ q: Double) -> Float { finite[min(finite.count - 1, Int(Double(finite.count - 1) * q))] }
        var low = quantile(lowerQuantile), high = quantile(upperQuantile)
        if high <= low { low = first; high = last } // campo casi constante
        return ScalarRange(low: low, high: high,
                           belowCount: finite.filter { $0 < low }.count,
                           aboveCount: finite.filter { $0 > high }.count,
                           total: finite.count)
    }
}

extension MeshOps {

    /// Si la malla pasa de `maxTriangles`, la simplifica por vóxeles (duplicando
    /// el tamaño de celda hasta caber) solo para mostrarla. Las mediciones usan
    /// siempre la malla completa.
    public func decimateForDisplay(_ mesh: Mesh, maxTriangles: Int = 1_000_000) -> (mesh: Mesh, simplified: Bool) {
        guard mesh.triangleCount > maxTriangles else { return (mesh, false) }
        var spacing: Float = 0.01
        var current = mesh
        for _ in 0..<12 where current.triangleCount > maxTriangles {
            guard let next = try? voxelDecimate(mesh, spacing: spacing) else { break }
            current = next
            spacing *= 2
        }
        return (current, current.triangleCount < mesh.triangleCount)
    }
}
