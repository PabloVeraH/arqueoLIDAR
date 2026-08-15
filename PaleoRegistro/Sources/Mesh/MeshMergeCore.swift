import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F4 — Fusión de piezas de malla (los ARMeshAnchor de la sesión) en un único
// Mesh en coordenadas de mundo, con desduplicación de vértices por posición
// cuantizada y remapeo de caras.
// ═══════════════════════════════════════════════════════════════════════════════

/// Una pieza de malla sin dependencia de ARKit: vértices locales, transform y caras.
public struct MeshPart: Sendable {
    public var transform: Matrix4x4
    public var localVertices: [SIMD3<Float>]
    /// Índices de vértice (local) por cara, en secuencia (3 por triángulo).
    public var faceIndices: [UInt32]
    public var indexCountPerPrimitive: Int

    public init(
        transform: Matrix4x4,
        localVertices: [SIMD3<Float>],
        faceIndices: [UInt32],
        indexCountPerPrimitive: Int = 3
    ) {
        self.transform = transform
        self.localVertices = localVertices
        self.faceIndices = faceIndices
        self.indexCountPerPrimitive = indexCountPerPrimitive
    }
}

/// Fusiona piezas de malla en un único `Mesh` en coordenadas de mundo.
///
/// - Desduplica vértices entre piezas por posición cuantizada (configurable).
/// - Opcionalmente subsamplea vértices (stride) para reducir el tamaño.
/// - Las caras que referencian un vértice descartado por el stride se remapean al
///   vértice muestreado más cercano, preservando la topología del volumen.
public struct MeshMergerCore: Sendable {
    public struct Config: Sendable, Equatable {
        /// Subsamplea vértices (true) o conserva todos (false).
        public var simplify: Bool
        /// Espaciado objetivo entre vértices conservados en metros.
        public var simplifySpacing: Float
        public var minVertexSpacing: Float
        public var maxVertexSpacing: Float
        /// Cuantización para la desduplicación de vértices (metros).
        public var dedupQuantization: Float

        public init(
            simplify: Bool = false,
            simplifySpacing: Float = 0,
            minVertexSpacing: Float = 0.005,
            maxVertexSpacing: Float = 0.05,
            dedupQuantization: Float = 0.001
        ) {
            self.simplify = simplify
            self.simplifySpacing = simplifySpacing
            self.minVertexSpacing = minVertexSpacing
            self.maxVertexSpacing = maxVertexSpacing
            self.dedupQuantization = dedupQuantization
        }

        public static let `default` = Config()
        public static let performance = Config(
            simplify: true,
            simplifySpacing: 0.01
        )
    }

    public init() {}

    public func merge(parts: [MeshPart], config: Config = .default) -> Mesh {
        guard !parts.isEmpty else { return Mesh(vertices: [], indices: []) }

        var vertices: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var lookup: [UInt64: Int] = [:]

        for part in parts {
            let vertexCount = part.localVertices.count
            let indicesPerFace = part.indexCountPerPrimitive
            guard vertexCount > 0, indicesPerFace >= 3, !part.faceIndices.isEmpty else { continue }
            let samplingStride = effectiveStride(for: config)

            // 1) Desduplicar vértices muestreados y transformarlos a mundo.
            var keptMerged: [Int] = []
            keptMerged.reserveCapacity(vertexCount / samplingStride + 1)
            for localIndex in stride(from: 0, to: vertexCount, by: samplingStride) {
                let local = part.localVertices[localIndex]
                let world = part.transform.applyAffine(local)
                let key = dedupKey(world, quantization: config.dedupQuantization)
                if let existing = lookup[key] {
                    keptMerged.append(existing)
                } else {
                    let newIndex = vertices.count
                    vertices.append(world)
                    lookup[key] = newIndex
                    keptMerged.append(newIndex)
                }
            }

            // 2) Emitir caras. Un triángulo con algún índice fuera de rango se descarta
            //    COMPLETO (no parcial) para no desalinear los triples de `indices`.
            let faceCount = part.faceIndices.count / indicesPerFace
            var remapped = [UInt32](repeating: 0, count: indicesPerFace)
            for face in 0..<faceCount {
                var valid = true
                for k in 0..<indicesPerFace {
                    let localIndex = Int(part.faceIndices[face * indicesPerFace + k])
                    guard localIndex >= 0, localIndex < vertexCount else {
                        valid = false
                        break
                    }
                    let keptSlot = max(0, min(keptMerged.count - 1, (localIndex + samplingStride / 2) / samplingStride))
                    remapped[k] = UInt32(keptMerged[keptSlot])
                }
                if valid {
                    indices.append(contentsOf: remapped)
                }
            }
        }

        return Mesh(vertices: vertices, indices: indices)
    }

    // MARK: - Helpers

    private func effectiveStride(for config: Config) -> Int {
        guard config.simplify else { return 1 }
        let spacing = min(max(config.simplifySpacing, config.minVertexSpacing),
                          config.maxVertexSpacing)
        return max(1, Int((spacing / config.dedupQuantization).rounded()))
    }

    /// Clave de 64 bits: 3 componentes de ~21 bits (cuantizadas).
    private func dedupKey(_ position: SIMD3<Float>, quantization: Float) -> UInt64 {
        guard quantization > 0 else { return 0 }
        let scale = 1 / quantization
        func quantized(_ component: Float) -> UInt64 {
            UInt64(bitPattern: Int64((component * scale).rounded())) & 0x1FFFFF
        }
        return (quantized(position.x) << 42) | (quantized(position.y) << 21) | quantized(position.z)
    }
}