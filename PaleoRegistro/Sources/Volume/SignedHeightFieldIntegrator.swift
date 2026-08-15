import Foundation
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// F5 — SignedHeightFieldIntegrator: generalización del integrador de grilla de
// StockIA. En vez de una sola grilla con `max(0, h)`, mantiene dos envolventes por
// celda: `upper` (máxima altura sobre la referencia) y `lower` (mínima altura bajo
// la referencia). Reporta positivo y negativo por separado, nunca el neto solo.
// ═══════════════════════════════════════════════════════════════════════════════

/// Integración por campo de alturas firmado contra una `ReferenceSurface` plana.
///
/// Cada celda guarda dos envolventes: la altura máxima positiva y la mínima
/// negativa respecto de la referencia. Esto corrige el defecto conocido del
/// integrador original de StockIA (`max(0, h)`), que colapsaría una zanja bajo el
/// plano a volumen cero: aquí la zanja produce `negative > 0`.
public struct SignedHeightFieldIntegrator: VolumeIntegrating {
    public static var algorithmVersion: String { "1.0.0" }

    private struct Cell: Hashable {
        let i: Int
        let j: Int
    }

    public init() {}

    public func integrate(
        mesh: Mesh,
        reference: ReferenceSurface,
        cellSize: Float,
        emptyCells: EmptyCellStrategy
    ) throws(VolumeError) -> VolumeResult {
        guard !mesh.isEmpty else { throw .emptyMesh }
        guard cellSize > 0, cellSize.isFinite else { throw .invalidCellSize(cellSize) }

        guard case .plane(let plane) = reference else {
            throw .invalidReferenceSurface("height field requiere .plane")
        }
        let n = plane.normal
        guard vecLength(n) > 0.5 else {
            throw .invalidReferenceSurface("plano con normal degenerada")
        }
        let (u, v) = Self.orthonormalBasis(n)

        // Proyección: u, v en el plano de referencia, h firmada (+ sobre el plano).
        var upper: [Cell: Double] = [:]
        var lower: [Cell: Double] = [:]
        for p in mesh.vertices {
            let off = p - plane.point
            let uu = Double(vecDot(off, u))
            let vv = Double(vecDot(off, v))
            let h = Double(vecDot(off, n))
            let key = Cell(i: Self.cellIndex(Float(uu), cellSize: cellSize), j: Self.cellIndex(Float(vv), cellSize: cellSize))
            if h >= 0 {
                upper[key] = max(upper[key] ?? 0, h)
            } else {
                lower[key] = min(lower[key] ?? 0, h)
            }
        }

        guard !upper.isEmpty || !lower.isEmpty else {
            throw .notEnoughData("ningún vértice proyectado sobre la grilla")
        }

        // Rasterización de triángulos: interpolar la altura firmada sobre el
        // footprint 2D de cada triángulo y mezclarla con las envolventes.
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            let ia = Int(mesh.indices[t])
            let ib = Int(mesh.indices[t + 1])
            let ic = Int(mesh.indices[t + 2])
            guard ia < mesh.vertices.count, ib < mesh.vertices.count, ic < mesh.vertices.count else {
                throw .invalidReferenceSurface("índice de triángulo fuera de rango")
            }
            let a = Self.project(mesh.vertices[ia], plane: plane, u: u, v: v, n: n, cellSize: cellSize)
            let b = Self.project(mesh.vertices[ib], plane: plane, u: u, v: v, n: n, cellSize: cellSize)
            let c = Self.project(mesh.vertices[ic], plane: plane, u: u, v: v, n: n, cellSize: cellSize)

            let loI = min(a.i, min(b.i, c.i))
            let hiI = max(a.i, max(b.i, c.i))
            let loJ = min(a.j, min(b.j, c.j))
            let hiJ = max(a.j, max(b.j, c.j))

            let coeffs = Self.planeCoefficients(a, b, c)
            for i in loI...hiI {
                for j in loJ...hiJ {
                    let cx = (Float(i) + 0.5) * cellSize
                    let cy = (Float(j) + 0.5) * cellSize
                    guard Self.pointInTriangle(px: cx, py: cy, a, b, c) else { continue }
                    let h = Double(coeffs.A) * Double(cx) + Double(coeffs.B) * Double(cy) + Double(coeffs.C)
                    let key = Cell(i: i, j: j)
                    if h >= 0 {
                        upper[key] = max(upper[key] ?? 0, h)
                    } else {
                        lower[key] = min(lower[key] ?? 0, h)
                    }
                }
            }
        }

        var positive: Double = 0
        var negative: Double = 0
        switch emptyCells {
        case .ignore:
            positive = Self.sumEnvelope(upper)
            negative = Self.sumEnvelope(lower)
        case .fillInteriorHoles:
            Self.fillInteriorHoles(&upper)
            Self.fillInteriorHoles(&lower)
            positive = Self.sumEnvelope(upper)
            negative = Self.sumEnvelope(lower)
        }

        // Cobertura: unión de celdas con alguna envolvente.
        var covered = Set<Cell>(upper.keys)
        covered.formUnion(lower.keys)

        let cellArea = Double(cellSize) * Double(cellSize)
        let volPositive = positive * cellArea
        let volNegative = abs(negative) * cellArea

        // filledCellRatio: celdas con datos sobre el bbox de cobertura.
        let filled = covered.count
        let total = Self.bboxCellCount(covered)
        let ratio = total > 0 ? Double(filled) / Double(total) : 0

        // Incertidumbre: media celda de error de discretización por columna.
        let uncertainty = 0.5 * Double(cellSize) * Double(covered.count)

        return VolumeResult(
            positive: volPositive,
            negative: volNegative,
            coveredArea: Double(filled) * cellArea,
            filledCellRatio: ratio,
            uncertainty: uncertainty,
            method: .heightField,
            isInferred: false,
            algorithmVersion: Self.algorithmVersion
        )
    }

    // MARK: - Helpers

    /// Suma determinista de una envolvente: claves ordenadas por (i, j).
    private static func sumEnvelope(_ env: [Cell: Double]) -> Double {
        let sortedKeys = env.keys.sorted { lhs, rhs in
            if lhs.i != rhs.i { return lhs.i < rhs.i }
            return lhs.j < rhs.j
        }
        var sum: Double = 0
        for k in sortedKeys {
            sum += env[k]!
        }
        return sum
    }

    private static func project(_ p: SIMD3<Float>, plane: Plane, u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>, cellSize: Float) -> (i: Int, j: Int, u: Double, v: Double, h: Double) {
        let off = p - plane.point
        let uu = vecDot(off, u)
        let vv = vecDot(off, v)
        let h = vecDot(off, n)
        return (Self.cellIndex(uu, cellSize: cellSize), Self.cellIndex(vv, cellSize: cellSize), Double(uu), Double(vv), Double(h))
    }

    private static func cellIndex(_ coord: Float, cellSize: Float) -> Int {
        Int(floor(coord / cellSize))
    }

    private static func orthonormalBasis(_ n: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let ref: SIMD3<Float> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let u = vecNormalize(vecCross(ref, n))
        let v = vecNormalize(vecCross(n, u))
        return (u, v)
    }

    private static func planeCoefficients(
        _ a: (i: Int, j: Int, u: Double, v: Double, h: Double),
        _ b: (i: Int, j: Int, u: Double, v: Double, h: Double),
        _ c: (i: Int, j: Int, u: Double, v: Double, h: Double)
    ) -> (A: Float, B: Float, C: Float) {
        let d = (b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u)
        guard abs(d) > 1e-6 else { return (0, 0, 0) }
        let A = ((b.h - a.h) * (c.v - a.v) - (b.v - a.v) * (c.h - a.h)) / d
        let B = ((b.u - a.u) * (c.h - a.h) - (b.h - a.h) * (c.u - a.u)) / d
        let C = a.h - A * a.u - B * a.v
        return (Float(A), Float(B), Float(C))
    }

    private static func pointInTriangle(
        px: Float, py: Float,
        _ a: (i: Int, j: Int, u: Double, v: Double, h: Double),
        _ b: (i: Int, j: Int, u: Double, v: Double, h: Double),
        _ c: (i: Int, j: Int, u: Double, v: Double, h: Double)
    ) -> Bool {
        func sign(_ p1: (Float, Float), _ p2: (Float, Float), _ p3: (Float, Float)) -> Float {
            (p1.0 - p3.0) * (p2.1 - p3.1) - (p2.0 - p3.0) * (p1.1 - p3.1)
        }
        let p = (px, py)
        let d1 = sign(p, (Float(a.u), Float(a.v)), (Float(b.u), Float(b.v)))
        let d2 = sign(p, (Float(b.u), Float(b.v)), (Float(c.u), Float(c.v)))
        let d3 = sign(p, (Float(c.u), Float(c.v)), (Float(a.u), Float(a.v)))
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        return !(hasNeg && hasPos)
    }

    /// Rellena huecos interiores (celdas sin dato no alcanzadas por el flood desde el
    /// borde del bbox) con la media de los vecinos llenos, iterativamente.
    private static func fillInteriorHoles(_ heights: inout [Cell: Double]) {
        guard !heights.isEmpty else { return }
        let iMin = heights.keys.map(\.i).min()!
        let iMax = heights.keys.map(\.i).max()!
        let jMin = heights.keys.map(\.j).min()!
        let jMax = heights.keys.map(\.j).max()!

        var outside = Set<Cell>()
        var queue: [Cell] = []
        func push(_ i: Int, _ j: Int) {
            guard i >= iMin, i <= iMax, j >= jMin, j <= jMax else { return }
            let key = Cell(i: i, j: j)
            guard heights[key] == nil, !outside.contains(key) else { return }
            outside.insert(key)
            queue.append(key)
        }
        for i in iMin...iMax {
            push(i, jMin)
            push(i, jMax)
        }
        for j in jMin...jMax {
            push(iMin, j)
            push(iMax, j)
        }
        while let key = queue.popLast() {
            push(key.i + 1, key.j)
            push(key.i - 1, key.j)
            push(key.i, key.j + 1)
            push(key.i, key.j - 1)
        }

        let neighborOffsets = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var changed = true
        var guardCount = 0
        while changed, guardCount < 400 {
            changed = false
            guardCount += 1
            var toSet: [(Cell, Double)] = []
            for i in iMin...iMax {
                for j in jMin...jMax {
                    let key = Cell(i: i, j: j)
                    guard heights[key] == nil, !outside.contains(key) else { continue }
                    var sum: Double = 0
                    var count = 0
                    for (di, dj) in neighborOffsets {
                        if let v = heights[Cell(i: i + di, j: j + dj)] {
                            sum += v
                            count += 1
                        }
                    }
                    if count > 0 {
                        toSet.append((key, sum / Double(count)))
                    }
                }
            }
            if toSet.isEmpty { break }
            for (key, value) in toSet { heights[key] = value }
            changed = true
        }
    }

    private static func bboxCellCount(_ cells: Set<Cell>) -> Int {
        guard let first = cells.first else { return 0 }
        var iMin = first.i, iMax = first.i, jMin = first.j, jMax = first.j
        for c in cells {
            iMin = min(iMin, c.i)
            iMax = max(iMax, c.i)
            jMin = min(jMin, c.j)
            jMax = max(jMax, c.j)
        }
        let width = iMax - iMin + 1
        let height = jMax - jMin + 1
        guard width > 0, height > 0 else { return 0 }
        return width * height
    }
}