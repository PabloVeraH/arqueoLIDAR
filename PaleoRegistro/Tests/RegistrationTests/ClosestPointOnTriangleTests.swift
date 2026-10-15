import Testing
import Foundation
import Domain
@testable import Registration

// ═══════════════════════════════════════════════════════════════════════════════
// F11 — closestPointOnTriangle: verifica la clasificación de regiones de Voronoi
// del triángulo (interior, 3 aristas, 3 vértices) de Ericson, "Real-Time
// Collision Detection" (2005), §5.1.5 — el mecanismo detrás de la correspondencia
// punto→superficie de ICPAligner (antes: punto→vértice más cercano, que cuantiza
// la superficie target al espaciado de sus vértices; ver fixes.md,
// "correspondencia punto→triángulo").
// ═══════════════════════════════════════════════════════════════════════════════

@Suite("F11 Registration: closestPointOnTriangle")
struct ClosestPointOnTriangleTests {

    // Triángulo de referencia en el plano XZ (normal +Y), lado 1.
    let a = SIMD3<Float>(0, 0, 0)
    let b = SIMD3<Float>(1, 0, 0)
    let c = SIMD3<Float>(0, 0, 1)

    @Test("Punto sobre el plano, dentro del triángulo → proyección directa, baricéntricas suman 1")
    func interiorPoint() {
        let p = SIMD3<Float>(0.2, 0.5, 0.2) // encima del centro-ish, elevado en Y
        let result = closestPointOnTriangle(p, a, b, c)

        // La proyección debe caer en el plano Y=0, dentro del triángulo,
        // directamente bajo p (mismo X, Z).
        #expect(abs(result.point.y) < 1e-5)
        #expect(abs(result.point.x - p.x) < 1e-5)
        #expect(abs(result.point.z - p.z) < 1e-5)

        let bc = result.barycentric
        #expect(abs((bc.x + bc.y + bc.z) - 1.0) < 1e-5, "Baricéntricas deben sumar 1")
        let reconstructed = a * bc.x + b * bc.y + c * bc.z
        #expect(vecLength(reconstructed - result.point) < 1e-5)
    }

    @Test("Punto sobre la región de Voronoi del vértice a → devuelve a")
    func vertexRegionA() {
        let p = SIMD3<Float>(-1, 0, -1) // lejos, en dirección opuesta a b y c
        let result = closestPointOnTriangle(p, a, b, c)
        #expect(vecLength(result.point - a) < 1e-5)
        #expect(vecLength(result.barycentric - SIMD3(1, 0, 0)) < 1e-5)
    }

    @Test("Punto sobre la región de Voronoi del vértice b → devuelve b")
    func vertexRegionB() {
        let p = SIMD3<Float>(2, 0, -1)
        let result = closestPointOnTriangle(p, a, b, c)
        #expect(vecLength(result.point - b) < 1e-5)
    }

    @Test("Punto sobre la región de Voronoi del vértice c → devuelve c")
    func vertexRegionC() {
        let p = SIMD3<Float>(-1, 0, 2)
        let result = closestPointOnTriangle(p, a, b, c)
        #expect(vecLength(result.point - c) < 1e-5)
    }

    @Test("Punto fuera, frente a la arista ab → cae sobre el segmento ab, no en un vértice")
    func edgeRegionAB() {
        let p = SIMD3<Float>(0.5, 0, -1) // fuera del triángulo, "debajo" de ab (Z negativo)
        let result = closestPointOnTriangle(p, a, b, c)
        #expect(abs(result.point.z) < 1e-5, "Debe caer sobre la arista ab (Z=0)")
        #expect(result.point.x > 0 && result.point.x < 1, "Debe estar estrictamente dentro del segmento, no en un extremo")
    }

    @Test("Punto fuera, frente a la arista bc → cae sobre el segmento bc")
    func edgeRegionBC() {
        let p = SIMD3<Float>(1, 0, 1) // fuera, en la diagonal opuesta al origen
        let result = closestPointOnTriangle(p, a, b, c)
        // La arista bc va de (1,0,0) a (0,0,1): x+z=1 sobre ella.
        #expect(abs((result.point.x + result.point.z) - 1.0) < 1e-4)
    }

    @Test("Triángulo degenerado (a=b=c) se comporta como punto único — caso nube de puntos sin triangulación")
    func degenerateTriangleIsPoint() {
        let single = SIMD3<Float>(3, 4, 5)
        let p = SIMD3<Float>(10, 10, 10)
        let result = closestPointOnTriangle(p, single, single, single)
        #expect(vecLength(result.point - single) < 1e-5)
    }

    @Test("Distancia al punto proyectado nunca es mayor que la distancia a cualquier vértice")
    func projectionNeverWorseThanVertices() {
        let points: [SIMD3<Float>] = [
            SIMD3(0.3, 0.7, 0.1), SIMD3(-2, 1, 0.5), SIMD3(5, -3, 2), SIMD3(0.1, 0, 0.1),
        ]
        for p in points {
            let result = closestPointOnTriangle(p, a, b, c)
            let dProj = vecLength(p - result.point)
            let dA = vecLength(p - a)
            let dB = vecLength(p - b)
            let dC = vecLength(p - c)
            #expect(dProj <= min(dA, dB, dC) + 1e-4, "La proyección sobre la superficie debe ser al menos tan buena como el mejor vértice")
        }
    }

    /// Malla esférica de referencia para medir la reducción de error de
    /// cuantización en superficie CURVA — el escenario donde este cambio
    /// realmente importa. Un cubo de caras planas (como `denseCubeMesh`, el
    /// usado en `RegistrationTests`) no puede exhibir este efecto: el
    /// residuo punto-a-plano ya es invariante a qué punto de una misma cara
    /// plana se use como correspondencia (ver comentario en
    /// `ICPAligner.align`), así que nearest-vertex y point-to-triangle dan
    /// prácticamente el mismo resultado ahí — medido empíricamente: 0.0616 m
    /// de error de traslación en ambos casos, sin diferencia. En una
    /// superficie curva el plano tangente cambia de un vértice a otro, y
    /// ahí es donde nearest-vertex pierde precisión de verdad.
    private func sphereMesh(radius: Float, lat: Int, lon: Int) -> Mesh {
        var verts: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0...lat {
            let theta = Float.pi * Float(i) / Float(lat)
            for j in 0...lon {
                let phi = 2 * Float.pi * Float(j) / Float(lon)
                verts.append(SIMD3(radius * sin(theta) * cos(phi), radius * cos(theta), radius * sin(theta) * sin(phi)))
            }
        }
        let stride = lon + 1
        for i in 0..<lat {
            for j in 0..<lon {
                let idxA = UInt32(i * stride + j), idxB = UInt32(i * stride + j + 1)
                let idxC = UInt32((i + 1) * stride + j), idxD = UInt32((i + 1) * stride + j + 1)
                indices.append(contentsOf: [idxA, idxB, idxC])
                indices.append(contentsOf: [idxB, idxD, idxC])
            }
        }
        return Mesh(vertices: verts, indices: indices)
    }

    @Test("En superficie curva, point-to-triangle reduce el error de cuantización a menos de la mitad de nearest-vertex")
    func curvedSurfaceQuantizationReduction() {
        let sphere = sphereMesh(radius: 1.0, lat: 8, lon: 8)
        var rng = SplitMix64(seed: 7)
        var sumSqVertex: Double = 0
        var sumSqTriangle: Double = 0
        let sampleCount = 300

        for _ in 0..<sampleCount {
            // Punto aleatorio sobre la esfera UNITARIA exacta (distribución
            // uniforme en área, no en ángulos) — simula una fuente densa
            // contra un target discretizado más grueso.
            let u = Float.random(in: 0...1, using: &rng)
            let v = Float.random(in: 0...1, using: &rng)
            let theta = acos(2 * u - 1)
            let phi = 2 * Float.pi * v
            let q = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))

            var bestVertexDist: Float = .infinity
            for vtx in sphere.vertices {
                bestVertexDist = min(bestVertexDist, vecLength(q - vtx))
            }

            var bestTriDist: Float = .infinity
            let triCount = sphere.indices.count / 3
            for t in 0..<triCount {
                let ta = sphere.vertices[Int(sphere.indices[t * 3])]
                let tb = sphere.vertices[Int(sphere.indices[t * 3 + 1])]
                let tc = sphere.vertices[Int(sphere.indices[t * 3 + 2])]
                let proj = closestPointOnTriangle(q, ta, tb, tc)
                bestTriDist = min(bestTriDist, vecLength(q - proj.point))
            }

            sumSqVertex += Double(bestVertexDist * bestVertexDist)
            sumSqTriangle += Double(bestTriDist * bestTriDist)
        }

        let rmsVertex = (sumSqVertex / Double(sampleCount)).squareRoot()
        let rmsTriangle = (sumSqTriangle / Double(sampleCount)).squareRoot()

        // Medido: rmsVertex≈0.218, rmsTriangle≈0.053 (76% de reducción) con
        // esta malla y semilla. El umbral de 0.5 deja margen generoso sobre
        // lo medido mientras sigue siendo una aserción real, no un piso
        // trivial.
        #expect(rmsTriangle < rmsVertex * 0.5,
                "point-to-triangle (\(rmsTriangle)) debe reducir el RMS de cuantización a menos de la mitad de nearest-vertex (\(rmsVertex)) en superficie curva")
    }
}
