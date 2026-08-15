import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F4 — MeshOps: normales, componentes conexas, decimación por vóxel, reparación
// de orientación y diagnóstico de estanqueidad.
// ═══════════════════════════════════════════════════════════════════════════════

public struct MeshOps: Sendable {
    public init() {}

    /// Normales de cara (producto cruz no normalizado de aristas).
    public func faceNormals(_ mesh: Mesh) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(mesh.triangleCount)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = mesh.vertices[Int(mesh.indices[t])]
            let b = mesh.vertices[Int(mesh.indices[t + 1])]
            let c = mesh.vertices[Int(mesh.indices[t + 2])]
            result.append(vecCross(b - a, c - a))
        }
        return result
    }

    /// Normales de vértice: promedio (no normalizado) de las normales de las caras
    /// incidentes. Devuelve un array por vértice (eventualmente .zero).
    public func computeVertexNormals(_ mesh: Mesh) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = Int(mesh.indices[t])
            let i1 = Int(mesh.indices[t + 1])
            let i2 = Int(mesh.indices[t + 2])
            let a = mesh.vertices[i0]
            let b = mesh.vertices[i1]
            let c = mesh.vertices[i2]
            let n = vecCross(b - a, c - a)
            normals[i0] += n
            normals[i1] += n
            normals[i2] += n
        }
        return normals
    }

    /// Componentes conexas sobre el grafo de adyacencia de triángulos (comparten
    /// un vértice). Devuelve, por componente, la lista de índices de vértice.
    public func connectedComponents(_ mesh: Mesh) -> [[Int]] {
        let vertexCount = mesh.vertices.count
        let faceCount = mesh.triangleCount
        guard faceCount > 0 else { return [] }

        // Adyacencia de vértices: qué caras usan cada vértice.
        var vertexFaces = [[Int]](repeating: [], count: vertexCount)
        for f in 0..<faceCount {
            for k in 0..<3 {
                let vi = Int(mesh.indices[f * 3 + k])
                vertexFaces[vi].append(f)
            }
        }

        var visitedFaces = [Bool](repeating: false, count: faceCount)
        var result: [[Int]] = []

        for start in 0..<faceCount where !visitedFaces[start] {
            var queue = [start]
            visitedFaces[start] = true
            var facesInComponent: [Int] = []
            while !queue.isEmpty {
                let f = queue.removeFirst()
                facesInComponent.append(f)
                for k in 0..<3 {
                    let vi = Int(mesh.indices[f * 3 + k])
                    for neighbor in vertexFaces[vi] where !visitedFaces[neighbor] {
                        visitedFaces[neighbor] = true
                        queue.append(neighbor)
                    }
                }
            }
            var vertices = Set<Int>()
            for f in facesInComponent {
                for k in 0..<3 {
                    vertices.insert(Int(mesh.indices[f * 3 + k]))
                }
            }
            result.append(vertices.sorted())
        }
        return result
    }

    /// Decimación por vóxel: consolida los vértices que caen en la misma celda de
    /// una grilla uniforme (cuantización `spacing`) y remapea las caras. Los
    /// triángulos que colapsan (dos o más vértices en la misma celda) se descartan.
    public func voxelDecimate(_ mesh: Mesh, spacing: Float) throws(MeshError) -> Mesh {
        guard spacing > 0, spacing.isFinite else {
            throw .invalidInput("spacing debe ser > 0")
        }
        guard !mesh.vertices.isEmpty else { throw .invalidInput("malla vacía") }

        // Agrupar por celda cuantizada.
        var cellVertices: [UInt64: [Int]] = [:]
        for (i, v) in mesh.vertices.enumerated() {
            let key = cellKey(v, spacing: spacing)
            cellVertices[key, default: []].append(i)
        }

        // Representante por celda: promedio de los vértices de la celda.
        var cellCenter: [UInt64: SIMD3<Float>] = [:]
        for (key, indices) in cellVertices {
            var sum = SIMD3<Float>.zero
            for idx in indices {
                sum += mesh.vertices[idx]
            }
            cellCenter[key] = sum / Float(indices.count)
        }

        // Mapa vértice original -> índice en el nuevo mesh.
        var remap = [Int: UInt32]()
        var newVertices: [SIMD3<Float>] = []
        var cellToIndex: [UInt64: UInt32] = [:]
        for (i, v) in mesh.vertices.enumerated() {
            let key = cellKey(v, spacing: spacing)
            if let existing = cellToIndex[key] {
                remap[i] = existing
            } else {
                guard let representative = cellCenter[key] else { continue }
                let newIndex = UInt32(newVertices.count)
                newVertices.append(representative)
                cellToIndex[key] = newIndex
                remap[i] = newIndex
            }
        }

        var newIndices: [UInt32] = []
        var triToEdgeFaces: [UInt64: [Int]] = [:]
        var triFaceCount = 0
        // Deduplicar triángulos idénticos (mismo set de 3 vértices colapsados).
        var seenTri: Set<UInt64> = []
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = remap[Int(mesh.indices[t])] ?? UInt32.max
            let b = remap[Int(mesh.indices[t + 1])] ?? UInt32.max
            let c = remap[Int(mesh.indices[t + 2])] ?? UInt32.max
            // Descartar triángulos degenerados (vértices colapsados en una misma celda).
            if a == b || b == c || a == c { continue }
            // Clave canónica: suma de los 3 índices para triángulos duplicados.
            let sorted = [a, b, c].sorted()
            let triKey = (UInt64(sorted[0]) << 42) | (UInt64(sorted[1]) << 21) | UInt64(sorted[2])
            if seenTri.contains(triKey) { continue }
            seenTri.insert(triKey)
            let tri = triFaceCount
            triFaceCount += 1
            newIndices.append(a)
            newIndices.append(b)
            newIndices.append(c)
            for k in 0..<3 {
                let i0 = Int(newIndices[tri * 3 + k])
                let i1 = Int(newIndices[tri * 3 + (k + 1) % 3])
                let key = UInt64(min(i0, i1)) << 32 | UInt64(max(i0, i1))
                triToEdgeFaces[key, default: []].append(tri)
            }
        }

        // Paso manifold: ninguna arista puede ser compartida por más de 2 caras.
        // Iterativo: en cada pasada se descartan las caras de más (conservando las
        // 2 con mayor diedro) hasta que toda arista tenga ≤2 caras vivas.
        var faceDropped = [Bool](repeating: false, count: triFaceCount)
        while true {
            var changed = false
            for (key, faces) in triToEdgeFaces {
                let alive = faces.filter { !faceDropped[$0] }
                guard alive.count > 2 else { continue }
                changed = true
                let a = Int(key >> 32)
                let b = Int(key & 0xFFFFFFFF)
                // Conservar las 2 caras vivas con mayor diedro (normales paralelas).
                var bestPair = (alive[0], alive[1])
                var bestScore: Float = -1
                for i in 0..<alive.count {
                    for j in (i + 1)..<alive.count {
                        func third(_ f: Int) -> SIMD3<Float> {
                            for k in 0..<3 {
                                let idx = Int(newIndices[f * 3 + k])
                                if idx != a && idx != b { return newVertices[idx] }
                            }
                            return .zero
                        }
                        let e = newVertices[b] - newVertices[a]
                        let n1 = vecNormalize(vecCross(e, third(alive[i]) - newVertices[a]))
                        let n2 = vecNormalize(vecCross(e, third(alive[j]) - newVertices[a]))
                        let score = abs(vecDot(n1, n2))
                        if score > bestScore {
                            bestScore = score
                            bestPair = (alive[i], alive[j])
                        }
                    }
                }
                for f in alive where f != bestPair.0 && f != bestPair.1 {
                    faceDropped[f] = true
                }
            }
            if !changed { break }
        }
        var filtered: [UInt32] = []
        filtered.reserveCapacity(newIndices.count)
        for f in 0..<triFaceCount where !faceDropped[f] {
            filtered.append(contentsOf: newIndices[f * 3..<(f * 3 + 3)])
        }
        return Mesh(vertices: newVertices, indices: filtered)
    }

    /// Repara la orientación de las caras: recorre la malla propagando el winding
    /// consistente de un triángulo a sus vecinos que comparten arista. Devuelve la
    /// malla con `indices` reordenados por cara.
    public func fixOrientation(_ mesh: Mesh) -> Mesh {
        let faceCount = mesh.triangleCount
        var visited = [Bool](repeating: false, count: faceCount)
        var newIndices = mesh.indices

        // Arista ordenada (min,max) -> caras que la usan, con el slot local de min.
        var edgeFaces: [UInt64: [(face: Int, minSlot: Int)]] = [:]
        for f in 0..<faceCount {
            for k in 0..<3 {
                let i0 = Int(mesh.indices[f * 3 + k])
                let i1 = Int(mesh.indices[f * 3 + (k + 1) % 3])
                let a = min(i0, i1)
                let b = max(i0, i1)
                let key = UInt64(a) << 32 | UInt64(b)
                edgeFaces[key, default: []].append((f, i0 == a ? k : (k + 1) % 3))
            }
        }

        for seed in 0..<faceCount where !visited[seed] {
            visited[seed] = true
            var queue = [seed]
            while !queue.isEmpty {
                let f = queue.removeFirst()
                for k in 0..<3 {
                    let i0 = Int(newIndices[f * 3 + k])
                    let i1 = Int(newIndices[f * 3 + (k + 1) % 3])
                    let a = min(i0, i1)
                    let b = max(i0, i1)
                    let key = UInt64(a) << 32 | UInt64(b)
                    guard let neighbors = edgeFaces[key] else { continue }
                    for n in neighbors where n.face != f && !visited[n.face] {
                        visited[n.face] = true
                        // Slot local de `a` en el vecino.
                        let nMinSlot = n.minSlot
                        let n0 = Int(newIndices[n.face * 3 + nMinSlot])
                        // El vecino recorre la arista hacia el otro extremo si parte de `a`.
                        // Si en el vecino la arista (a,b) se recorre como a->b en el slot
                        // (nMinSlot -> siguiente), y en f se recorre como (k -> k+1) partiendo
                        // también de a hacia b, entonces ambos apuntan al mismo lado -> voltear.
                        let fGoesAToB = (i0 == a && i1 == b)
                        let nGoesAToB = (n0 == a)
                        if fGoesAToB == nGoesAToB {
                            let base = n.face * 3
                            newIndices.swapAt(base + 1, base + 2)
                        }
                        queue.append(n.face)
                    }
                }
            }
        }
        return Mesh(vertices: mesh.vertices, indices: newIndices, normals: mesh.normals, colors: mesh.colors)
    }

    /// Diagnóstico de estanqueidad: ¿cada arista compartida por exactamente 2 caras?
    public func watertightness(_ mesh: Mesh) -> WatertightnessReport {
        let faceCount = mesh.triangleCount
        var boundaryEdges = 0
        var edgeCount: [UInt64: Int] = [:]
        for f in 0..<faceCount {
            for k in 0..<3 {
                let i0 = Int(mesh.indices[f * 3 + k])
                let i1 = Int(mesh.indices[f * 3 + (k + 1) % 3])
                let a = min(i0, i1)
                let b = max(i0, i1)
                let key = UInt64(a) << 32 | UInt64(b)
                edgeCount[key, default: 0] += 1
            }
        }
        for (_, count) in edgeCount {
            if count != 2 {
                boundaryEdges += 1
            }
        }
        let isWatertight = boundaryEdges == 0
        let euler = mesh.vertices.count - edgeCount.count + faceCount
        return WatertightnessReport(
            isWatertight: isWatertight,
            boundaryEdges: boundaryEdges,
            vertexCount: mesh.vertices.count,
            faceCount: faceCount,
            eulerCharacteristic: euler
        )
    }

    // MARK: - Helpers

    private func cellKey(_ v: SIMD3<Float>, spacing: Float) -> UInt64 {
        let scale = 1 / spacing
        func q(_ c: Float) -> UInt64 {
            UInt64(bitPattern: Int64((c * scale).rounded())) & 0x3FFFFF
        }
        return (q(v.x) << 42) | (q(v.y) << 21) | q(v.z)
    }
}