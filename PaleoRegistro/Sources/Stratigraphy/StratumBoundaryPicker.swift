import Foundation
import Domain
import Geometry

// ═══════════════════════════════════════════════════════════════════════════════
// F6 — Marcación de límites de estrato sobre la orto-imagen 2D. El operador
// marca los límites de nivel sobre la orto-imagen rectificada (no sobre la
// malla 3D), porque los límites son transiciones cromáticas/de textura que el
// LiDAR no resuelve geométricamente. Cada píxel marcado se retro-proyecta al
// plano de la pared y produce una StratumBoundary con posición 3D. La
// reproducibilidad es bit a bit: los mismos píxeles producen la misma potencia.
// ═══════════════════════════════════════════════════════════════════════════════

/// Una marca del operador: (límite, píxel) sobre la orto-imagen.
public struct PixelMark: Sendable, Equatable {
    public var boundaryID: UUID
    public var col: Int
    public var row: Int

    public init(boundaryID: UUID, col: Int, row: Int) {
        self.boundaryID = boundaryID
        self.col = col
        self.row = row
    }
}

/// Retro-proyecta píxeles marcados sobre la orto-imagen a posiciones 3D en el
/// plano de la pared. Cada límite queda como un conjunto de marcas 3D.
public struct StratumBoundaryPicker: Sendable {
    public static var algorithmVersion: String { "1.0.0" }

    public init() {}

    /// Convierte un píxel de la orto-imagen a posición 3D sobre el plano.
    /// Usa el centro del píxel (col+0.5, row+0.5) y el origen/ejes de la imagen.
    public func backProject(
        col: Int,
        row: Int,
        in image: RectifiedOrthoImage
    ) -> SIMD3<Float> {
        let u = (Float(col) + 0.5) / image.resolution
        let v = (Float(row) + 0.5) / image.resolution
        return image.origin + image.basisU * u + image.basisV * v
    }

    /// Retro-proyecta todas las marcas a StratumBoundary (una entrada por píxel).
    /// Los límites se agrupan por `boundaryID`; el `imagePoint` guarda el píxel
    /// (x,y) como SIMD2 para trazabilidad y reproducibilidad.
    public func pick(
        marks: [PixelMark],
        in image: RectifiedOrthoImage
    ) throws(StratigraphyError) -> [StratumBoundary] {
        guard !marks.isEmpty else { throw .noOrthoImage }

        var result: [StratumBoundary] = []
        result.reserveCapacity(marks.count)
        for mark in marks {
            guard mark.col >= 0, mark.row >= 0,
                  mark.col < image.width, mark.row < image.height else {
                continue
            }
            let pos = backProject(col: mark.col, row: mark.row, in: image)
            result.append(StratumBoundary(
                boundaryID: mark.boundaryID,
                position: pos,
                imagePoint: SIMD2<Float>(Float(mark.col), Float(mark.row))
            ))
        }
        guard !result.isEmpty else { throw .noOrthoImage }
        return result
    }
}
