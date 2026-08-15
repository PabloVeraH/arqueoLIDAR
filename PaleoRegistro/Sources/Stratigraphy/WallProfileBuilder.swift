import Foundation
import Domain
import Geometry

// ═══════════════════════════════════════════════════════════════════════════════
// F6 — Perfil de pared: ajusta el plano de la pared de corte con restricción
// vertical (aprovechando la clasificación `wall` de ARKit como prior) y genera
// la orto-imagen métrica rectificada donde el operador marca los límites de
// nivel. Base de la estratigrafía: el LiDAR no ve cambio de nivel entre dos
// arcillas de igual dureza, los límites son transiciones cromáticas/de textura
// sobre la orto-imagen 2D, no sobre la malla 3D.
// ═══════════════════════════════════════════════════════════════════════════════

/// Perfil de pared: plano ajustado + orto-imagen rectificada con escala métrica.
public struct WallProfile: Sendable {
    /// Plano de la pared de corte (normal aprox. horizontal por restricción vertical).
    public var plane: Plane
    /// Orto-imagen rectificada con escala conocida (px/m).
    public var orthoImage: RectifiedOrthoImage
    /// RMS de los inliers del ajuste (incertidumbre del plano), metros.
    public var inlierRMS: Float

    public init(plane: Plane, orthoImage: RectifiedOrthoImage, inlierRMS: Float) {
        self.plane = plane
        self.orthoImage = orthoImage
        self.inlierRMS = inlierRMS
    }
}

/// Construye el perfil de pared ajustando el plano (restricción vertical) y
/// generando la orto-imagen métrica. Prerequisito duro: F2 (Rectifier + ajuste
/// con restricción de orientación).
public struct WallProfileBuilder: Sendable {
    public var resolution: Float
    public var options: PlaneFitOptions

    public static var algorithmVersion: String { "1.0.0" }

    public init(resolution: Float = 500, options: PlaneFitOptions? = nil) {
        self.resolution = resolution
        self.options = options ?? PlaneFitOptions(
            maxIterations: 500,
            inlierDistance: 0.02,
            minInliers: 50,
            constraint: .vertical(maxTiltDegrees: 15),
            scoring: .msac,
            confidence: 0.99,
            rngSeed: 0x9E3779B97F4A7C15
        )
    }

    /// Construye el perfil: ajusta plano vertical + orto-imagen.
    public func build(
        points: [SIMD3<Float>]
    ) throws(GeometryError) -> WallProfile {
        guard points.count >= 3 else { throw .insufficientPoints(points.count) }

        let fitter = RANSACPlaneFitter()
        let plane = try fitter.fit(
            points: points,
            normals: nil,
            options: options
        )
        let rms = plane.inlierRMS ?? 0

        let rectifier = Rectifier(resolution: resolution)
        let ortho = try rectifier.rectify(points: points, plane: plane)

        return WallProfile(plane: plane, orthoImage: ortho, inlierRMS: rms)
    }
}
