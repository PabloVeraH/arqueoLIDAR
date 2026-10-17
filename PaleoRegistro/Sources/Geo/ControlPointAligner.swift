import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F8 — ControlPointAligner (plan §2.C.5, ManualCoordinateProvider). Con dos o
// más puntos marcados en la captura cuya coordenada entrega un topógrafo (GNSS
// diferencial), el marco de sitio sale de esos puntos y no del GPS del teléfono:
// el norte verdadero se obtiene con la misma alineación de Horn que el recorrido
// GPS, y el origen queda en el primer punto, con precisión de centímetros.
// ═══════════════════════════════════════════════════════════════════════════════

public struct ControlPointAligner: Sendable {

    /// Distancia mínima entre puntos de control para fijar el norte (m). Con
    /// ±2 cm por punto, 1 m de base deja el yaw en ~1,6°; más base, mejor.
    public static let minBaseline: Float = 1.0

    private let converter: UTMConverter

    public init(converter: UTMConverter = UTMConverter()) {
        self.converter = converter
    }

    /// - Returns: marco de sitio con origen en el primer punto y la matriz marco
    ///   AR → sitio (rotación por el yaw y traslación del primer punto al origen).
    public func resolve(_ points: [ControlPoint]) throws(GeoError) -> (frame: SiteFrame, arWorldToSite: Matrix4x4) {
        guard points.count >= 2, let first = points.first else {
            throw .degenerateTrack("se necesitan al menos 2 puntos de control (hay \(points.count))")
        }
        let pairs = points.map { p in
            (SIMD2<Float>(p.arPosition.x, -p.arPosition.z), TrackYawSolver.localEN(p.fix, origin: first.fix))
        }
        let baseline = pairs.map { vecLength2D($0.0 - pairs[0].0) }.max() ?? 0
        guard baseline >= Self.minBaseline else {
            throw .degenerateTrack("los puntos de control están a \(baseline) m entre sí; se necesitan al menos \(Self.minBaseline) m")
        }

        let (yaw, hornSigma) = try TrackYawSolver.horn(pairs)
        // Con 2 puntos el residuo de Horn es 0 por construcción: la incertidumbre
        // real la pone la precisión de los puntos sobre la base que los separa.
        let pointError = points.map { $0.fix.horizontalAccuracy }.max() ?? 0
        let sigma = max(hornSigma, atan(Float(pointError) * Float(2).squareRoot() / baseline))

        let utm = try converter.toUTM(latitude: first.fix.latitude, longitude: first.fix.longitude,
                                      height: first.fix.altitude)
        let frame = SiteFrame(
            siteID: UUID(), origin: utm, yawFromTrueNorth: yaw, yawSigma: sigma,
            meridianConvergence: Float(converter.meridianConvergence(
                latitude: first.fix.latitude, longitude: first.fix.longitude, zone: utm.zone)))

        // Primero llevar el punto 1 al origen, después rotar.
        var matrix = SiteFrameResolver.rotation(yaw: yaw)
        let moved = matrix.applyAffine(first.arPosition)
        matrix.columns.3 = SIMD4(-moved.x, -moved.y, -moved.z, 1)
        return (frame: frame, arWorldToSite: matrix)
    }
}

private func vecLength2D(_ v: SIMD2<Float>) -> Float {
    (v.x * v.x + v.y * v.y).squareRoot()
}
