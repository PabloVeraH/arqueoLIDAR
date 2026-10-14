import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F11 — DiffEngine. Distancia firmada punto-a-superficie, clustering de
// cambios, volumen ganado/perdido. Requiere transformación de alineación
// previamente calculada.
// ═══════════════════════════════════════════════════════════════════════════════

public struct DiffEngine: MeshDifferencing, Sendable {

    public init() {}

    public func diff(
        baseline: Mesh,
        current: Mesh,
        alignment: AlignmentResult,
        cellSize: Float
    ) throws(RegistrationError) -> DiffResult {

        guard !baseline.isEmpty, !current.isEmpty else {
            throw .invalidInput("Mallas vacías")
        }
        guard !alignment.isDegenerate else {
            throw .degenerate(conditionNumber: alignment.conditionNumber, weakDirections: alignment.weakDirections)
        }

        // Transformar la malla actual al marco de la baseline
        let currentAligned = current.vertices.map { alignment.transform.applyAffine($0) }

        // Construir hash espacial para la baseline
        let baselineHash = SpatialHash2(points: baseline.vertices, cellSize: cellSize * 2)

        // Distancia firmada por punto de la malla actual contra la baseline
        var signedDistances: [Float] = []
        signedDistances.reserveCapacity(currentAligned.count)

        for cp in currentAligned {
            let dist = signedDistanceToMesh(point: cp, target: baseline, hash: baselineHash)
            signedDistances.append(dist)
        }

        // Umbral de cambio significativo
        let noiseFloor = max(3.0 * alignment.rmse, 0.02) // 3·σ_RMSE o 2 cm (ruido LiDAR)

        // Clustering de cambios
        let clusters = findChangeClusters(
            vertices: currentAligned,
            signedDistances: signedDistances,
            threshold: noiseFloor,
            cellSize: cellSize
        )

        // Volumen ganado/perdido: rasterizar ambas mallas a grilla común
        let (lostVol, gainedVol) = computeVolumeChange(
            baseline: baseline,
            current: currentAligned,
            cellSize: cellSize,
            threshold: noiseFloor
        )

        let uncertainty = Double(alignment.rmse) * Double(alignment.rmse) * Double(currentAligned.count).squareRoot() * 0.1

        return DiffResult(
            alignment: alignment,
            signedDistances: signedDistances,
            changeThreshold: noiseFloor,
            lostVolume: lostVol,
            gainedVolume: gainedVol,
            volumeUncertainty: uncertainty,
            clusters: clusters,
            noiseFloor: noiseFloor
        )
    }

    // MARK: - Helpers

    /// Distancia firmada de un punto a la superficie de una malla.
    /// Positiva = punto está "afuera" de la baseline (ganancia).
    /// Negativa = punto está "adentro" de la baseline (pérdida/erosión).
    private func signedDistanceToMesh(
        point: SIMD3<Float>,
        target: Mesh,
        hash: SpatialHash2
    ) -> Float {
        guard hash.nearest(to: point) != nil else { return 0 }

        // Encontrar el triángulo más cercano
        var bestDist: Float = .infinity
        var bestSign: Float = 1

        for f in 0..<target.triangleCount {
            let base = f * 3
            let i0 = Int(target.indices[base])
            let i1 = Int(target.indices[base + 1])
            let i2 = Int(target.indices[base + 2])

            let v0 = target.vertices[i0]
            let v1 = target.vertices[i1]
            let v2 = target.vertices[i2]

            let (dist, sign) = pointToTriangleDistance(point, v0, v1, v2)
            if abs(dist) < abs(bestDist) {
                bestDist = dist
                bestSign = sign
            }
        }

        return bestDist * bestSign
    }

    /// Distancia punto → triángulo con signo usando la normal de la cara.
    private func pointToTriangleDistance(
        _ p: SIMD3<Float>,
        _ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>
    ) -> (dist: Float, sign: Float) {
        let normal = vecNormalize(vecCross(v1 - v0, v2 - v0))
        let d = vecDot(p - v0, normal)
        let sign: Float = d >= 0 ? 1 : -1

        // Proyectar p al plano del triángulo
        let proj = p - normal * d

        // Determinar si la proyección cae dentro del triángulo (baricéntricas)
        let u = v1 - v0
        let v = v2 - v0
        let w = proj - v0

        let uu = vecDot(u, u)
        let uv = vecDot(u, v)
        let vv = vecDot(v, v)
        let wu = vecDot(w, u)
        let wv = vecDot(w, v)

        let denom = uv * uv - uu * vv
        if abs(denom) < 1e-12 {
            // Triángulo degenerado
            return (vecLength(p - v0), sign)
        }

        let invDenom = 1.0 / denom
        var s = (uv * wv - vv * wu) * invDenom
        var t = (uv * wu - uu * wv) * invDenom

        s = max(0, min(1, s))
        t = max(0, min(1, t))

        if s + t <= 1 {
            // Dentro del triángulo
            return (abs(d), sign)
        } else {
            // Fuera: distancia mínima a los bordes/vértices
            let edge1 = closestPointOnSegment(p, v0, v1)
            let edge2 = closestPointOnSegment(p, v1, v2)
            let edge3 = closestPointOnSegment(p, v2, v0)
            let d1 = vecLength(p - edge1)
            let d2 = vecLength(p - edge2)
            let d3 = vecLength(p - edge3)
            let bestDist = d1 < d2 ? (d1 < d3 ? d1 : d3) : (d2 < d3 ? d2 : d3)
            return (bestDist, sign)
        }
    }

    private func closestPointOnSegment(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        let ab = b - a
        let t = max(0, min(1, vecDot(p - a, ab) / max(vecDot(ab, ab), 1e-12)))
        return a + ab * t
    }

    /// Encuentra clusters de cambio significativo por componentes conexas en espacio.
    private func findChangeClusters(
        vertices: [SIMD3<Float>],
        signedDistances: [Float],
        threshold: Float,
        cellSize: Float
    ) -> [ChangeCluster] {
        // Filtrar puntos con cambio significativo
        var changedIndices: [Int] = []
        for (i, d) in signedDistances.enumerated() {
            if abs(d) > threshold { changedIndices.append(i) }
        }

        guard changedIndices.count >= 3 else { return [] }

        // Agrupar por proximidad espacial (celdas de hash)
        let hashCellSize = cellSize * 3
        var cellToPoints: [SIMD3<Int>: [Int]] = [:]
        for idx in changedIndices {
            let v = vertices[idx]
            let key = SIMD3<Int>(
                Int(floor(v.x / hashCellSize)),
                Int(floor(v.y / hashCellSize)),
                Int(floor(v.z / hashCellSize))
            )
            cellToPoints[key, default: []].append(idx)
        }

        // Union-Find sobre celdas adyacentes
        let cells = Array(cellToPoints.keys)
        var parent = Array(0..<cells.count)

        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            return r
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        for i in 0..<cells.count {
            for j in (i+1)..<cells.count {
                let ci = cells[i], cj = cells[j]
                if abs(ci.x - cj.x) <= 1 && abs(ci.y - cj.y) <= 1 && abs(ci.z - cj.z) <= 1 {
                    union(i, j)
                }
            }
        }

        // Construir clusters
        var clusters: [ChangeCluster] = []
        var rootToCluster: [Int: (centroid: SIMD3<Float>, sumDist: Float, count: Int, sign: Float)] = [:]

        for (cellIdx, cell) in cells.enumerated() {
            let root = find(cellIdx)
            let points = cellToPoints[cell] ?? []
            var sumPos = SIMD3<Float>.zero
            var sumD: Float = 0
            var totalSign: Float = 0
            for idx in points {
                sumPos += vertices[idx]
                sumD += abs(signedDistances[idx])
                totalSign += signedDistances[idx]
            }
            _ = Float(points.count)
            var entry = rootToCluster[root] ?? (.zero, 0, 0, 0)
            entry.centroid += sumPos
            entry.sumDist += sumD
            entry.count += points.count
            entry.sign += totalSign
            rootToCluster[root] = entry
        }

        for (_, entry) in rootToCluster where entry.count >= 5 {
            let n = Float(entry.count)
            let centroid = entry.centroid / n
            let volume = Double(entry.sumDist) * Double(cellSize * cellSize) // aproximación
            let sign: ChangeSign = entry.sign < 0 ? .lost : .gained
            clusters.append(ChangeCluster(
                centroid: centroid,
                volume: volume,
                vertexCount: entry.count,
                sign: sign
            ))
        }

        return clusters
    }

    /// Eje fuera-de-plano de una superficie de referencia: el componente de su
    /// normal con mayor magnitud. Los otros dos ejes forman el plano de la
    /// grilla de rasterización. Cubre los tres casos posibles (suelo con
    /// normal ≈ Y, pared con normal ≈ Z o ≈ X) — antes solo se distinguían
    /// dos casos con un booleano, y el tercero (normal ≈ X) quedaba mal
    /// proyectado en silencio igual que el caso Y original.
    private enum ReferenceAxis { case x, y, z }

    private func dominantAxis(of normal: SIMD3<Float>) -> ReferenceAxis {
        let a = SIMD3<Float>(abs(normal.x), abs(normal.y), abs(normal.z))
        if a.x >= a.y && a.x >= a.z { return .x }
        if a.y >= a.z { return .y }
        return .z
    }

    /// Coordenadas de grilla (los dos ejes en el plano) y "altura" (el eje
    /// fuera de plano) de un punto, dado el eje de referencia de la
    /// superficie contra la que se mide el cambio.
    private func gridKeyAndHeight(_ v: SIMD3<Float>, axis: ReferenceAxis, cellSize: Float) -> (key: SIMD2<Int>, height: Float) {
        switch axis {
        case .x: return (SIMD2(Int(floor(v.y / cellSize)), Int(floor(v.z / cellSize))), v.x)
        case .y: return (SIMD2(Int(floor(v.x / cellSize)), Int(floor(v.z / cellSize))), v.y)
        case .z: return (SIMD2(Int(floor(v.x / cellSize)), Int(floor(v.y / cellSize))), v.z)
        }
    }

    /// Rasteriza ambas mallas a una grilla común y calcula volumen ganado/perdido.
    private func computeVolumeChange(
        baseline: Mesh,
        current: [SIMD3<Float>],
        cellSize: Float,
        threshold: Float
    ) -> (lost: Double, gained: Double) {

        // Proyecta sobre el plano perpendicular a la normal dominante de la
        // baseline: suelo/montículo (normal ≈ Y) se rasteriza sobre (x,z) con
        // altura y; pared vertical (normal ≈ Z o ≈ X) se rasteriza sobre el
        // plano correspondiente con la normal como altura.
        let normal = dominantPlaneNormal(baseline.vertices)
        let axis = dominantAxis(of: normal)

        var gridBaseline: [SIMD2<Int>: Float] = [:]
        var gridCurrent: [SIMD2<Int>: Float] = [:]

        for v in baseline.vertices {
            let (key, h) = gridKeyAndHeight(v, axis: axis, cellSize: cellSize)
            gridBaseline[key] = max(gridBaseline[key] ?? -.infinity, h)
        }

        for v in current {
            let (key, h) = gridKeyAndHeight(v, axis: axis, cellSize: cellSize)
            gridCurrent[key] = max(gridCurrent[key] ?? -.infinity, h)
        }

        var lost: Double = 0
        var gained: Double = 0
        let cellArea = Double(cellSize * cellSize)

        // Celdas donde baseline tiene dato
        for (key, hBase) in gridBaseline {
            let hCurr = gridCurrent[key] ?? hBase
            let diff = Double(hCurr - hBase)
            if diff < -Double(threshold) { lost += abs(diff) * cellArea }
            else if diff > Double(threshold) { gained += diff * cellArea }
        }

        // Celdas solo en current (ganancia pura)
        for (key, hCurr) in gridCurrent where gridBaseline[key] == nil {
            gained += Double(hCurr) * cellArea
        }

        return (lost, gained)
    }

    private func dominantPlaneNormal(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard points.count >= 3 else { return SIMD3(0, 0, 1) }

        var cov00: Float = 0, cov01: Float = 0, cov02: Float = 0
        var cov11: Float = 0, cov12: Float = 0, cov22: Float = 0

        var sum = SIMD3<Float>.zero
        for p in points { sum += p }
        let c = sum / Float(points.count)

        for p in points {
            let d = p - c
            cov00 += d.x * d.x
            cov01 += d.x * d.y
            cov02 += d.x * d.z
            cov11 += d.y * d.y
            cov12 += d.y * d.z
            cov22 += d.z * d.z
        }

        // Eigenvector del menor autovalor por iteración de potencia inversa
        // Simplificación: devolver el eje con menor varianza
        let vars = SIMD3<Float>(cov00, cov11, cov22)
        if vars.x <= vars.y && vars.x <= vars.z { return SIMD3(1, 0, 0) }
        if vars.y <= vars.z { return SIMD3(0, 1, 0) }
        return SIMD3(0, 0, 1)
    }
}

// MARK: - Spatial Hash (duplicado local para independencia de módulo)

private struct SpatialHash2 {
    private var grid: [SIMD3<Int>: [Int]] = [:]
    private let points: [SIMD3<Float>]
    private let cellSize: Float

    init(points: [SIMD3<Float>], cellSize: Float) {
        self.points = points
        self.cellSize = cellSize
        for (i, p) in points.enumerated() {
            let key = SIMD3<Int>(
                Int(floor(p.x / cellSize)),
                Int(floor(p.y / cellSize)),
                Int(floor(p.z / cellSize))
            )
            grid[key, default: []].append(i)
        }
    }

    func nearest(to query: SIMD3<Float>) -> Int? {
        let key = SIMD3<Int>(
            Int(floor(query.x / cellSize)),
            Int(floor(query.y / cellSize)),
            Int(floor(query.z / cellSize))
        )
        var bestIdx: Int?
        var bestDist: Float = .infinity
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let nKey = SIMD3<Int>(key.x + dx, key.y + dy, key.z + dz)
                    guard let candidates = grid[nKey] else { continue }
                    for idx in candidates {
                        let d2 = vecDistSq(query, points[idx])
                        if d2 < bestDist { bestDist = d2; bestIdx = idx }
                    }
                }
            }
        }
        return bestIdx
    }

    private func vecDistSq(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return d.x * d.x + d.y * d.y + d.z * d.z
    }
}