import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F2 — Caja orientada (OBB) por PCA: autovalores/autovectores de la matriz de
// covarianza vía rotaciones de Jacobi sobre matriz simétrica 3×3.
// ═══════════════════════════════════════════════════════════════════════════════

/// Autovalores (descendentes) y autovectores asociados de una matriz 3×3 simétrica.
struct EigenDecomposition3 {
    /// Autovalores ordenados de mayor a menor.
    var eigenvalues: SIMD3<Float>
    /// Columnas = autovectores asociados a `eigenvalues[0..2]`.
    var eigenvectors: Matrix3x3

    /// Jacobi cíclico sobre matriz simétrica dada como columnas.
    static func symmetric(_ m: Matrix3x3) -> EigenDecomposition3 {
        var a = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for r in 0..<3 {
            for c in 0..<3 {
                a[r][c] = m[c][r]
            }
        }

        for _ in 0..<40 {
            var p = 0
            var q = 1
            var maxValue: Float = 0
            for i in 0..<3 {
                for j in (i + 1)..<3 {
                    let av = abs(a[i][j])
                    if av > maxValue {
                        maxValue = av
                        p = i
                        q = j
                    }
                }
            }
            if maxValue < 1e-12 { break }

            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = theta == 0 ? 0 : copysign(1, theta) / (abs(theta) + sqrt(theta * theta + 1))
            let c = 1 / sqrt(t * t + 1)
            let s = t * c

            for k in 0..<3 {
                let akp = a[k][p]
                let akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
                let vkp = v[k][p]
                let vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
            for k in 0..<3 {
                let apk = a[p][k]
                let aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
        }

        var idx = [0, 1, 2].sorted { abs(a[$0][$0]) > abs(a[$1][$1]) }
        if idx[0] == idx[1] { idx = [0, 1, 2] }

        var evals = SIMD3<Float>(0, 0, 0)
        var cols: [SIMD3<Float>] = []
        for i in 0..<3 {
            let li = idx[i]
            evals[i] = a[li][li]
            cols.append(SIMD3(v[0][li], v[1][li], v[2][li]))
        }
        return EigenDecomposition3(eigenvalues: evals, eigenvectors: Matrix3x3(cols))
    }
}

/// Ajuste de caja orientada por PCA. Opcionalmente fuerza el eje vertical de la
/// caja al eje de gravedad (utilidad en segmentación multi-especimen).
public struct PCAOBBFitter: BoxFitting {
    public init() {}

    public func fit(
        points: [SIMD3<Float>],
        gravityAlignedUpAxis: Bool
    ) throws(GeometryError) -> OrientedBox {
        guard points.count >= 3 else { throw .insufficientPoints(points.count) }

        let center = points.reduce(SIMD3<Float>(0, 0, 0), +) / Float(points.count)

        var covariance = Matrix3x3.identity
        for p in points {
            let o = p - center
            for r in 0..<3 {
                for c in 0..<3 {
                    covariance[c][r] += o[c] * o[r]
                }
            }
        }

        var decomp = EigenDecomposition3.symmetric(covariance)

        // Normalizar autovectores (Jacobi los produce unitarios, pero defensivo).
        var cols = [SIMD3<Float>](repeating: .zero, count: 3)
        for i in 0..<3 {
            let ev = decomp.eigenvectors[i]
            let len = vecLength(ev)
            cols[i] = len > 1e-12 ? ev / len : SIMD3(i == 0 ? 1 : 0, i == 1 ? 1 : 0, i == 2 ? 1 : 0)
        }
        decomp.eigenvectors = Matrix3x3(cols)

        var axes = decomp.eigenvectors
        if gravityAlignedUpAxis {
            // Encontrar el autovector más cercano a +Y y forzarlo a Y puro.
            var upIndex = 0
            var best = -Float.greatestFiniteMagnitude
            for i in 0..<3 {
                let d = abs(vecDot(axes[i], SIMD3(0, 1, 0)))
                if d > best {
                    best = d
                    upIndex = i
                }
            }
            let sign: Float = vecDot(axes[upIndex], SIMD3(0, 1, 0)) >= 0 ? 1 : -1
            let upAxis = SIMD3(0, sign, 0)
            var horizontal: [SIMD3<Float>] = []
            for i in 0..<3 where i != upIndex {
                horizontal.append(axes[i])
            }
            let h0 = vecNormalize(horizontal[0] - vecDot(horizontal[0], upAxis) * upAxis)
            let h1 = vecCross(upAxis, h0)

            var newCols = [SIMD3<Float>](repeating: .zero, count: 3)
            var j = 0
            for i in 0..<3 {
                if i == upIndex {
                    newCols[i] = upAxis
                } else {
                    newCols[i] = j == 0 ? h0 : h1
                    j += 1
                }
            }
            axes = Matrix3x3(newCols)
        }

        // Proyectar sobre los ejes para obtener semiejes.
        var minP = SIMD3<Float>(.infinity, .infinity, .infinity)
        var maxP = SIMD3<Float>(-.infinity, -.infinity, -.infinity)
        for p in points {
            let o = p - center
            let proj = SIMD3(vecDot(o, axes[0]), vecDot(o, axes[1]), vecDot(o, axes[2]))
            minP = SIMD3(min(minP.x, proj.x), min(minP.y, proj.y), min(minP.z, proj.z))
            maxP = SIMD3(max(maxP.x, proj.x), max(maxP.y, proj.y), max(maxP.z, proj.z))
        }

        let halfExtents = (maxP - minP) * 0.5
        guard halfExtents.x.isFinite && halfExtents.y.isFinite && halfExtents.z.isFinite else {
            throw .degenerateConfiguration("semiejes no finitos")
        }

        let boxCenter = center + axes * ((minP + maxP) * 0.5)
        // Invariantes garantizadas: semiejes ≥ 0 (guard anterior) y ejes con
        // determinante positivo (PCA). El init nunca lanza aquí.
        return try! OrientedBox(center: boxCenter, axes: axes, halfExtents: halfExtents)
    }
}