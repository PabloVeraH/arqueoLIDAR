import CoreLocation
import Observation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Registro GPS durante la captura (plan §2.C.5): se guarda la serie completa de
// fijaciones, no una sola lectura. La coordenada del sitio sale después de la
// mediana ponderada (FixQualityGate) y la serie entera queda en geo.json.
// ═══════════════════════════════════════════════════════════════════════════════

@Observable
final class LocationRecorder: NSObject, CLLocationManagerDelegate {

    private(set) var fixes: [GeoFix] = []
    private(set) var denied = false

    private let manager = CLLocationManager()
    @ObservationIgnored private var recording = false

    var bestAccuracy: Double? { fixes.map(\.horizontalAccuracy).min() }

    /// Una línea para mostrar en pantalla durante la captura.
    var statusText: String {
        if denied { return "GPS: permiso denegado (Ajustes → Privacidad → Ubicación)" }
        guard let best = bestAccuracy else { return "GPS: buscando señal…" }
        return "GPS: \(fixes.count) lecturas · mejor ±\(best.formatted(.number.precision(.fractionLength(1)))) m"
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        fixes = []
        recording = true
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() {
        recording = false
        manager.stopUpdatingLocation()
    }

    // CLLocationManager entrega los eventos en el hilo donde se creó (el principal).

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let new = locations.compactMap { l -> GeoFix? in
            guard l.horizontalAccuracy >= 0 else { return nil }   // < 0 = lectura inválida
            // Altura elipsoidal (WGS84), la que espera UTMCoordinate.ellipsoidalHeight.
            return try? GeoFix(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                               altitude: l.ellipsoidalAltitude, horizontalAccuracy: l.horizontalAccuracy,
                               verticalAccuracy: max(l.verticalAccuracy, 0), timestamp: l.timestamp,
                               source: .coreLocation)
        }
        MainActor.assumeIsolated { fixes += new }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            denied = status == .denied || status == .restricted
            if recording, status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        }
    }
}
