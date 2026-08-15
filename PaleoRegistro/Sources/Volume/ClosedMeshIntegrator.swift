import Foundation
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// F5 — ClosedMeshIntegrator: teorema de la divergencia sobre malla cerrada.
// V = (1/6)·Σ (v0 × v1)·v2. Es el único correcto para fósiles con socavaciones y
// voladizos. Acumuladores en Double y orden de suma por índice de cara → resultado
// determinista bit a bit sobre la misma malla.
// ═══════════════════════════════════════════════════════════════════════════════

public struct ClosedMeshIntegrator: VolumeIntegrating {
    public static var algorithmVersion: String { "1.0.0" }

    public init() {}

    public func integrate(
        mesh: Mesh,
        reference: ReferenceSurface,
        cellSize: Float,
        emptyCells: EmptyCellStrategy
    ) throws(VolumeError) -> VolumeResult {
        guard !mesh.isEmpty else { throw .emptyMesh }
        guard case .closedSolid = reference else {
            throw .invalidReferenceSurface("closed mesh requiere .closedSolid")
        }

        let report = MeshOps().watertightness(mesh)
        guard report.isWatertight else {
            throw .meshNotClosed
        }
        guard mesh.indices.count % 3 == 0 else {
            throw .invalidReferenceSurface("índices no múltiplo de 3")
        }

        var volume: Double = 0
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[t])
            let ib = Int(mesh.indices[t + 1])
            let ic = Int(mesh.indices[t + 2])
            guard ia < mesh.vertices.count, ib < mesh.vertices.count, ic < mesh.vertices.count else {
                throw .invalidReferenceSurface("índice de triángulo fuera de rango")
            }
            let a = mesh.vertices[ia]
            let b = mesh.vertices[ib]
            let c = mesh.vertices[ic]
            // (a × b) · c en Double.
            let crossX = Double(a.y) * Double(b.z) - Double(a.z) * Double(b.y)
            let crossY = Double(a.z) * Double(b.x) - Double(a.x) * Double(b.z)
            let crossZ = Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x)
            volume += crossX * Double(c.x) + crossY * Double(c.y) + crossZ * Double(c.z)
        }
        volume /= 6

        return VolumeResult(
            positive: volume,
            negative: 0,
            coveredArea: 0,
            filledCellRatio: 1,
            uncertainty: 0,
            method: .closedMesh,
            isInferred: false,
            algorithmVersion: Self.algorithmVersion
        )
    }
}