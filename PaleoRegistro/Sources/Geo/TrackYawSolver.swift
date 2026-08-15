import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F8 — TrackYawSolver. Resuelve el yaw del marco AR respecto al norte verdadero
// alineando la trayectoria de la cámara (proyectada al plano horizontal) contra
// la traza GPS mediante el algoritmo de Horn 2D (closed-form).
//
// El sesgo constante de posición no afecta el resultado porque Horn elimina
// la traslación. El heading magnético se guarda como control cruzado.
// ═══════════════════════════════════════════════════════════════════════════════

public struct TrackYawSolver: Sendable {
    public init() {}

    /// Resuelve el yaw alineando trayectoria AR (plano XZ → EN) contra traza GPS (lat/lon → EN local).
    ///
    /// - Parameters:
    ///   - cameraTrack: pares (timestamp, transform) de la cámara AR en marco ARKit (.gravity).
    ///                  La trayectoria se proyecta al plano XZ (horizontal ENU).
    ///   - fixes: fijaciones GPS correspondientes, ordenadas por timestamp.
    ///   - minTrackLength: longitud mínima acumulada de la trayectoria (m) para que el solver no se niegue.
    /// - Throws: `GeoError.degenerateTrack` si la trayectoria es demasiado corta o rectilínea.
    /// - Returns: yaw en radianes (rotación del eje +X AR hacia el Este verdadero), más sigma estimada.
    public func resolve(
        cameraTrack: [(time: Date, transform: Matrix4x4)],
        fixes: [GeoFix],
        minTrackLength: Float = 10.0
    ) throws(GeoError) -> (yaw: Float, sigma: Float) {

        guard cameraTrack.count >= 3 else {
            throw .degenerateTrack("trayectoria AR insuficiente (\(cameraTrack.count) puntos, mínimo 3)")
        }
        guard fixes.count >= 3 else {
            throw .degenerateTrack("traza GPS insuficiente (\(fixes.count) puntos, mínimo 3)")
        }

        // 1. Proyectar trayectoria AR al plano horizontal (XZ → EN).
        var arPoints: [SIMD2<Float>] = []
        arPoints.reserveCapacity(cameraTrack.count)
        var totalLength: Float = 0
        var prev: SIMD2<Float>?

        for frame in cameraTrack {
            let t = frame.transform.translation
            let p = SIMD2<Float>(t.x, -t.z) // +X → E, -Z → N
            if let prev = prev {
                totalLength += vecLength2(p - prev)
            }
            prev = p
            arPoints.append(p)
        }

        guard totalLength >= minTrackLength else {
            throw .degenerateTrack("trayectoria AR demasiado corta (\(totalLength.description) m < \(minTrackLength.description) m)")
        }

        // 2. Convertir fixes GPS a EN local (origen = primer fix).
        guard let origin = fixes.first else { throw .degenerateTrack("sin fijaciones GPS") }
        let cosLat0 = cos(Float(origin.latitude) * .pi / 180.0)
        let mPerDegLat: Float = 111_320.0
        let mPerDegLon: Float = mPerDegLat * cosLat0

        var gpsPoints: [SIMD2<Float>] = []
        gpsPoints.reserveCapacity(fixes.count)
        for fix in fixes {
            let dLat = Float(fix.latitude - origin.latitude) * mPerDegLat
            let dLon = Float(fix.longitude - origin.longitude) * mPerDegLon
            gpsPoints.append(SIMD2<Float>(dLon, dLat)) // EN: x=Este, y=Norte
        }

        // 3. Correspondencia por tiempo: para cada punto AR, interpolar GPS más cercano en tiempo.
        let gpsEpochs = fixes.map { $0.timestamp.timeIntervalSince1970 }
        var matchedGPS: [SIMD2<Float>?] = Array(repeating: nil, count: arPoints.count)

        for (i, frame) in cameraTrack.enumerated() {
            let t = frame.time.timeIntervalSince1970
            if t <= gpsEpochs.first! {
                matchedGPS[i] = gpsPoints[0]
            } else if t >= gpsEpochs.last! {
                matchedGPS[i] = gpsPoints.last!
            } else {
                // Búsqueda binaria del intervalo
                var lo = 0, hi = gpsEpochs.count - 1
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if gpsEpochs[mid] <= t { lo = mid } else { hi = mid }
                }
                let frac = Float((t - gpsEpochs[lo]) / (gpsEpochs[hi] - gpsEpochs[lo]))
                matchedGPS[i] = gpsPoints[lo] + (gpsPoints[hi] - gpsPoints[lo]) * frac
            }
        }

        // Filtrar puntos con correspondencia
        let pairs: [(SIMD2<Float>, SIMD2<Float>)] = zip(arPoints, matchedGPS).compactMap { ar, gps in
            gps.map { (ar, $0) }
        }
        guard pairs.count >= 3 else {
            throw .degenerateTrack("pocas correspondencias AR↔GPS (\(pairs.count))")
        }

        // 4. Horn 2D (closed-form): yaw = ángulo que minimiza Σ|R(θ)·p_AR − p_GPS|²
        // Solución: tan(θ) = (Σ cross) / (Σ dot) tras centrar ambas nubes.
        let arCentroid: SIMD2<Float> = pairs.reduce(.zero) { $0 + $1.0 } / Float(pairs.count)
        let gpsCentroid: SIMD2<Float> = pairs.reduce(.zero) { $0 + $1.1 } / Float(pairs.count)

        var sxx: Float = 0, sxy: Float = 0, syx: Float = 0, syy: Float = 0
        for (ar, gps) in pairs {
            let da = ar - arCentroid
            let dg = gps - gpsCentroid
            sxx += da.x * dg.x
            sxy += da.x * dg.y
            syx += da.y * dg.x
            syy += da.y * dg.y
        }

        let num = sxy - syx
        let den = sxx + syy

        guard abs(den) > 1e-10 else {
            throw .degenerateTrack("Horn 2D degenerado (denominador ≈ 0)")
        }

        let yaw = atan2(num, den)

        // 5. Estimar sigma del yaw: residual RMS / radio medio de la nube
        let cosY = cos(yaw), sinY = sin(yaw)
        var residSq: Float = 0
        for (ar, gps) in pairs {
            let da = ar - arCentroid
            let rotated = SIMD2<Float>(
                cosY * da.x - sinY * da.y,
                sinY * da.x + cosY * da.y
            )
            let d = rotated - (gps - gpsCentroid)
            residSq += d.x * d.x + d.y * d.y
        }
        let rmse = sqrt(residSq / Float(pairs.count))

        var meanRadius: Float = 0
        for (ar, _) in pairs {
            let da = ar - arCentroid
            meanRadius += sqrt(da.x * da.x + da.y * da.y)
        }
        meanRadius /= Float(pairs.count)

        let sigma = meanRadius > 1e-6 ? rmse / meanRadius : .infinity

        return (yaw: yaw, sigma: sigma)
    }
}

private func vecLength2(_ v: SIMD2<Float>) -> Float {
    (v.x * v.x + v.y * v.y).squareRoot()
}