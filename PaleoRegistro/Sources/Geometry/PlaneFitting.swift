import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F2 — Ajuste de planos: mínimos cuadrados + RANSAC/MSAC genérico con
// restricción de orientación evaluada DENTRO del bucle de consenso.
// RNG determinista (SplitMix64) para reproducción bit a bit.
// ═══════════════════════════════════════════════════════════════════════════════

/// ¿La normal satisface la restricción de orientación?
/// Se usa `abs` en los dot products porque el signo de la normal es arbitrario.
func constraintSatisfied(_ constraint: OrientationConstraint, normal: SIMD3<Float>) -> Bool {
    switch constraint {
    case .none:
        return true
    case .horizontal(let maxTiltDegrees):
        let limit = cos(maxTiltDegrees * .pi / 180)
        return abs(normal.y) >= limit
    case .vertical(let maxTiltDegrees):
        let limit = sin(maxTiltDegrees * .pi / 180)
        return abs(normal.y) <= limit
    case .nearNormal(let dir, let toleranceDegrees):
        let d = vecNormalize(dir)
        let limit = cos(toleranceDegrees * .pi / 180)
        return abs(vecDot(normal, d)) >= limit
    }
}

/// Ajuste de plano por mínimos cuadrados (eigenvector de menor autovalor de la
/// matriz de covarianza, vía rotaciones de Jacobi).
public struct LeastSquaresPlaneFitter: PlaneFitting {
    public static var algorithmVersion: String { "1.0.0" }

    public init() {}

    public func fit(
        points: [SIMD3<Float>],
        normals: [SIMD3<Float>]?,
        options: PlaneFitOptions
    ) throws(GeometryError) -> Plane {
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

        var a = [[Float]](repeating: [Float](repeating: 0, count: 3), count: 3)
        var v: [[Float]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for r in 0..<3 {
            for c in 0..<3 {
                a[r][c] = covariance[c][r]
            }
        }

        for _ in 0..<30 {
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
            if maxValue < 1e-9 { break }

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

        let diag = [abs(a[0][0]), abs(a[1][1]), abs(a[2][2])]
        guard let minIndex = diag.firstIndex(of: diag.min() ?? 0) else {
            throw .degenerateConfiguration("covarianza sin autovalores")
        }
        let normal = SIMD3(v[0][minIndex], v[1][minIndex], v[2][minIndex])
        let length = vecLength(normal)
        guard length > 1e-6 else { throw .colinearPoints }

        // La normal está normalizada y su norma > 0: el init nunca lanza aquí.
        var result = try! Plane(
            point: center,
            normal: normal / length,
            inlierCount: points.count
        )
        var rms: Float = 0
        for p in points {
            let d = abs(vecDot(p - center, result.normal))
            rms += d * d
        }
        result.inlierRMS = (rms / Float(points.count)).squareRoot()
        return result
    }
}

/// Ajuste robusto de plano dominante por RANSAC con puntuación MSAC.
///
/// La restricción de orientación se evalúa sobre el candidato ANTES de contar
/// inliers: un candidato que la viola se descarta sin contarlo. Esto hace que
/// un plano vertical gane el consenso incluso cuando un piso horizontal tiene
/// más puntos. El RNG (SplitMix64) va sembrado desde `PlaneFitOptions.rngSeed`
/// para que el resultado sea reproducible bit a bit.
public struct RANSACPlaneFitter: PlaneFitting {
    public static var algorithmVersion: String { "1.0.0" }

    public init() {}

    public func fit(
        points: [SIMD3<Float>],
        normals: [SIMD3<Float>]?,
        options: PlaneFitOptions
    ) throws(GeometryError) -> Plane {
        guard points.count >= 3 else { throw .insufficientPoints(points.count) }

        var rng = SplitMix64(seed: options.rngSeed)
        var bestPlane: Plane?
        var bestInliers: [SIMD3<Float>] = []
        var bestScore: Float = .infinity

        // Detección previa de colinearidad: si todos los puntos están sobre una
        // misma recta (dentro de una tolerancia relativa), ningún plano puede
        // pasar por 3 de ellos sin degeneración numérica.
        if Self.isColinear(points) {
            throw .colinearPoints
        }

        // Prefiltrado por normal de cara si se proveen normales: acelera la
        // convergencia descartando puntos cuyas normales ya violan la restricción.
        var candidates = points
        if let normals, normals.count == points.count {
            var kept: [SIMD3<Float>] = []
            for (i, p) in points.enumerated() {
                if constraintSatisfied(options.constraint, normal: normals[i]) {
                    kept.append(p)
                }
            }
            if kept.count >= 3 {
                candidates = kept
            }
        }

        // Iteraciones adaptativas: N = log(1-p) / log(1-w³), con w = fracción
        // de inliers del mejor modelo hallado hasta ahora.
        var iterations = options.maxIterations
        var w = Float(max(1, options.minInliers)) / Float(points.count)
        if w >= 1 { w = 0.999 }

        var effectiveIterations = 0
        var anyCandidate = false
        for _ in 0..<iterations {
            effectiveIterations += 1

            let ai = Int.random(in: 0..<candidates.count, using: &rng)
            let bi = Int.random(in: 0..<candidates.count, using: &rng)
            let ci = Int.random(in: 0..<candidates.count, using: &rng)
            guard let candidate = Self.planeThrough(candidates[ai], candidates[bi], candidates[ci]) else {
                continue
            }
            anyCandidate = true

            // Restricción DENTRO del bucle: descartar antes de contar inliers.
            guard constraintSatisfied(options.constraint, normal: candidate.normal) else {
                continue
            }

            var score: Float = 0
            var inliers: [SIMD3<Float>] = []
            inliers.reserveCapacity(points.count)
            let thresholdSq = options.inlierDistance * options.inlierDistance

            for p in points {
                let d = abs(vecDot(p - candidate.point, candidate.normal))
                if d <= options.inlierDistance {
                    inliers.append(p)
                    score += d * d
                } else {
                    score += thresholdSq
                }
            }

            // MSAC: menor error cuadrático truncado gana. Con `inlierCount`
            // gana el mayor conteo binario.
            let isBetter: Bool
            switch options.scoring {
            case .msac:
                isBetter = score < bestScore
            case .inlierCount:
                isBetter = inliers.count > bestInliers.count
            }
            if isBetter {
                bestPlane = candidate
                bestInliers = inliers
                bestScore = score
                if options.scoring == .inlierCount {
                    bestScore = Float(inliers.count)
                }

                // Actualizar w y el número de iteraciones adaptativo.
                let newW = Float(bestInliers.count) / Float(points.count)
                if newW > w { w = newW }
                let denom = log1p(-w * w * w)
                if denom < 0 {
                    let needed = Int(log1p(-options.confidence) / denom)
                    iterations = min(options.maxIterations, max(1, needed))
                }
            }
        }

        guard bestInliers.count >= options.minInliers, let bestPlane else {
            if !anyCandidate {
                // Ninguna terna produjo un plano no degenerado: puntos colineales.
                throw .colinearPoints
            }
            throw .noConsensus
        }

        // Refinamiento por mínimos cuadrados sobre los inliers del mejor consenso.
        let refined = LeastSquaresPlaneFitter()
        let refinedPlane = try refined.fit(points: bestInliers, normals: nil, options: options)
        var result: Plane
        if constraintSatisfied(options.constraint, normal: refinedPlane.normal) {
            result = refinedPlane
        } else {
            result = bestPlane
        }
        result.inlierCount = bestInliers.count
        return result
    }

    /// Plano que pasa por tres puntos no colineales.
    static func planeThrough(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>
    ) -> Plane? {
        let normal = vecCross(b - a, c - a)
        let length = vecLength(normal)
        guard length > 1e-6 else { return nil }
        return try? Plane(point: a, normal: normal / length)
    }

    /// Distancia absoluta de un punto a un plano.
    static func distance(from point: SIMD3<Float>, to plane: Plane) -> Float {
        abs(vecDot(point - plane.point, plane.normal))
    }

    /// ¿Todos los puntos están sobre una recta (dentro de tolerancia relativa)?
    static func isColinear(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count >= 3 else { return true }
        let p0 = points[0]
        var dir = SIMD3<Float>.zero
        var maxExtent: Float = 0
        for p in points.dropFirst() {
            let d = p - p0
            maxExtent = max(maxExtent, vecLength(d))
        }
        if maxExtent < 1e-6 { return true }
        // Dirección dominante: vector entre el primer punto y el más lejano.
        var far = points[0]
        var farDist: Float = -1
        for p in points.dropFirst() {
            let d = vecLength(p - p0)
            if d > farDist {
                farDist = d
                far = p
            }
        }
        dir = vecNormalize(far - p0)
        var maxPerp: Float = 0
        for p in points {
            let rel = p - p0
            let proj = vecDot(rel, dir) * dir
            maxPerp = max(maxPerp, vecLength(rel - proj))
        }
        // Tolerancia relativa al tamaño de la nube.
        return maxPerp < maxExtent * 1e-3
    }
}