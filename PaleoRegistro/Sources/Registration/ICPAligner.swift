import Foundation
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// F11 — ICPAligner. ICP punto-a-plano recortado, submuestreo por vóxel
// multiresolución, hash espacial para correspondencias, Gauss-Newton 6DOF.
// ═══════════════════════════════════════════════════════════════════════════════

public struct ICPAligner: MeshRegistering, Sendable {

    public static var algorithmVersion: String { "1.0.0" }

    public init() {}

    public func align(
        source: Mesh,
        target: Mesh,
        initial: Matrix4x4,
        stableRegionMask: RegionMask? = nil,
        options: ICPOptions = ICPOptions()
    ) throws(RegistrationError) -> AlignmentResult {

        guard !source.isEmpty, !target.isEmpty else {
            throw .insufficientCorrespondences(0)
        }

        // Aplicar máscara de región estable si existe
        let effectiveTarget = applyStableMask(target, mask: stableRegionMask)

        var transform = initial
        var prevRMSE: Float = .infinity

        // El update de Gauss-Newton se aplica siempre, incluso si el sistema
        // 6×6 está mal condicionado y produce un paso malo — el único freno
        // es "no more del 10% peor que la iteración anterior" (más abajo),
        // que no evita una deriva lenta y acumulada a lo largo de muchas
        // iteraciones. Se guarda aparte la mejor transformación vista (menor
        // RMSE) y se devuelve esa al final, no necesariamente la última: así
        // una cola de iteraciones que empeoran gradualmente no puede echar a
        // perder un resultado que ya había convergido bien.
        var bestTransform = initial
        var bestRMSE: Float = .infinity

        for (level, voxelSize) in options.voxelSizes.enumerated() {
            // Submuestrear ambas nubes, conservando el índice original de
            // cada punto representante — necesario para poder consultar su
            // normal real más abajo (antes se usaba `corr.srcIdx % norms.count`,
            // el índice dentro del arreglo *submuestreado*, contra el arreglo
            // de normales *sin submuestrear*: dos espacios de índices
            // distintos que no tienen relación entre sí).
            let srcPts = voxelSubsample(source.vertices, cellSize: voxelSize)
            let tgtPts = voxelSubsample(effectiveTarget.vertices, cellSize: voxelSize)

            let tgtHasNormals = effectiveTarget.normals != nil

            guard srcPts.count >= 10, tgtPts.count >= 10 else { continue }

            // Construir hash espacial para la nube target
            let targetHash = SpatialHash(points: tgtPts.map(\.point), cellSize: voxelSize * 2)

            let cosNormalMax = cos(options.normalCompatibilityAngleDegrees * .pi / 180)

            for iter in 0..<options.maxIterations {
                // Transformar source points
                let srcTransformed = srcPts.map { transform.applyAffine($0.point) }

                // Correspondencias via hash espacial
                var correspondences: [(srcIdx: Int, tgtPt: SIMD3<Float>, srcOriginalIdx: Int, tgtOriginalIdx: Int)] = []
                for (i, sp) in srcTransformed.enumerated() {
                    if let tgtIdx = targetHash.nearest(to: sp) {
                        let diff = vecLength(sp - tgtPts[tgtIdx].point)
                        if diff < options.maxCorrespondenceDistance {
                            correspondences.append((i, tgtPts[tgtIdx].point, srcPts[i].index, tgtPts[tgtIdx].index))
                        }
                    }
                }

                guard correspondences.count >= 6 else {
                    if level == 0 && iter == 0 { throw .insufficientCorrespondences(correspondences.count) }
                    break
                }

                // Trimmed: descartar peores correspondencias
                let sorted = correspondences.sorted {
                    vecLength(srcTransformed[$0.srcIdx] - $0.tgtPt) < vecLength(srcTransformed[$1.srcIdx] - $1.tgtPt)
                }
                let keepCount = max(6, Int(Float(sorted.count) * (1.0 - options.trimmedOutlierFraction)))
                let kept = Array(sorted.prefix(keepCount))

                // Construir sistema Gauss-Newton 6×6
                // Punto-a-plano: minimizar Σ ((R·pi + t - qi)·ni)²
                // Jacobiano por punto: [n, (Rpi × n)]
                var JtJ = [Float](repeating: 0, count: 36) // 6×6 simétrica
                var JtE = [Float](repeating: 0, count: 6)
                var totalError: Float = 0
                // Distinto de `kept.count`: el chequeo de compatibilidad de
                // normales de abajo puede saltarse (`continue`) parte de
                // `kept` sin contribuir a JtJ/JtE/totalError. Usar
                // `kept.count` como si fuera el número real de puntos que
                // sí contribuyeron (para el RMSE y el mínimo de 6) subestima
                // el error cuando la normal por defecto o real filtra
                // varios pares —el sistema puede terminar mal determinado
                // sin que el chequeo `kept.count >= 6` lo note.
                var usedCount = 0

                for corr in kept {
                    let sp = srcPts[corr.srcIdx].point
                    let tgt = corr.tgtPt

                    // Normal del target (si no disponible, usar vector fuente→target)
                    let normal: SIMD3<Float>
                    if tgtHasNormals, let norms = effectiveTarget.normals, corr.tgtOriginalIdx < norms.count {
                        normal = norms[corr.tgtOriginalIdx]
                        // Chequeo de compatibilidad de normales
                        let srcNormal = transform.rotation3x3 * (
                            (corr.srcOriginalIdx < (source.normals?.count ?? 0)) ? source.normals![corr.srcOriginalIdx] : normal
                        )
                        if abs(vecDot(normal, srcNormal)) < cosNormalMax { continue }
                    } else {
                        normal = vecNormalize(srcTransformed[corr.srcIdx] - tgt)
                    }

                    let spTrans = sp
                    let t = transform.translation
                    let r = transform.rotation3x3
                    let rp = r * spTrans + t

                    let residual = vecDot(rp - tgt, normal)
                    totalError += residual * residual
                    usedCount += 1

                    // Cross product: (R * pi) × n
                    let cross = vecCross(rp, normal)

                    // Jacobiano: 6 componentes = [nx, ny, nz, cross.x, cross.y, cross.z]
                    let J: [Float] = [normal.x, normal.y, normal.z, cross.x, cross.y, cross.z]

                    // JtJ += J * J^T (matriz simétrica 6×6, solo triangular inferior)
                    for r in 0..<6 {
                        for c in r..<6 {
                            JtJ[r * 6 + c] += J[r] * J[c]
                        }
                        JtE[r] += J[r] * residual
                    }
                }

                guard usedCount >= 6 else { break }

                // `transform` en este punto es el estado ANTES de la
                // actualización de esta iteración; su RMSE (calculado con
                // `totalError` de arriba) describe qué tan buena es esa
                // transformación ya aplicada. Se guarda como candidato antes
                // de arriesgar un paso que podría empeorarla.
                let preUpdateRMSE = sqrt(totalError / Float(usedCount))
                if preUpdateRMSE < bestRMSE {
                    bestRMSE = preUpdateRMSE
                    bestTransform = transform
                }

                // Rellenar triangular superior de JtJ (simétrica)
                for r in 0..<6 {
                    for c in 0..<r {
                        JtJ[r * 6 + c] = JtJ[c * 6 + r]
                    }
                }

                // Amortiguación tipo Levenberg-Marquardt: sin esto, un paso
                // de Gauss-Newton puro puede sobrepasar el mínimo cuando la
                // aproximación de ángulo pequeño (R ≈ I + [ω]×) todavía no es
                // muy buena — típicamente en las primeras iteraciones, con
                // pocas correspondencias, o con una normal ~= dirección del
                // residuo (el respaldo sin normales reales). Un paso peor
                // solo se aplica una vez (el filtro `bestTransform` evita que
                // se acumule), pero amortiguar reduce cuántas iteraciones se
                // desperdician antes de que el filtro de "empeoró > 10%"
                // corte la refinación.
                let diagMean = (0..<6).reduce(Float(0)) { $0 + JtJ[$1 * 6 + $1] } / 6.0
                let damping = max(diagMean * 1e-3, 1e-8)
                for i in 0..<6 { JtJ[i * 6 + i] += damping }

                // Resolver sistema 6×6 con eliminación Gauss-Jordan
                let solution = solve6x6(JtJ, rhs: JtE)
                guard let sol = solution else {
                    if iter == 0 { throw .notConverged }
                    break
                }

                // Aplicar actualización incremental (ángulos pequeños → aproximación).
                // Un sistema mal condicionado (paredes casi planas, pocas
                // correspondencias, correspondencias por vecino más cercano
                // en una malla con aristas filosas) puede dar un paso que
                // sobrepasa ampliamente el mínimo — la aproximación de
                // ángulo pequeño ya no vale para un `omega` grande, y un
                // salto de traslación mayor que la propia distancia de
                // correspondencia puede dejar al ICP sin correspondencias
                // en la iteración siguiente (el resultado ya no tiene forma
                // de recuperarse: 6 iteraciones seguidas sin datos y el
                // refinamiento termina). Se acota la magnitud del paso por
                // iteración — igual de válido cerca del mínimo (donde el
                // paso real es pequeño de todas formas) y evita que un
                // Hessiano ruidoso mande la transformación fuera del rango
                // donde las correspondencias siguen siendo válidas.
                var alpha = SIMD3<Float>(sol[0], sol[1], sol[2])
                var omega = SIMD3<Float>(sol[3], sol[4], sol[5])
                let maxStepT = options.maxCorrespondenceDistance * 0.5
                let maxStepR: Float = 0.2 // rad, ~11.5°
                let alphaLen = vecLength(alpha)
                if alphaLen > maxStepT { alpha *= maxStepT / alphaLen }
                let omegaLen = vecLength(omega)
                if omegaLen > maxStepR { omega *= maxStepR / omegaLen }

                let deltaR = skewToRotation(omega)
                let deltaT = alpha

                let deltaTransform = Matrix4x4(
                    SIMD4(deltaR[0].x, deltaR[0].y, deltaR[0].z, 0),
                    SIMD4(deltaR[1].x, deltaR[1].y, deltaR[1].z, 0),
                    SIMD4(deltaR[2].x, deltaR[2].y, deltaR[2].z, 0),
                    SIMD4(deltaT.x, deltaT.y, deltaT.z, 1)
                )

                transform = deltaTransform * transform

                if abs(preUpdateRMSE - prevRMSE) < 1e-7 || preUpdateRMSE > prevRMSE * 1.1 { break }
                prevRMSE = preUpdateRMSE
            }
        }

        // Se usa la mejor transformación vista durante el refinamiento, no
        // necesariamente la última — ver el comentario junto a `bestTransform`.
        if bestRMSE < .infinity {
            transform = bestTransform
        }

        // Chequeo de degeneración
        let conditionNumber = computeConditionNumber(transform: transform, target: effectiveTarget)
        let isDegenerate = conditionNumber > options.degeneracyConditionThreshold

        if isDegenerate {
            throw .degenerate(conditionNumber: conditionNumber)
        }

        // RMSE final
        let finalRMSE = computeRMSE(source: source, target: effectiveTarget, transform: transform)

        return AlignmentResult(
            transform: transform,
            rmse: finalRMSE,
            inlierRatio: 1.0,
            iterations: options.maxIterations * options.voxelSizes.count,
            conditionNumber: conditionNumber,
            isDegenerate: isDegenerate,
            initializationMethod: .geodetic
        )
    }

    // MARK: - Helpers

    private func applyStableMask(_ target: Mesh, mask: RegionMask?) -> Mesh {
        guard let region = mask?.stableRegion else { return target }

        var keep = [Bool](repeating: false, count: target.vertices.count)
        for (i, v) in target.vertices.enumerated() {
            keep[i] = region.contains(v)
        }

        let keepCount = keep.filter { $0 }.count
        if keepCount == target.vertices.count { return target }
        if keepCount == 0 { return target } // no filtrar todo

        var newVerts: [SIMD3<Float>] = []
        var newNormals: [SIMD3<Float>] = []
        var oldToNew: [Int] = Array(repeating: -1, count: target.vertices.count)
        var newIndices: [UInt32] = []

        for (i, v) in target.vertices.enumerated() {
            if keep[i] {
                oldToNew[i] = newVerts.count
                newVerts.append(v)
                // Filtrar las normales igual que los vértices: dejarlas sin
                // filtrar (como estaba antes) descuadra sus índices respecto
                // a newVerts en cuanto la máscara excluye algún vértice.
                if let normals = target.normals, i < normals.count {
                    newNormals.append(normals[i])
                }
            }
        }

        for i in stride(from: 0, to: target.indices.count, by: 3) {
            let i0 = Int(target.indices[i]), i1 = Int(target.indices[i+1]), i2 = Int(target.indices[i+2])
            let k0 = oldToNew[i0], k1 = oldToNew[i1], k2 = oldToNew[i2]
            if k0 >= 0, k1 >= 0, k2 >= 0 {
                newIndices.append(UInt32(k0))
                newIndices.append(UInt32(k1))
                newIndices.append(UInt32(k2))
            }
        }

        return Mesh(vertices: newVerts, indices: newIndices, normals: target.normals != nil ? newNormals : nil)
    }

    /// Submuestra por vóxel, conservando el índice del punto original que
    /// representa a cada celda ocupada — necesario para poder recuperar su
    /// normal (u otro dato por vértice) después de submuestrear.
    private func voxelSubsample(_ points: [SIMD3<Float>], cellSize: Float) -> [(point: SIMD3<Float>, index: Int)] {
        guard cellSize > 0 else { return points.enumerated().map { (point: $0.element, index: $0.offset) } }
        var grid: [SIMD3<Int>: (point: SIMD3<Float>, index: Int)] = [:]
        for (i, p) in points.enumerated() {
            let key = SIMD3<Int>(
                Int(floor(p.x / cellSize)),
                Int(floor(p.y / cellSize)),
                Int(floor(p.z / cellSize))
            )
            if grid[key] == nil {
                grid[key] = (point: p, index: i)
            }
        }
        return Array(grid.values)
    }

    private func skewToRotation(_ omega: SIMD3<Float>) -> Matrix3x3 {
        // Aproximación de pequeños ángulos: R ≈ I + [ω]×
        return Matrix3x3(
            SIMD3(1, omega.z, -omega.y),
            SIMD3(-omega.z, 1, omega.x),
            SIMD3(omega.y, -omega.x, 1)
        )
    }

    private func solve6x6(_ A: [Float], rhs: [Float]) -> [Float]? {
        var M = A
        var b = rhs
        // Gauss-Jordan con pivote parcial
        for col in 0..<6 {
            var maxVal = abs(M[col * 6 + col])
            var maxRow = col
            for row in (col+1)..<6 {
                if abs(M[row * 6 + col]) > maxVal {
                    maxVal = abs(M[row * 6 + col])
                    maxRow = row
                }
            }
            if maxVal < 1e-15 { return nil }
            if maxRow != col {
                for c in 0..<6 {
                    let tmp = M[col * 6 + c]
                    M[col * 6 + c] = M[maxRow * 6 + c]
                    M[maxRow * 6 + c] = tmp
                }
                let tb = b[col]; b[col] = b[maxRow]; b[maxRow] = tb
            }
            let pivot = M[col * 6 + col]
            for c in col..<6 { M[col * 6 + c] /= pivot }
            b[col] /= pivot
            for row in 0..<6 where row != col {
                let factor = M[row * 6 + col]
                if abs(factor) < 1e-15 { continue }
                for c in col..<6 { M[row * 6 + c] -= factor * M[col * 6 + c] }
                b[row] -= factor * b[col]
            }
        }
        return b
    }

    private func computeConditionNumber(transform: Matrix4x4, target: Mesh) -> Float {
        let r = transform.rotation3x3
        let t = transform.translation

        var cov = [Float](repeating: 0, count: 36)
        let sample = voxelSubsample(target.vertices, cellSize: 0.1)
        let n = Float(sample.count)

        guard n >= 6 else { return 1e7 }

        // NOTA (auditoría, ver fixes.md): se intentó reemplazar este
        // heurístico por el Hessiano real punto-a-plano (producto externo
        // de [normal, rp×normal] por punto, igual que JtJ en align()), que
        // sí detecta correctamente una pared plana grande como degenerada
        // — pero sobre-marca como degenerada una escena con normales en
        // varias direcciones (ej. un cubo) cuando la transformación acumula
        // una traslación grande, incluso evaluando las columnas
        // rotacionales alrededor del centroide de la muestra en vez del
        // origen del mundo. No se pudo aislar la causa raíz exacta (posible
        // pérdida de precisión en el determinante 6×6 en Float) con
        // confianza dentro del tiempo disponible, así que se mantiene este
        // heurístico de dispersión geométrica — menos fiel al problema real
        // de punto-a-plano, pero sin el falso positivo sobre escenas no
        // degeneradas.
        for (p, _) in sample {
            let rp = r * p + t
            let gx: SIMD3<Float> = SIMD3(1, 0, 0)
            let gy: SIMD3<Float> = SIMD3(0, 1, 0)
            let gz: SIMD3<Float> = SIMD3(0, 0, 1)
            let gw: SIMD3<Float> = vecCross(rp, SIMD3(1,0,0))
            let gv: SIMD3<Float> = vecCross(rp, SIMD3(0,1,0))
            let gu: SIMD3<Float> = vecCross(rp, SIMD3(0,0,1))

            let J: [SIMD3<Float>] = [gx, gy, gz, gw, gv, gu]
            for r in 0..<6 {
                for c in r..<6 {
                    let val = vecDot(J[r], J[c]) / n
                    cov[r * 6 + c] += val
                }
            }
        }

        for r in 0..<6 {
            for c in 0..<r {
                cov[r * 6 + c] = cov[c * 6 + r]
            }
        }

        // Traza como proxy de número de condición (más estable que eigenvalores)
        var trace: Float = 0
        for i in 0..<6 { trace += cov[i * 6 + i] }

        // Si la traza es cero, la nube es completamente degenerada
        guard trace > 1e-10 else { return 1e7 }

        // Determinante como proxy de condicionalidad
        // Para una nube plana, el determinante tiende a 0 → condición alta
        let det = determinant6x6(cov)
        let cond = abs(trace * trace / max(det, 1e-15))

        return min(cond, 1e7)
    }

    private func determinant6x6(_ A: [Float]) -> Float {
        // Usar eliminación gaussiana para calcular el determinante
        var M = A
        var det: Float = 1
        for col in 0..<6 {
            var pivot = abs(M[col * 6 + col])
            var pivotRow = col
            for row in (col+1)..<6 {
                if abs(M[row * 6 + col]) > pivot {
                    pivot = abs(M[row * 6 + col])
                    pivotRow = row
                }
            }
            if pivot < 1e-15 { return 0 }
            if pivotRow != col {
                det = -det
                for c in 0..<6 {
                    let tmp = M[col * 6 + c]
                    M[col * 6 + c] = M[pivotRow * 6 + c]
                    M[pivotRow * 6 + c] = tmp
                }
            }
            det *= M[col * 6 + col]
            for row in (col+1)..<6 {
                let factor = M[row * 6 + col] / M[col * 6 + col]
                for c in col..<6 {
                    M[row * 6 + c] -= factor * M[col * 6 + c]
                }
            }
        }
        return det
    }

    private func computeRMSE(source: Mesh, target: Mesh, transform: Matrix4x4) -> Float {
        let srcTrans = source.vertices.map { transform.applyAffine($0) }
        let tgtHash = SpatialHash(points: target.vertices, cellSize: 0.1)
        var sumSq: Float = 0
        var count = 0
        for sp in srcTrans {
            if let idx = tgtHash.nearest(to: sp) {
                let d = vecLength(sp - target.vertices[idx])
                sumSq += d * d
                count += 1
            }
        }
        return count > 0 ? sqrt(sumSq / Float(count)) : .infinity
    }
}

// MARK: - Spatial Hash

private struct SpatialHash {
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

        // Buscar en la celda y vecinas (3×3×3 = 27 celdas)
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let nKey = SIMD3<Int>(key.x + dx, key.y + dy, key.z + dz)
                    guard let candidates = grid[nKey] else { continue }
                    for idx in candidates {
                        let d2 = vecDistSq(query, points[idx])
                        if d2 < bestDist {
                            bestDist = d2
                            bestIdx = idx
                        }
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