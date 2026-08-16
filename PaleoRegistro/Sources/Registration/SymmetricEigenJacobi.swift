// ═══════════════════════════════════════════════════════════════════════════════
// F11 — SymmetricEigenSolver. Descomposición espectral de una matriz
// simétrica pequeña (aquí, 6×6) vía el método cíclico de Jacobi (Golub &
// Van Loan, "Matrix Computations", §8.4; forma de actualización con `tau`
// de Press et al., "Numerical Recipes in C", §11.1 — reduce el error de
// redondeo frente a la forma directa c/s).
//
// Puro Swift, sin LAPACK/Accelerate: `Registration` es un módulo de
// arquitectura pura (Scripts/check_module_boundaries.sh lo prohibiría de
// todas formas), y usar Accelerate solo en macOS mientras Linux corre una
// implementación distinta introduciría una divergencia entre plataformas
// inaceptable para un proyecto donde el veredicto de degeneración de un
// calce puede terminar en un informe pericial — el mismo criterio que ya
// se aplicó a `Mesh/PLYCodec` y al SHA-256 autocontenido de
// `Persistence/CanonicalJSON.swift` (fixes.md, "computeConditionNumber").
//
// En Double explícitamente (no Float): el propio historial de este archivo
// documenta pérdida de precisión sospechada en un determinante 6×6 en
// Float como una causa probable del falso positivo que hizo abortar el
// primer intento de usar el Hessiano real (ver ICPAligner.computeConditionNumber).
// ═══════════════════════════════════════════════════════════════════════════════

enum SymmetricEigenSolver {

    struct Result {
        /// Autovalores, sin ordenar, en el mismo orden que las columnas de `vectors`.
        let values: [Double]
        /// Autovectores como columnas: `vectors[i][k]` es la componente `i` del autovector `k`.
        let vectors: [[Double]]
    }

    /// Diagonaliza una matriz simétrica `n×n` (solo se lee/escribe el
    /// triángulo superior, incluida la diagonal — el inferior se ignora,
    /// convención estándar de esta familia de algoritmos). `maxSweeps` de
    /// sobra para n=6 (converge típicamente en 4-8 barridos); `tolerance`
    /// es la suma de valores absolutos del triángulo superior fuera de la
    /// diagonal por debajo de la cual se considera diagonalizada.
    static func solve(_ symmetric: [[Double]], maxSweeps: Int = 100, tolerance: Double = 1e-13) -> Result {
        let n = symmetric.count
        var a = symmetric
        var v = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { v[i][i] = 1 }

        guard n > 1 else {
            return Result(values: n == 1 ? [a[0][0]] : [], vectors: v)
        }

        func rotate(_ m: inout [[Double]], _ i: Int, _ j: Int, _ k: Int, _ l: Int, _ s: Double, _ tau: Double) {
            let g = m[i][j]
            let h = m[k][l]
            m[i][j] = g - s * (h + g * tau)
            m[k][l] = h + s * (g - h * tau)
        }

        for _ in 0..<maxSweeps {
            var offDiagSum: Double = 0
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    offDiagSum += abs(a[p][q])
                }
            }
            if offDiagSum < tolerance { break }

            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    guard abs(a[p][q]) > 1e-300 else { continue }

                    let h = a[q][q] - a[p][p]
                    let t: Double
                    if abs(h) < 1e-300 {
                        t = 1
                    } else {
                        let theta = 0.5 * h / a[p][q]
                        let denom = abs(theta) + (1 + theta * theta).squareRoot()
                        t = theta >= 0 ? 1 / denom : -1 / denom
                    }
                    let c = 1 / (1 + t * t).squareRoot()
                    let s = t * c
                    let tau = s / (1 + c)
                    let hpq = t * a[p][q]

                    a[p][p] -= hpq
                    a[q][q] += hpq
                    a[p][q] = 0

                    for j in 0..<p { rotate(&a, j, p, j, q, s, tau) }
                    for j in (p + 1)..<q { rotate(&a, p, j, j, q, s, tau) }
                    for j in (q + 1)..<n { rotate(&a, p, j, q, j, s, tau) }
                    for j in 0..<n { rotate(&v, j, p, j, q, s, tau) }
                }
            }
        }

        var values = [Double](repeating: 0, count: n)
        for i in 0..<n { values[i] = a[i][i] }
        return Result(values: values, vectors: v)
    }
}
