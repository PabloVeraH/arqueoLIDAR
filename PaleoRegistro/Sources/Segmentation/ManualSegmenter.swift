import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F7 — ManualSegmenter. Herramientas de ajuste manual de segmentación.
// Divide y fusiona componentes (el humano dispone sobre lo propuesto
// por la automática).
// ═══════════════════════════════════════════════════════════════════════════════

public struct ManualSegmenter: Sendable {

    public init() {}

    /// Divide un conjunto de índices de vértices en dos componentes, separados
    /// por un plano de corte definido por el usuario.
    public func split(
        vertices: [SIMD3<Float>],
        indices: [UInt32],
        by plane: Plane
    ) -> (compA: [UInt32], compB: [UInt32]) {

        let n = plane.normal
        let p0 = plane.point

        let dist: [Float] = vertices.map { v in
            (v.x - p0.x) * n.x + (v.y - p0.y) * n.y + (v.z - p0.z) * n.z
        }

        var sideA: Set<UInt32> = []
        var sideB: Set<UInt32> = []

        for idx in indices {
            if dist[Int(idx)] >= 0 {
                sideA.insert(idx)
            } else {
                sideB.insert(idx)
            }
        }

        return (Array(sideA), Array(sideB))
    }

    /// Fusiona dos listas de índices (unión simple).
    public func merge(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        Array(Set(a).union(b))
    }

    /// Recalcula OBB para un subconjunto de índices sobre los vértices
    /// de la malla original.
    public func rebox(
        indices: [UInt32],
        vertices: [SIMD3<Float>]
    ) -> OrientedBox {
        let points = indices.map { vertices[Int($0)] }
        let segmenter = MeshSegmenter()
        return segmenter.fitOBB(points)
    }
}