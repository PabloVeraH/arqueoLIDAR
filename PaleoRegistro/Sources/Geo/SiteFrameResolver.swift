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
        let cosY = cos(yaw)
        let sinY = sin(yaw)

        // Rotación: columnas de la matriz de rotación 3x3.
        // Columna X: hacia dónde apunta +X AR en marco de sitio (Este rotado por yaw).
        // Columna Y: arriba (igual).
        // Columna Z: hacia dónde apunta +Z AR en marco de sitio (rotado por yaw).
        let r00 = cosY;  let r02 = sinY   // +X AR → (cosY, 0, sinY) en ENU
        let r20 = -sinY; let r22 = cosY   // +Z AR → (−sinY, 0, cosY) en ENU
        // Nota: +Z AR = forward (into screen) = −Z ENU = Sur. Ajustamos signo.

        let arWorldToSite = Matrix4x4(
            SIMD4(r00, 0, r20, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(r02, 0, r22, 0),
            SIMD4(0, 0, 0, 1)
        )

        return (frame: frame, arWorldToSite: arWorldToSite)
    }
}