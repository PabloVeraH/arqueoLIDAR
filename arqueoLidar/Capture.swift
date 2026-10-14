import SwiftUI
import ARKit
import RealityKit
import CoreLocation
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// Captura en terreno: sesión ARKit con reconstrucción de malla LiDAR y registro
// continuo de fijaciones GPS mientras dura el escaneo.
// ═══════════════════════════════════════════════════════════════════════════════

/// Sesión ARKit con la configuración fijada en el plan (§2.A).
@Observable
final class LiDARCapture {

    static var isSupported: Bool { ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) }

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    func start() {
        let config = ARWorldTrackingConfiguration()
        // La clasificación (suelo/pared) se usa luego como prior para RANSAC.
        config.sceneReconstruction = ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
            ? .meshWithClassification : .mesh
        // `.gravity` y no `.gravityAndHeading`: la brújula falla 10-30° cerca de
        // maquinaria o roca con magnetita; el norte se resuelve con la traza GPS.
        config.worldAlignment = .gravity
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    /// Detiene la sesión y entrega cada trozo de malla con su pose en el mundo AR.
    func stop() -> [MeshPart] {
        let anchors = arView.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
        arView.session.pause()
        return anchors.map(Self.meshPart)
    }

    private static func meshPart(_ anchor: ARMeshAnchor) -> MeshPart {
        let geometry = anchor.geometry

        // Vértices: float3 empaquetado (12 bytes). Se lee componente a componente
        // porque SIMD3<Float> ocupa 16 bytes y leerlo directo desbordaría el buffer.
        let v = geometry.vertices
        let vBase = v.buffer.contents().advanced(by: v.offset)
        let vertices = (0..<v.count).map { i -> SIMD3<Float> in
            let p = vBase.advanced(by: i * v.stride).assumingMemoryBound(to: Float.self)
            return SIMD3(p[0], p[1], p[2])
        }

        let f = geometry.faces
        let count = f.count * f.indexCountPerPrimitive
        let fBase = f.buffer.contents()
        let indices: [UInt32] = f.bytesPerIndex == 2
            ? (0..<count).map { UInt32(fBase.load(fromByteOffset: $0 * 2, as: UInt16.self)) }
            : (0..<count).map { fBase.load(fromByteOffset: $0 * 4, as: UInt32.self) }

        let t = anchor.transform
        return MeshPart(transform: Matrix4x4(t.columns.0, t.columns.1, t.columns.2, t.columns.3),
                        localVertices: vertices, faceIndices: indices,
                        indexCountPerPrimitive: f.indexCountPerPrimitive)
    }
}

/// Vista de cámara en vivo con la malla LiDAR superpuesta.
struct ARPreview: UIViewRepresentable {
    let view: ARView
    func makeUIView(context: Context) -> ARView { view }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Registra la serie completa de fijaciones GPS (no una sola lectura): la
/// coordenada del sitio sale de la mediana ponderada y la serie se guarda entera.
@Observable
final class LocationRecorder: NSObject, CLLocationManagerDelegate {

    private(set) var fixes: [GeoFix] = []
    private(set) var denied = false

    private let manager = CLLocationManager()
    @ObservationIgnored private var recording = false

    var bestAccuracy: Double? { fixes.map(\.horizontalAccuracy).min() }

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
