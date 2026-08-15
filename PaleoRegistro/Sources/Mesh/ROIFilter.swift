import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F4 — ROIFilter: recorte de malla por caja orientada (OBB). Política para los
// triángulos cortados por el borde: incluir completo, excluir completo, o partir.
// ═══════════════════════════════════════════════════════════════════════════════

/// Política para triángulos que cruzan el borde del ROI.
public enum ROIPolicy: Sendable, Equatable {
    /// Conserva el triángulo completo si TODOS sus vértices están dentro.
    case includeComplete
    /// Conserva el triángulo solo si todos sus vértices están dentro (equivale a include).
    case exclude
    /// Corta el triángulo por el borde y conserva la parte interior.
    case split
}

/// Recorte de mallas por región de interés (caja orientada).
public struct ROIFilter: Sendable {
    public init() {}

    /// Filtra la malla a los triángulos contenidos en la caja orientada.
    public func filter(mesh: Mesh, to box: OrientedBox, policy: ROIPolicy = .includeComplete) -> Mesh {
        switch policy {
        case .includeComplete, .exclude:
            return filterAllVerticesInside(mesh: mesh, box: box)
        case .split:
            return splitAtBoundary(mesh: mesh, box: box)
        }
    }

    // MARK: - include/exclude

    /// Conserva un triángulo solo si sus tres vértices están dentro de la caja.
    private func filterAllVerticesInside(mesh: Mesh, box: OrientedBox) -> Mesh {
        var newVertices: [SIMD3<Float>] = []
        var remap: [UInt32: UInt32] = [:]
        newVertices.reserveCapacity(mesh.vertices.count)

        func mapped(_ old: UInt32) -> UInt32? {
            if let newIndex = remap[old] { return newIndex }
            let idx = Int(old)
            guard idx < mesh.vertices.count else { return nil }
            let vertex = mesh.vertices[idx]
            guard box.contains(vertex) else { return nil }
            let newIndex = UInt32(newVertices.count)
            newVertices.append(vertex)
            remap[old] = newIndex
            return newIndex
        }

        var newIndices: [UInt32] = []
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            guard let a = mapped(mesh.indices[t]),
                  let b = mapped(mesh.indices[t + 1]),
                  let c = mapped(mesh.indices[t + 2]) else { continue }
            newIndices.append(a)
            newIndices.append(b)
            newIndices.append(c)
        }
        return Mesh(vertices: newVertices, indices: newIndices)
    }

    // MARK: - split

    /// Corta los triángulos contra la caja (6 semi-espacios) y conserva la parte interior.
    private func splitAtBoundary(mesh: Mesh, box: OrientedBox) -> Mesh {
        let axes = [box.axes[0], box.axes[1], box.axes[2]]
        let half = box.halfExtents

        // Cada semi-espacio interior: dot(p - center, axis) <= half.
        func clipPolygon(_ polygon: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var poly = polygon
            for i in 0..<3 {
                let axis = axes[i]
                let limit = half[i]
                for sign: Float in [1, -1] {
                    poly = clipAgainstHalfspace(poly, axis: axis, sign: sign, limit: limit, center: box.center)
                    if poly.count < 3 { return [] }
                }
            }
            return poly
        }

        // Nuevos vértices (incluyendo intersecciones con el borde).
        var newVertices: [SIMD3<Float>] = []
        var remap: [SIMD3<Float>: UInt32] = [:]
        func vertexIndex(_ p: SIMD3<Float>) -> UInt32 {
            if let existing = remap[p] { return existing }
            let idx = UInt32(newVertices.count)
            newVertices.append(p)
            remap[p] = idx
            return idx
        }

        var newIndices: [UInt32] = []
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let tri = [mesh.vertices[Int(mesh.indices[t])],
                       mesh.vertices[Int(mesh.indices[t + 1])],
                       mesh.vertices[Int(mesh.indices[t + 2])]]
            // Clasificación rápida: si los 3 están dentro, se conserva completo.
            if tri.allSatisfy({ box.contains($0) }) {
                for v in tri {
                    newIndices.append(vertexIndex(v))
                }
                continue
            }
            // Si los 3 están fuera, se descarta.
            if tri.allSatisfy({ !box.contains($0) }) {
                continue
            }
            // Mezclado: cortar por los 6 semi-espacios.
            let clipped = clipPolygon(tri)
            guard clipped.count >= 3 else { continue }
            // Triangulación en abanico desde el primer vértice.
            let base = vertexIndex(clipped[0])
            for k in 1..<(clipped.count - 1) {
                newIndices.append(base)
                newIndices.append(vertexIndex(clipped[k]))
                newIndices.append(vertexIndex(clipped[k + 1]))
            }
        }
        return Mesh(vertices: newVertices, indices: newIndices)
    }

    /// Sutherland–Hodgman: recorta el polígono contra dot(p-center, axis)*sign <= limit.
    private func clipAgainstHalfspace(
        _ polygon: [SIMD3<Float>],
        axis: SIMD3<Float>,
        sign: Float,
        limit: Float,
        center: SIMD3<Float>
    ) -> [SIMD3<Float>] {
        guard polygon.count >= 3 else { return [] }
        var output: [SIMD3<Float>] = []
        for i in 0..<polygon.count {
            let cur = polygon[i]
            let nxt = polygon[(i + 1) % polygon.count]
            let curD = sign * vecDot(cur - center, axis) - limit
            let nxtD = sign * vecDot(nxt - center, axis) - limit
            let curInside = curD <= 0
            let nxtInside = nxtD <= 0

            if curInside {
                output.append(cur)
                if !nxtInside {
                    if let inter = intersection(cur, nxt, curD, nxtD) {
                        output.append(inter)
                    }
                }
            } else if nxtInside {
                if let inter = intersection(cur, nxt, curD, nxtD) {
                    output.append(inter)
                }
            }
        }
        return output
    }

    private func intersection(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>,
        _ da: Float, _ db: Float
    ) -> SIMD3<Float>? {
        let denom = da - db
        guard abs(denom) > 1e-12 else { return nil }
        let t = da / denom
        return a + (b - a) * t
    }
}