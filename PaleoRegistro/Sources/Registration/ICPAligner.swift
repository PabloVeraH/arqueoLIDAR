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
        let (conditionNumber, weakDirections) = computeConditionNumber(
            target: effectiveTarget,
            threshold: options.degeneracyConditionThreshold
        )
        let isDegenerate = conditionNumber > options.degeneracyConditionThreshold

        if isDegenerate {
            throw .degenerate(conditionNumber: conditionNumber, weakDirections: weakDirections)
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
            initializationMethod: .geodetic,
            weakDirections: weakDirections
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

    /// Número de condición del Hessiano punto-a-plano real (H = Σ JᵀJ, J =
    /// [n, p̂×n]) sobre una muestra del target, y las direcciones de 6-DOF
    /// que lo dominan. Reemplaza el heurístico de dispersión geométrica que
    /// vivió aquí antes (ver fixes.md, "computeConditionNumber"): ese primer
    /// intento con el Hessiano real sobre-marcaba escenas bien
    /// condicionadas (ej. un cubo con traslación acumulada grande) como
    /// degeneradas. Causa raíz identificada (no solo "hacía falta más
    /// tiempo"): comparaba autovalores de H = JᵀJ (que van como κ(J)²)
    /// contra un umbral calibrado para el heurístico anterior, sin
    /// normalizar la escala de los puntos — la combinación exacta que
    /// Gelfand, Ikemoto, Rusinkiewicz & Levoy, "Geometrically Stable
    /// Sampling for the ICP Algorithm" (3DIM 2003), identifican como
    /// necesaria para que este número tenga sentido físico independiente
    /// del tamaño de la escena. Este método corrige eso: centra en el
    /// centroide, no-dimensionaliza por la escala RMS de la muestra, y
    /// diagonaliza H en `Double` (no `Float` — la sospecha de pérdida de
    /// precisión del intento anterior, documentada en el propio historial
    /// de este archivo, era razonable) vía `SymmetricEigenSolver`.
    ///
    /// `threshold` es el mismo `options.degeneracyConditionThreshold` que
    /// decide `isDegenerate`: una dirección se reporta como "débil" si su
    /// propia razón σ_max/σ_i ya supera ese umbral por sí sola — así
    /// `weakDirections` es exactamente el conjunto de direcciones
    /// responsables de que `isDegenerate` sea cierto, sin un segundo umbral
    /// mágico que mantener sincronizado.
    private func computeConditionNumber(
        target: Mesh,
        threshold: Float
    ) -> (conditionNumber: Float, weakDirections: [WeakDirection]) {
        let sample = voxelSubsample(target.vertices, cellSize: 0.1)
        guard sample.count >= 6 else { return (1e7, []) }

        // Normales reales si el target las trae (mismo criterio que
        // `align()`); si no, se derivan de la topología del propio target
        // — a diferencia del respaldo usado dentro del bucle de Gauss-
        // Newton (que solo tiene la dirección fuente→destino por
        // correspondencia disponible), aquí sí se dispone de la malla
        // completa con sus caras.
        let normals: [SIMD3<Float>]
        if let real = target.normals, real.count == target.vertices.count {
            normals = sample.map { real[$0.index] }
        } else {
            let computed = MeshOps().computeVertexNormals(target).map { vecNormalize($0) }
            normals = sample.map { computed[$0.index] }
        }

        // Centroide de la muestra, en Double desde el principio.
        var cx = 0.0, cy = 0.0, cz = 0.0
        for (p, _) in sample { cx += Double(p.x); cy += Double(p.y); cz += Double(p.z) }
        let count = Double(sample.count)
        cx /= count; cy /= count; cz /= count

        // Escala característica: RMS de la distancia al centroide. No-
        // dimensionaliza el bloque rotacional del Hessiano (p̂×n, unidades
        // de longitud) para que sea comparable en magnitud al bloque
        // traslacional (n, siempre unitario) — sin esto, la misma escena
        // geométrica a otra escala física (o la misma escena con más
        // traslación acumulada) da un número de condición distinto por
        // pura escala, no por una diferencia real de condicionamiento.
        var sumSq = 0.0
        for (p, _) in sample {
            let dx = Double(p.x) - cx, dy = Double(p.y) - cy, dz = Double(p.z) - cz
            sumSq += dx * dx + dy * dy + dz * dz
        }
        let scale = (sumSq / count).squareRoot()
        guard scale > 1e-9 else { return (1e7, []) } // toda la muestra en un punto: sin información

        // H = Σ JᵀJ, J = [n, p̂×n], p̂ = (p - centroide) / escala. Igual
        // estructura que el Jacobiano punto-a-plano de `align()`.
        var h = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for (idx, (p, _)) in sample.enumerated() {
            let n = normals[idx]
            guard vecLength(n) > 1e-6 else { continue }
            let px = (Double(p.x) - cx) / scale
            let py = (Double(p.y) - cy) / scale
            let pz = (Double(p.z) - cz) / scale
            let nx = Double(n.x), ny = Double(n.y), nz = Double(n.z)
            let cross = (px: py * nz - pz * ny, py: pz * nx - px * nz, pz: px * ny - py * nx)
            let j = [nx, ny, nz, cross.px, cross.py, cross.pz]
            for r in 0..<6 {
                for c in r..<6 {
                    h[r][c] += j[r] * j[c]
                }
            }
        }
        for r in 0..<6 { for c in 0..<r { h[r][c] = h[c][r] } }

        let eig = SymmetricEigenSolver.solve(h)
        // σ = √λ (H es semidefinida positiva por construcción; λ<0 solo por
        // ruido numérico residual se trata como 0). σ vive en la misma
        // escala que las filas de J, no la de H — evita reportar el
        // cuadrado inflado directamente en el veredicto.
        let sigmas = eig.values.map { $0 > 0 ? $0.squareRoot() : 0.0 }
        guard let sigmaMax = sigmas.max(), sigmaMax > 1e-12 else { return (1e7, []) }
        let sigmaMin = max(sigmas.min() ?? 0, 1e-300)
        let conditionNumber = Float(min(sigmaMax / sigmaMin, 1e7))

        let axes: [DegenerateAxis] = [.translationX, .translationY, .translationZ, .rotationX, .rotationY, .rotationZ]
        var weak: [(axis: DegenerateAxis, sigma: Double, ratio: Double)] = []
        for k in 0..<6 {
            let ratio = sigmaMax / max(sigmas[k], 1e-300)
            guard ratio > Double(threshold) else { continue }
            var bestIdx = 0
            var bestMag = abs(eig.vectors[0][k])
            for i in 1..<6 {
                let m = abs(eig.vectors[i][k])
                if m > bestMag { bestMag = m; bestIdx = i }
            }
            weak.append((axis: axes[bestIdx], sigma: sigmas[k], ratio: ratio))
        }
        weak.sort { $0.ratio > $1.ratio }

        return (conditionNumber, weak.map { WeakDirection(axis: $0.axis, sigma: Float($0.sigma)) })
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