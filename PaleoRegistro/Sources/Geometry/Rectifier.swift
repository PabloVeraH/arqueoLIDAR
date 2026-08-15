import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F2 — Rectifier: orto-imagen métrica sobre un plano. Proyecta puntos 3D sobre
// el plano (marco local u/v de la imagen) y rasteriza con escala conocida
// (px/m). Base de las orto-imágenes de pared para estratigrafía (F6).
// ═══════════════════════════════════════════════════════════════════════════════

/// Orto-imagen rectificada con escala métrica conocida.
public struct RectifiedOrthoImage: Sendable, Codable, Equatable {
    /// Ancho en píxeles.
    public var width: Int
    /// Alto en píxeles.
    public var height: Int
    /// Resolución en px/m.
    public var resolution: Float
    /// Plano de proyección.
    public var plane: Plane
    /// Eje u (dirección horizontal de la imagen, en metros).
    public var basisU: SIMD3<Float>
    /// Eje v (dirección vertical de la imagen, en metros).
    public var basisV: SIMD3<Float>
    /// Punto 3D correspondiente al píxel (0, 0).
    public var origin: SIMD3<Float>
    /// Altura sobre el plano por celda (negativa enorme = celda vacía).
    public var heights: [Float]
    /// Número de muestras por celda (0 = vacía).
    public var counts: [Int]

    public static let emptyHeight: Float = -Float.greatestFiniteMagnitude
}

/// Proyección métrica de nubes/mallas sobre un plano para producir orto-imágenes.
public struct Rectifier: Sendable {
    public var resolution: Float

    public init(resolution: Float = 200) {
        self.resolution = resolution
    }

    /// Base ortonormal determinista dentro del plano: u = dirección horizontal
    /// (strike) cuando el plano no es horizontal, v = cruce con la normal.
    public static func makeBasis(plane: Plane) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let n = plane.normal
        let up = SIMD3<Float>(0, 1, 0)
        var u = vecCross(up, n)
        if vecLength(u) < 1e-6 {
            u = SIMD3(1, 0, 0)
        } else {
            u = vecNormalize(u)
        }
        let v = vecNormalize(vecCross(n, u))
        return (u, v)
    }

    /// Coordenadas locales (u, v) en metros sobre el plano, origen = `plane.point`.
    public static func localCoordinates(_ p: SIMD3<Float>, plane: Plane) -> SIMD2<Float> {
        let basis = makeBasis(plane: plane)
        let o = p - plane.point
        return SIMD2(vecDot(o, basis.u), vecDot(o, basis.v))
    }

    /// Proyecta los puntos sobre el plano y rasteriza una grilla de alturas.
    /// Devuelve la orto-imagen con escala `resolution` px/m.
    public func rectify(
        points: [SIMD3<Float>],
        plane: Plane
    ) throws(GeometryError) -> RectifiedOrthoImage {
        guard !points.isEmpty else { throw .insufficientPoints(0) }
        guard resolution > 0, resolution.isFinite else {
            throw .invalidInput("resolución debe ser > 0")
        }

        let basis = Self.makeBasis(plane: plane)
        var minU = Float.greatestFiniteMagnitude
        var maxU = -Float.greatestFiniteMagnitude
        var minV = Float.greatestFiniteMagnitude
        var maxV = -Float.greatestFiniteMagnitude
        for p in points {
            let o = p - plane.point
            let u = vecDot(o, basis.u)
            let v = vecDot(o, basis.v)
            minU = min(minU, u)
            maxU = max(maxU, u)
            minV = min(minV, v)
            maxV = max(maxV, v)
        }
        guard maxU > minU, maxV > minV else {
            throw .degenerateConfiguration("rango de proyección nulo")
        }

        // Píxel (0,0) corresponde al borde inferior-izquierdo del rango.
        let width = max(1, Int(ceil((maxU - minU) * resolution)))
        let height = max(1, Int(ceil((maxV - minV) * resolution)))
        var heights = [Float](repeating: RectifiedOrthoImage.emptyHeight, count: width * height)
        var counts = [Int](repeating: 0, count: width * height)

        for p in points {
            let o = p - plane.point
            let u = vecDot(o, basis.u)
            let v = vecDot(o, basis.v)
            let h = vecDot(o, plane.normal)
            let col = Int(((u - minU) * resolution).rounded(.down))
            let row = Int(((v - minV) * resolution).rounded(.down))
            let colClamped = min(width - 1, max(0, col))
            let rowClamped = min(height - 1, max(0, row))
            let idx = rowClamped * width + colClamped
            if heights[idx] == RectifiedOrthoImage.emptyHeight || h > heights[idx] {
                heights[idx] = h
            }
            counts[idx] += 1
        }

        let origin = plane.point + basis.u * minU + basis.v * minV
        return RectifiedOrthoImage(
            width: width,
            height: height,
            resolution: resolution,
            plane: plane,
            basisU: basis.u,
            basisV: basis.v,
            origin: origin,
            heights: heights,
            counts: counts
        )
    }

    /// Píxel (x, y) de un punto 3D proyectado. Devuelve nil si cae fuera.
    public func pixel(for p: SIMD3<Float>, in image: RectifiedOrthoImage) -> (Int, Int)? {
        let o = p - image.plane.point
        let u = vecDot(o, image.basisU)
        let v = vecDot(o, image.basisV)
        let rel = image.origin - image.plane.point
        let col = Int(((u - vecDot(rel, image.basisU)) * image.resolution).rounded(.down))
        let row = Int(((v - vecDot(rel, image.basisV)) * image.resolution).rounded(.down))
        guard col >= 0, row >= 0, col < image.width, row < image.height else {
            return nil
        }
        return (col, row)
    }
}