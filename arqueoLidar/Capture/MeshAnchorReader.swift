import ARKit
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// F3 — MeshAnchorReader: convierte los buffers de ARMeshGeometry (Metal) en
// tipos de dominio. Ningún tipo de Domain/ importa ARKit: la frontera está aquí.
// ═══════════════════════════════════════════════════════════════════════════════

nonisolated enum MeshAnchorReader {

    /// Pieza de malla en coordenadas locales del ancla + su transformación al
    /// mundo, lista para `MeshMergerCore.merge`.
    static func part(from anchor: ARMeshAnchor) -> MeshPart {
        let geometry = anchor.geometry
        return MeshPart(
            transform: matrix(anchor.transform),
            localVertices: localVertices(geometry),
            faceIndices: faceIndices(geometry),
            indexCountPerPrimitive: geometry.faces.indexCountPerPrimitive
        )
    }

    /// Vértices del ancla ya transformados a coordenadas de mundo.
    static func worldVertices(of anchor: ARMeshAnchor) -> [SIMD3<Float>] {
        let t = anchor.transform
        return localVertices(anchor.geometry).map { v in
            let w = t * SIMD4<Float>(v.x, v.y, v.z, 1)
            return SIMD3<Float>(w.x, w.y, w.z)
        }
    }

    static func localVertices(_ geometry: ARMeshGeometry) -> [SIMD3<Float>] {
        let source = geometry.vertices
        let base = source.buffer.contents()
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(source.count)
        for i in 0..<source.count {
            // float3 empaquetado (12 bytes): se lee como tupla, no como SIMD3 (16 bytes).
            let p = base.loadUnaligned(fromByteOffset: source.offset + source.stride * i, as: (Float, Float, Float).self)
            out.append(SIMD3<Float>(p.0, p.1, p.2))
        }
        return out
    }

    static func faceIndices(_ geometry: ARMeshGeometry) -> [UInt32] {
        let faces = geometry.faces
        let n = faces.count * faces.indexCountPerPrimitive
        let base = faces.buffer.contents()
        var out: [UInt32] = []
        out.reserveCapacity(n)
        if faces.bytesPerIndex == 2 {
            for i in 0..<n { out.append(UInt32(base.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))) }
        } else {
            for i in 0..<n { out.append(base.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)) }
        }
        return out
    }

    static func matrix(_ m: simd_float4x4) -> Matrix4x4 {
        Matrix4x4(m.columns.0, m.columns.1, m.columns.2, m.columns.3)
    }
}
