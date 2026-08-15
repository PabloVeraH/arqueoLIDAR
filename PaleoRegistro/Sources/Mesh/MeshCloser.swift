import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F4 — MeshCloser: cierra agujeros de borde de una malla mediante triangulación
// en abanico desde un punto interior del bucle (centroide proyectado). Produce
// un sólido cerrado (watertight) cuando el agujero es planar o "estrella".
// ═══════════════════════════════════════════════════════════════════════════════

public struct MeshCloser: MeshClosing {
    public init() {}

    /// Cierra todos los bucles de borde. `against` (plano de apoyo) permite
    /// tapar el agujero contra un plano conocido (caso de excavación), usando el
    /// centroide del bucle proyectado sobre el plano.
    public func close(mesh: Mesh, against plane: Plane?) throws(MeshError) -> (mesh: Mesh, report: WatertightnessReport) {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else {
            throw .invalidInput("malla vacía")
        }
        guard mesh.indices.count % 3 == 0 else {
            throw .invalidInput("índices no múltiplo de 3")
        }

        // 1) Contar aristas de borde (aparecen en exactamente 1 cara).
        var edgeCount: [UInt64: Int] = [:]
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            for k in 0..<3 {
                let i0 = Int(mesh.indices[t + k])
                let i1 = Int(mesh.indices[t + (k + 1) % 3])
                let a = min(i0, i1)
                let b = max(i0, i1)
                let key = UInt64(a) << 32 | UInt64(b)
                edgeCount[key, default: 0] += 1
            }
        }

        // 2) Extraer aristas de borde no dirigidas.
        var boundaryEdges: [(a: Int, b: Int)] = []
        for (key, count) in edgeCount where count == 1 {
            let a = Int(key >> 32)
            let b = Int(key & 0xFFFFFFFF)
            boundaryEdges.append((a, b))
        }
        guard !boundaryEdges.isEmpty else {
            // Ya es watertight.
            let report = MeshOps().watertightness(mesh)
            return (mesh, report)
        }

        // 3) Agrupar aristas de borde en bucles (grafo con grado 2 por vértice).
        var adjacency: [Int: [(Int, Int)]] = [:] // vértice -> [(vecino, edgeIndex)]
        for (idx, e) in boundaryEdges.enumerated() {
            adjacency[e.a, default: []].append((e.b, idx))
            adjacency[e.b, default: []].append((e.a, idx))
        }

        var usedEdge = [Bool](repeating: false, count: boundaryEdges.count)
        var loops: [[Int]] = []
        for (edgeIndex, _) in boundaryEdges.enumerated() where !usedEdge[edgeIndex] {
            var loop: [Int] = []
            var current = boundaryEdges[edgeIndex].a
            var start = current
            loop.append(current)
            usedEdge[edgeIndex] = true
            var currentEdge = edgeIndex
            while true {
                let neighbors = adjacency[current] ?? []
                var next: Int?
                var nextEdge: Int?
                for (nb, ei) in neighbors {
                    if ei == currentEdge { continue }
                    if !usedEdge[ei] {
                        next = nb
                        nextEdge = ei
                        break
                    }
                }
                guard let nb = next, let ne = nextEdge, nb != start else { break }
                usedEdge[ne] = true
                loop.append(nb)
                current = nb
                currentEdge = ne
            }
            if loop.count >= 3 {
                loops.append(loop)
            }
        }

        guard !loops.isEmpty else {
            throw .closingFailed("no se pudieron formar bucles de borde")
        }

        // 4) Cerrar cada bucle.
        var vertices = mesh.vertices
        var indices = mesh.indices
        var addedVertices = 0

        for loop in loops {
            guard loop.count >= 3 else { continue }

            // Centroide del bucle.
            var centroid = SIMD3<Float>.zero
            for vi in loop {
                centroid += vertices[vi]
            }
            centroid /= Float(loop.count)

            // Si se da un plano, proyectar el centroide sobre él.
            if let plane {
                centroid = centroid - plane.normal * vecDot(centroid - plane.point, plane.normal)
            }

            // Verificar que el centroide no coincida con un vértice del bucle.
            var valid = true
            for vi in loop {
                if vecLength(vertices[vi] - centroid) < 1e-6 {
                    valid = false
                    break
                }
            }
            if !valid {
                throw .closingFailed("centroide del bucle coincide con un vértice")
            }

            let centerIndex = UInt32(vertices.count)
            vertices.append(centroid)
            addedVertices += 1

            for k in 0..<loop.count {
                let a = loop[k]
                let b = loop[(k + 1) % loop.count]
                indices.append(UInt32(a))
                indices.append(UInt32(b))
                indices.append(centerIndex)
            }
        }

        let result = Mesh(vertices: vertices, indices: indices, normals: mesh.normals, colors: mesh.colors)
        let report = MeshOps().watertightness(result)
        if !report.isWatertight {
            throw .closingFailed("la malla no quedó watertight tras cerrar")
        }
        return (result, report)
    }
}