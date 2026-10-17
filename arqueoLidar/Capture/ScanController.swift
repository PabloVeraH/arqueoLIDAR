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

    /// Objeto marcado con la mira: caja inicial para medir el volumen después.
    private(set) var objectMark: ObjectMark?

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
        objectMark = nil // las coordenadas del mundo anterior ya no valen
    }

    /// Reanuda tras una pausa SIN borrar la malla (p. ej. si se canceló Face ID
    /// al sellar): el escaneo sigue ahí y se puede volver a guardar.
    func resume() {
        guard !isRunning, let config = sceneView.session.configuration else { return start() }
        sceneView.session.run(config)
        isRunning = true
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

    /// Prueba de ruido del sensor (criterio de F3): toma los vértices de la
    /// malla cercanos al punto que marca la mira, ajusta un plano con RANSAC y
    /// reporta la desviación estándar de los residuos de los puntos que SÍ están
    /// en ese plano. Si una parte importante de los puntos queda fuera, la zona
    /// no es plana (esquina, objetos) y el número no representa ruido del sensor.
    func measureSurfaceNoise(radius: Float = 0.2) {
        guard let frame = sceneView.session.currentFrame, let target = crosshairTarget() else {
            noiseResult = "Apunta la mira a una pared o superficie plana y vuelve a intentar."
            return
        }
        let cam = frame.camera.transform.columns.3
        let distance = simd_distance(target, SIMD3<Float>(cam.x, cam.y, cam.z))

        var points: [SIMD3<Float>] = []
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            for p in MeshAnchorReader.worldVertices(of: anchor) where simd_distance(p, target) < radius {
                points.append(p)
            }
        }
        guard points.count >= 30 else {
            noiseResult = "Solo \(points.count) vértices cerca de la mira. Escanea más esa zona y vuelve a medir."
            return
        }
        do {
            let inlierDistance: Float = 0.015
            let options = PlaneFitOptions(maxIterations: 1000, inlierDistance: inlierDistance,
                                          minInliers: max(20, points.count / 3))
            let plane = try RANSACPlaneFitter().fit(points: points, normals: nil, options: options)
            let inliers = points.filter { abs(simd_dot($0 - plane.point, plane.normal)) <= inlierDistance }
            let residuals = inliers.map { Double(simd_dot($0 - plane.point, plane.normal)) }
            let mean = residuals.reduce(0, +) / Double(residuals.count)
            let sigma = (residuals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(residuals.count)).squareRoot()
            let fraction = Double(inliers.count) / Double(points.count)
            var text = String(format: "Superficie a %.2f m · σ = %.1f mm · %d de %d vértices en el plano (%.0f%%), radio %.0f cm",
                              distance, sigma * 1000, inliers.count, points.count, fraction * 100, radius * 100)
            if fraction < 0.7 {
                text += "\n⚠︎ La zona no es plana (esquina u objetos): apunta a una pared despejada para medir el ruido."
            }
            noiseResult = text
        } catch {
            noiseResult = "No se encontró un plano bajo la mira. Apunta a una pared despejada. (\(error))"
        }
    }

    /// Marca el objeto que está bajo la mira, con un radio aproximado.
    func markObject(radius: Float) {
        guard let target = crosshairTarget() else {
            noiseResult = "Apunta la mira al objeto (donde ya se ve la malla) y vuelve a marcar."
            return
        }
        objectMark = ObjectMark(center: target, radius: radius)
        noiseResult = nil
    }

    /// Punto 3D (mundo) bajo la mira, sobre la malla o un plano estimado.
    private func crosshairTarget() -> SIMD3<Float>? {
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        guard let query = sceneView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
              let hit = sceneView.session.raycast(query).first else { return nil }
        let t = hit.worldTransform.columns.3
        return SIMD3<Float>(t.x, t.y, t.z)
    }
}
