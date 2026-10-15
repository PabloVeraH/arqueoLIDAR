import Testing
@testable import Registration

// ═══════════════════════════════════════════════════════════════════════════════
// F11 — SymmetricEigenSolver: verificación independiente del solver de Jacobi
// que usa `ICPAligner.computeConditionNumber` (fixes.md). No basta con que
// el número de condición de escenas conocidas "se vea razonable" — el
// propio autovalor/autovector debe reconstruir la matriz original dentro
// de tolerancia numérica, para cualquier matriz simétrica, no solo las
// que aparecen en los tests de ICP.
// ═══════════════════════════════════════════════════════════════════════════════

@Suite("F11 Registration: SymmetricEigenSolver (Jacobi)")
struct SymmetricEigenJacobiTests {

    @Test("Matriz diagonal: autovalores son la diagonal, autovectores son la identidad")
    func diagonalMatrix() {
        let diag = [5.0, 3.0, 1.0, 4.0, 2.0, 6.0]
        var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for i in 0..<6 { a[i][i] = diag[i] }

        let result = SymmetricEigenSolver.solve(a)

        #expect(result.values == diag)
        for i in 0..<6 {
            for j in 0..<6 {
                let expected = i == j ? 1.0 : 0.0
                #expect(abs(result.vectors[i][j] - expected) < 1e-12)
            }
        }
    }

    @Test("Bloque 2×2 con autovalores/autovectores conocidos a mano")
    func knownTwoByTwoBlock() {
        // [[2,1],[1,2]] tiene autovalores 3 y 1, autovectores (1,1)/√2 y (1,-1)/√2.
        // Embebido en 6×6 con el resto identidad (autovalor 1, ya diagonal).
        var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        for i in 2..<6 { a[i][i] = 1 }
        a[0][0] = 2; a[0][1] = 1
        a[1][0] = 1; a[1][1] = 2

        let result = SymmetricEigenSolver.solve(a)
        let sorted = result.values.sorted()
        // Espectro esperado: {3, 1, 1, 1, 1, 1} — el 3 y uno de los 1 vienen
        // del bloque 2×2 (filas/columnas 0,1, aislado del resto); los otros
        // cuatro 1 vienen del bloque identidad (filas/columnas 2..5).
        #expect(abs(sorted[5] - 3.0) < 1e-9)
        for v in sorted[0...4] {
            #expect(abs(v - 1.0) < 1e-9)
        }
    }

    @Test("Reconstrucción: A·v_k ≈ λ_k·v_k para una matriz simétrica genérica")
    func eigenpairsReconstructOriginalMatrix() {
        // Matriz simétrica arbitraria (no diagonal, sin estructura de bloque),
        // fija y determinista.
        let raw: [[Double]] = [
            [4, 1, 2, 0, 1, 0],
            [1, 3, 0, 1, 0, 2],
            [2, 0, 5, 1, 0, 1],
            [0, 1, 1, 2, 1, 0],
            [1, 0, 0, 1, 6, 1],
            [0, 2, 1, 0, 1, 3],
        ]

        let result = SymmetricEigenSolver.solve(raw)

        for k in 0..<6 {
            let lambda = result.values[k]
            for row in 0..<6 {
                var avRow = 0.0
                for col in 0..<6 { avRow += raw[row][col] * result.vectors[col][k] }
                let expected = lambda * result.vectors[row][k]
                #expect(abs(avRow - expected) < 1e-8, "A·v_\(k) discrepa de λ_\(k)·v_\(k) en la fila \(row)")
            }
        }
    }

    @Test("Autovectores ortonormales: V^T V ≈ I")
    func eigenvectorsAreOrthonormal() {
        let raw: [[Double]] = [
            [4, 1, 2, 0, 1, 0],
            [1, 3, 0, 1, 0, 2],
            [2, 0, 5, 1, 0, 1],
            [0, 1, 1, 2, 1, 0],
            [1, 0, 0, 1, 6, 1],
            [0, 2, 1, 0, 1, 3],
        ]
        let result = SymmetricEigenSolver.solve(raw)

        for i in 0..<6 {
            for j in 0..<6 {
                var dot = 0.0
                for row in 0..<6 { dot += result.vectors[row][i] * result.vectors[row][j] }
                let expected = i == j ? 1.0 : 0.0
                #expect(abs(dot - expected) < 1e-8, "v_\(i)·v_\(j) = \(dot), se esperaba \(expected)")
            }
        }
    }

    @Test("Traza se conserva: Σ autovalores == Σ diagonal original")
    func traceIsPreserved() {
        let raw: [[Double]] = [
            [4, 1, 2, 0, 1, 0],
            [1, 3, 0, 1, 0, 2],
            [2, 0, 5, 1, 0, 1],
            [0, 1, 1, 2, 1, 0],
            [1, 0, 0, 1, 6, 1],
            [0, 2, 1, 0, 1, 3],
        ]
        let originalTrace = (0..<6).reduce(0.0) { $0 + raw[$1][$1] }
        let result = SymmetricEigenSolver.solve(raw)
        let eigenTrace = result.values.reduce(0, +)
        #expect(abs(originalTrace - eigenTrace) < 1e-9)
    }
}
