import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F11 — closestPointOnTriangle: proyección de un punto sobre la superficie de un
// triángulo (no solo sobre sus vértices). Es la pieza que permite a `ICPAligner`
// buscar correspondencias punto→superficie en vez de punto→vértice más cercano
// (ver fixes.md, "correspondencia punto→triángulo"): con nearest-vertex, la
// distancia mínima posible entre una fuente y la superficie target está acotada
// por el espaciado real de los vértices del target (el espaciado del sensor
// LiDAR, no un parámetro que el algoritmo controle) — proyectar sobre el
// triángulo reduce ese error de cuantización a segundo orden dentro de cada
// cara, igual que hace cualquier motor de colisión o de raycasting contra malla.
// ═══════════════════════════════════════════════════════════════════════════════

/// Punto más cercano a `p` sobre el triángulo (a, b, c), y sus coordenadas
/// baricéntricas (u, v, w) tales que `point == a·u + b·v + c·w`, con
/// u + v + w == 1. Las baricéntricas permiten interpolar cualquier atributo
/// por vértice (aquí, normales) en el punto de correspondencia exacto, no
/// solo en el vértice más cercano.
///
/// Algoritmo de Ericson, *"Real-Time Collision Detection"* (2005), §5.1.5 —
/// clasifica en qué región de Voronoi del triángulo cae `p` (el interior, una
/// de las 3 aristas, o uno de los 3 vértices) usando solo productos punto,
/// sin normalizar por área hasta el caso interior. Un triángulo degenerado
/// (a == b == c, el caso de una nube de puntos sin triangulación real) cae
/// siempre en la primera rama (región del vértice `a`) y se comporta como
/// punto único — mismo resultado que la búsqueda punto→vértice anterior.
func closestPointOnTriangle(
    _ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>
) -> (point: SIMD3<Float>, barycentric: SIMD3<Float>) {
    let ab = b - a
    let ac = c - a
    let ap = p - a

    let d1 = vecDot(ab, ap)
    let d2 = vecDot(ac, ap)
    if d1 <= 0 && d2 <= 0 { return (a, SIMD3(1, 0, 0)) } // región del vértice a

    let bp = p - b
    let d3 = vecDot(ab, bp)
    let d4 = vecDot(ac, bp)
    if d3 >= 0 && d4 <= d3 { return (b, SIMD3(0, 1, 0)) } // región del vértice b

    let vc = d1 * d4 - d3 * d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        let v = d1 / (d1 - d3)
        return (a + ab * v, SIMD3(1 - v, v, 0)) // región de la arista ab
    }

    let cp = p - c
    let d5 = vecDot(ab, cp)
    let d6 = vecDot(ac, cp)
    if d6 >= 0 && d5 <= d6 { return (c, SIMD3(0, 0, 1)) } // región del vértice c

    let vb = d5 * d2 - d1 * d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        let w = d2 / (d2 - d6)
        return (a + ac * w, SIMD3(1 - w, 0, w)) // región de la arista ac
    }

    let va = d3 * d6 - d5 * d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
        let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return (b + (c - b) * w, SIMD3(0, 1 - w, w)) // región de la arista bc
    }

    // Región interior: proyección baricéntrica normal (única división del
    // camino feliz, evitada en todos los casos de arista/vértice de arriba).
    let denom = 1 / (va + vb + vc)
    let v = vb * denom
    let w = vc * denom
    return (a + ab * v + ac * w, SIMD3(1 - v - w, v, w))
}
