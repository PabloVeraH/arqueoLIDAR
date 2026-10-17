import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F8 — SiteFrameResolver. Combina UTMConverter + FixQualityGate + TrackYawSolver
// para resolver el marco de sitio canónico: origen UTM, yaw al norte verdadero,
// y la matriz arWorldToSite.
// ═══════════════════════════════════════════════════════════════════════════════

public struct SiteFrameResolver: SiteFrameResolving, Sendable {

    private let converter: UTMConverter
    private let qualityGate: FixQualityGate
    private let yawSolver: TrackYawSolver

    public init(
        converter: UTMConverter = UTMConverter(),
        qualityGate: FixQualityGate = FixQualityGate(),
        yawSolver: TrackYawSolver = TrackYawSolver()
    ) {
        self.converter = converter
        self.qualityGate = qualityGate
        self.yawSolver = yawSolver
    }

    public func resolve(
        cameraTrack: [(time: Date, transform: Matrix4x4)],
        fixes: [GeoFix],
        magneticHeading: Double? = nil
    ) throws(GeoError) -> (frame: SiteFrame, arWorldToSite: Matrix4x4) {

        // 1. Evaluar calidad del burst GPS.
        let verdict = qualityGate.evaluate(burst: fixes)

        guard let chosenFix = verdict.chosenFix else {
            throw .noFixAvailable
        }

        // 2. Convertir a UTM.
        let utm = try converter.toUTM(
            latitude: chosenFix.latitude,
            longitude: chosenFix.longitude,
            height: chosenFix.altitude
        )

        // 3. Convergencia meridiana.
        let convergence = converter.meridianConvergence(
            latitude: chosenFix.latitude,
            longitude: chosenFix.longitude,
            zone: utm.zone
        )

        // 4. Resolver yaw por trayectoria AR vs GPS.
        let (yaw, yawSigma) = try yawSolver.resolve(
            cameraTrack: cameraTrack,
            fixes: fixes
        )

        // 5. Construir marco de sitio.
        let siteID = UUID()
        let frame = SiteFrame(
            siteID: siteID,
            origin: utm,
            yawFromTrueNorth: yaw,
            yawSigma: yawSigma,
            meridianConvergence: Float(convergence)
        )

        // 6. Construir arWorldToSite: rotación del marco AR al marco de sitio.
        //    Marco AR: +X derecha, +Y arriba, +Z hacia atrás (right-handed, gravity).
        //    Marco de sitio: +X Este, +Y Arriba, -Z Norte.
        //    Yaw = rotación alrededor de Y (arriba) desde +X AR hacia el Este verdadero.
        return (frame: frame, arWorldToSite: Self.rotation(yaw: yaw))
    }

    /// Rotación alrededor de +Y que lleva el marco AR al de sitio para un yaw de
    /// TrackYawSolver.horn: un punto AR (x, y, z) queda en (E, y, −N) con
    /// (E, N) = R(yaw)·(x, −z). La usa también ControlPointAligner.
    static func rotation(yaw: Float) -> Matrix4x4 {
        let cosY = cos(yaw), sinY = sin(yaw)
        return Matrix4x4(
            SIMD4(cosY, 0, -sinY, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(sinY, 0, cosY, 0),
            SIMD4(0, 0, 0, 1)
        )
    }
}