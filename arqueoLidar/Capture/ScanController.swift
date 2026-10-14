import ARKit
import Observation
import Domain
import Geometry
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// F3 — Sesión ARKit con la configuración fijada en el plan (§2.A):
// sceneReconstruction .meshWithClassification (o .mesh), frameSemantics
// [.sceneDepth, .smoothedSceneDepth] y worldAlignment .gravity (no heading).
// ═══════════════════════════════════════════════════════════════════════════════

@Observable
final class ScanController {

    let sceneView = ARSCNView(frame: .zero)
    private let wireframe = WireframeRenderer()

    let isSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    private(set) var isRunning = false

    // HUD de diagnóstico
    private(set) var anchorCount = 0
    private(set) var vertexCount = 0
    private(set) var trackingText = "—"
    private(set) var trackingIsNormal = false
    private(set) var thermalText = "—"
    private(set) var freeDiskText = "—"
    private(set) var reconstructionText = "—"

    // Prueba de ruido del sensor (criterio de aceptación de F3)
    private(set) var noiseResult: String?

    init() {
        sceneView.delegate = wireframe
        sceneView.automaticallyUpdatesLighting = false
        sceneView.rendersCameraGrain = false
    }

    func start() {
        guard isSupported, !isRunning else { return }
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            reconstructionText = "malla + clasificación"
        } else {
            config.sceneReconstruction = .mesh
            reconstructionText = "malla"
        }
        var semantics: ARConfiguration.FrameSemantics = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { semantics.insert(.sceneDepth) }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { semantics.insert(.smoothedSceneDepth) }
        config.frameSemantics = semantics
        config.worldAlignment = .gravity
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        noiseResult = nil
    }

    func pause() {
        guard isRunning else { return }
        sceneView.session.pause()
        isRunning = false
    }

    /// Reinicia la reconstrucción desde cero (descarta la malla acumulada).
    func restart() {
        pause()
        start()
    }

    /// Actualiza los contadores del HUD. Se llama periódicamente desde la vista.
    func refresh() {
        let thermal = ProcessInfo.processInfo.thermalState
        switch thermal {
        case .nominal: thermalText = "normal"
        case .fair: thermalText = "tibia"
        case .serious: thermalText = "ALTA"
        case .critical: thermalText = "CRÍTICA"
        @unknown default: thermalText = "?"
        }
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let free = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            freeDiskText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        }

        guard let frame = sceneView.session.currentFrame else { return }
        let meshes = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        anchorCount = meshes.count
        vertexCount = meshes.reduce(0) { $0 + $1.geometry.vertices.count }

        switch frame.camera.trackingState {
        case .normal:
            trackingText = "normal"; trackingIsNormal = true
        case .notAvailable:
            trackingText = "no disponible"; trackingIsNormal = false
        case .limited(let reason):
            trackingIsNormal = false
            switch reason {
            case .initializing: trackingText = "iniciando…"
            case .excessiveMotion: trackingText = "muévete más lento"
            case .insufficientFeatures: trackingText = "poca textura/luz"
            case .relocalizing: trackingText = "relocalizando"
            @unknown default: trackingText = "limitado"
            }
        }
    }

    /// Piezas de malla de todos los ARMeshAnchor actuales, para fusionarlas y guardarlas.
    func collectParts() -> [MeshPart] {
        guard let frame = sceneView.session.currentFrame else { return [] }
        return frame.anchors.compactMap { $0 as? ARMeshAnchor }.map(MeshAnchorReader.part(from:))
    }

    /// Prueba de ruido del sensor: ajusta un plano a los vértices de la malla
    /// cercanos al punto que marca la mira y reporta la desviación estándar de
    /// los residuos. Se registra el número; no se compara contra ninguna expectativa.
    func measureSurfaceNoise(radius: Float = 0.3) {
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        guard let frame = sceneView.session.currentFrame,
              let query = sceneView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
              let hit = sceneView.session.raycast(query).first else {
            noiseResult = "Apunta la mira a una pared o superficie plana y vuelve a intentar."
            return
        }
        let target = SIMD3<Float>(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        let cam = frame.camera.transform.columns.3
        let distance = simd_distance(target, SIMD3<Float>(cam.x, cam.y, cam.z))

        var points: [SIMD3<Float>] = []
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            for p in MeshAnchorReader.worldVertices(of: anchor) where simd_distance(p, target) < radius {
                points.append(p)
            }
        }
        guard points.count >= 20 else {
            noiseResult = "Solo \(points.count) vértices cerca de la mira. Escanea más esa zona y vuelve a medir."
            return
        }
        do {
            let plane = try LeastSquaresPlaneFitter().fit(points: points, normals: nil, options: PlaneFitOptions())
            let residuals = points.map { Double(simd_dot($0 - plane.point, plane.normal)) }
            let mean = residuals.reduce(0, +) / Double(residuals.count)
            let variance = residuals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(residuals.count)
            noiseResult = String(format: "Superficie a %.2f m · σ = %.1f mm · %d vértices en %.0f cm de radio",
                                 distance, variance.squareRoot() * 1000, points.count, radius * 100)
        } catch {
            noiseResult = "No se pudo ajustar el plano: \(error)"
        }
    }
}
