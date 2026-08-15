import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F7 — MeshSegmenter. Implementación de MeshSegmenting.
// Flujo: recorte ROI → remoción de plano → componentes conexas →
// OBB por componente → sugerencia automática.
// La automática propone, el humano dispone.
// ═══════════════════════════════════════════════════════════════════════════════

public struct MeshSegmenter: MeshSegmenting, Sendable {

    public init() {}

    public func segment(
        mesh: Mesh,
        roi: OrientedBox?,
        removingPlane: Plane?,
        options: SegmentationOptions
    ) throws(SegmentationError) -> [SegmentedComponent] {

        // 1. Recorte por caja orientada
        let workingMesh: Mesh
        if let box = roi {
            workingMesh = applyROI(mesh, box: box)
        } else {
            workingMesh = mesh
        }
        guard !workingMesh.vertices.isEmpty else { return [] }

        // 2. Remoción del plano de soporte
        let (aboveMesh, _) = removingPlane.map { removePlane(workingMesh, plane: $0) }
            ?? (workingMesh, nil)

        guard !aboveMesh.vertices.isEmpty else { return [] }

        // 3. Componentes conexas
        let components = connectedComponents(aboveMesh, options: options)

        // 4. OBB por componente, filtrado por tamaño mínimo
        var results: [SegmentedComponent] = []
        for comp in components {
            guard comp.count >= options.minComponentSize else { continue }

            let compVerts = comp.map { aboveMesh.vertices[Int($0)] }
            let box = fitOBB(compVerts)

            results.append(SegmentedComponent(
                vertexIndices: comp,
                box: box,
                triangleCount: comp.count / 3
            ))
        }

        return results
    }
}

// MARK: - Operaciones de segmentación

extension MeshSegmenter {

    /// Recorta la malla por una caja orientada. Triángulos con los 3 vértices dentro: incluidos.
    /// Triángulos con algún vértice fuera: excluidos (política `includeComplete`).
    private func applyROI(_ mesh: Mesh, box: OrientedBox) -> Mesh {
        var inMask = [Bool](repeating: false, count: mesh.vertices.count)
        for (i, v) in mesh.vertices.enumerated() {
            if box.contains(v) {
                inMask[i] = true
            }
        }

        var newVertices: [SIMD3<Float>] = []
        var oldToNew: [Int] = Array(repeating: -1, count: mesh.vertices.count)
        var newIndices: [UInt32] = []

        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = Int(mesh.indices[i])
            let i1 = Int(mesh.indices[i+1])
            let i2 = Int(mesh.indices[i+2])
            if i0 < inMask.count && i1 < inMask.count && i2 < inMask.count,
               inMask[i0], inMask[i1], inMask[i2] {
                for vi in [i0, i1, i2] {
                    if oldToNew[vi] < 0 {
                        oldToNew[vi] = newVertices.count
                        newVertices.append(mesh.vertices[vi])
                    }
                    newIndices.append(UInt32(oldToNew[vi]))
                }
            }
        }

        return Mesh(vertices: newVertices, indices: newIndices)
    }

    /// Remueve puntos por encima/por debajo de un plano de soporte.
    /// Retorna: (malla recortada, vértices removidos).
    private func removePlane(_ mesh: Mesh, plane: Plane) -> (Mesh, [UInt32]) {
        let n = plane.normal
        let p0 = plane.point

        // Distancia firmada de cada vértice al plano.
        let distances: [Float] = mesh.vertices.map { v in
            (v.x - p0.x) * n.x + (v.y - p0.y) * n.y + (v.z - p0.z) * n.z
        }

        // Conservar solo vértices por encima del plano (distancia > 0 con margen).
        let margin: Float = 0.005 // 5 mm
        var keep = [Bool](repeating: false, count: mesh.vertices.count)
        for i in 0..<mesh.vertices.count {
            keep[i] = distances[i] > margin
        }

        // Si todos o ninguno quedan, devolver tal cual
        let keepCount = keep.filter { $0 }.count
        if keepCount == 0 || keepCount == mesh.vertices.count {
            return (mesh, [])
        }

        var newVertices: [SIMD3<Float>] = []
        var oldToNew: [Int] = Array(repeating: -1, count: mesh.vertices.count)
        var newIndices: [UInt32] = []
        var removed: [UInt32] = []

        for (i, v) in mesh.vertices.enumerated() {
            if keep[i] {
                oldToNew[i] = newVertices.count
                newVertices.append(v)
            } else {
                removed.append(UInt32(i))
            }
        }

        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = Int(mesh.indices[i]), i1 = Int(mesh.indices[i+1]), i2 = Int(mesh.indices[i+2])
            let k0 = oldToNew[i0], k1 = oldToNew[i1], k2 = oldToNew[i2]
            if k0 >= 0, k1 >= 0, k2 >= 0 {
                newIndices.append(UInt32(k0))
                newIndices.append(UInt32(k1))
                newIndices.append(UInt32(k2))
            }
        }

        return (Mesh(vertices: newVertices, indices: newIndices), removed)
    }

    /// Componentes conexas sobre el grafo de adyacencia de triángulos.
    /// Corte: ángulo diedro y distancia entre caras.
    private func connectedComponents(
        _ mesh: Mesh,
        options: SegmentationOptions
    ) -> [[UInt32]] {
        let faceCount = mesh.triangleCount
        guard faceCount > 0 else { return [] }

        // Construir aristas del grafo de caras
        // Dos caras son adyacentes si comparten al menos un vértice Y
        // el ángulo diedro entre sus normales < maxDihedralAngle Y
        // la distancia mínima entre sus vértices < maxDistance.

        // Para simplificar: adyacencia por vértice compartido con chequeo de
        // ángulo diedro.
        // Índice vértice → caras que lo contienen.
        var vertexToFaces: [Int: [Int]] = [:]
        for f in 0..<faceCount {
            let base = f * 3
            for k in 0..<3 {
                let vi = Int(mesh.indices[base + k])
                vertexToFaces[vi, default: []].append(f)
            }
        }

        // Calcular normales de cara para chequeo de diedro
        var faceNormals: [SIMD3<Float>] = []
        faceNormals.reserveCapacity(faceCount)
        for f in 0..<faceCount {
            let base = f * 3
            let p0 = mesh.vertices[Int(mesh.indices[base])]
            let p1 = mesh.vertices[Int(mesh.indices[base + 1])]
            let p2 = mesh.vertices[Int(mesh.indices[base + 2])]
            let n = vecNormalize(vecCross(p1 - p0, p2 - p0))
            faceNormals.append(n)
        }

        // Union-Find sobre caras
        var parent = Array(0..<faceCount)

        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            // Path compression
            var i = x
            while parent[i] != r {
                let next = parent[i]
                parent[i] = r
                i = next
            }
            return r
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        let cosThreshold = cos(options.maxDihedralAngleDegrees * .pi / 180)

        // Para cada vértice, conectar caras que lo comparten si pasan el filtro
        for (_, faces) in vertexToFaces {
            let n = faces.count
            for i in 0..<n {
                for j in (i+1)..<n {
                    let fi = faces[i], fj = faces[j]
                    let dot = abs(vecDot(faceNormals[fi], faceNormals[fj]))
                    if dot >= cosThreshold {
                        union(fi, fj)
                    }
                }
            }
        }

        // Agrupar por raíz
        var groups: [Int: [UInt32]] = [:]
        for f in 0..<faceCount {
            let root = find(f)
            let base = f * 3
            let idxs = [UInt32(mesh.indices[base]), UInt32(mesh.indices[base+1]), UInt32(mesh.indices[base+2])]
            groups[root, default: []].append(contentsOf: idxs)
        }

        return Array(groups.values)
    }

    /// Ajusta una caja orientada (OBB) a un conjunto de puntos.
    /// Usa PCA simplificada: autovalores de la matriz de covarianza 3x3.
    func fitOBB(_ points: [SIMD3<Float>]) -> OrientedBox {
        guard points.count >= 3 else {
            // Degenerado: caja mínima
            return try! OrientedBox(
                center: points.first ?? .zero,
                axes: Matrix3x3.identity,
                halfExtents: SIMD3(0.01, 0.01, 0.01)
            )
        }

        let n = Float(points.count)
        var sum = SIMD3<Float>.zero
        for p in points { sum += p }
        let centroid = sum / n

        // Matriz de covarianza 3x3 simétrica
        var cov00: Float = 0, cov01: Float = 0, cov02: Float = 0
        var cov11: Float = 0, cov12: Float = 0, cov22: Float = 0

        for p in points {
            let d = p - centroid
            cov00 += d.x * d.x
            cov01 += d.x * d.y
            cov02 += d.x * d.z
            cov11 += d.y * d.y
            cov12 += d.y * d.z
            cov22 += d.z * d.z
        }

        cov00 /= n; cov01 /= n; cov02 /= n
        cov11 /= n; cov12 /= n; cov22 /= n

        // Eigenvalores por Jacobi cíclico (mismo enfoque que OBBFitter)
        var eigvec: [[Float]] = [[1,0,0],[0,1,0],[0,0,1]]
        var m00 = cov00, m01 = cov01, m02 = cov02, m11 = cov11, m12 = cov12, m22 = cov22

        for _ in 0..<20 {
            // Encontrar el mayor elemento fuera de la diagonal
            let abs01 = abs(m01), abs02 = abs(m02), abs12 = abs(m12)
            if abs01 < 1e-12 && abs02 < 1e-12 && abs12 < 1e-12 { break }

            if abs01 >= abs02 && abs01 >= abs12 {
                let tau = (m11 - m00) / (2 * m01)
                let t = if tau >= 0 { 1.0 / (tau + sqrt(1 + tau*tau)) }
                        else { -1.0 / (-tau + sqrt(1 + tau*tau)) }
                let c = 1.0 / sqrt(1 + t*t)
                let s = t * c
                // Rotación en plano 0-1
                let r00 = c*c*m00 + s*s*m11 - 2*s*c*m01
                let r11 = s*s*m00 + c*c*m11 + 2*s*c*m01
                m01 = 0
                let r02 = c*m02 - s*m12
                let r12 = s*m02 + c*m12
                m00 = r00; m11 = r11; m02 = r02; m12 = r12

                for k in 0..<3 {
                    let ek0 = eigvec[k][0], ek1 = eigvec[k][1]
                    eigvec[k][0] = c*ek0 - s*ek1
                    eigvec[k][1] = s*ek0 + c*ek1
                }
            } else if abs02 >= abs12 {
                let tau = (m22 - m00) / (2 * m02)
                let t = if tau >= 0 { 1.0 / (tau + sqrt(1 + tau*tau)) }
                        else { -1.0 / (-tau + sqrt(1 + tau*tau)) }
                let c = 1.0 / sqrt(1 + t*t)
                let s = t * c
                let r00 = c*c*m00 + s*s*m22 - 2*s*c*m02
                let r22 = s*s*m00 + c*c*m22 + 2*s*c*m02
                m02 = 0
                let r01 = c*m01 - s*m12
                let r12_ = s*m01 + c*m12
                m00 = r00; m22 = r22; m01 = r01; m12 = r12_

                for k in 0..<3 {
                    let ek0 = eigvec[k][0], ek2 = eigvec[k][2]
                    eigvec[k][0] = c*ek0 - s*ek2
                    eigvec[k][2] = s*ek0 + c*ek2
                }
            } else {
                let tau = (m22 - m11) / (2 * m12)
                let t = if tau >= 0 { 1.0 / (tau + sqrt(1 + tau*tau)) }
                        else { -1.0 / (-tau + sqrt(1 + tau*tau)) }
                let c = 1.0 / sqrt(1 + t*t)
                let s = t * c
                let r11 = c*c*m11 + s*s*m22 - 2*s*c*m12
                let r22 = s*s*m11 + c*c*m22 + 2*s*c*m12
                m12 = 0
                let r01 = c*m01 - s*m02
                let r02_ = s*m01 + c*m02
                m11 = r11; m22 = r22; m01 = r01; m02 = r02_

                for k in 0..<3 {
                    let ek1 = eigvec[k][1], ek2 = eigvec[k][2]
                    eigvec[k][1] = c*ek1 - s*ek2
                    eigvec[k][2] = s*ek1 + c*ek2
                }
            }
        }

        var evals = SIMD3<Float>(m00, m11, m22)
        // Ordenar por valor propio descendente y sus vectores
        var cols: [SIMD3<Float>] = [
            SIMD3(eigvec[0][0], eigvec[1][0], eigvec[2][0]),
            SIMD3(eigvec[0][1], eigvec[1][1], eigvec[2][1]),
            SIMD3(eigvec[0][2], eigvec[1][2], eigvec[2][2]),
        ]

        // Ordenar por eigenvalor descendente (bubble sort para 3 elementos)
        for i in 0..<2 {
            for j in (i+1)..<3 {
                if evals[j] > evals[i] {
                    let te = evals[i]; evals[i] = evals[j]; evals[j] = te
                    let tc = cols[i]; cols[i] = cols[j]; cols[j] = tc
                }
            }
        }

        // Calcular semiextensiones: proyectar todos los puntos sobre cada eje
        var halfExt = SIMD3<Float>(0, 0, 0)
        for p in points {
            let d = p - centroid
            for a in 0..<3 {
                let proj = abs(vecDot(d, cols[a]))
                if proj > halfExt[a] { halfExt[a] = proj }
            }
        }
        halfExt = SIMD3(max(halfExt.x, 0.001), max(halfExt.y, 0.001), max(halfExt.z, 0.001))

        let axes = Matrix3x3(cols[0], cols[1], cols[2])
        return try! OrientedBox(center: centroid, axes: axes, halfExtents: halfExt)
    }
}