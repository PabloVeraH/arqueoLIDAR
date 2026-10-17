import SwiftUI
import SceneKit
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// Visor 3D offline de un escaneo guardado (sin cámara): girar con un dedo,
// acercar con dos, tocar para marcar un punto. Encima se dibujan la caja de
// medición, el plano de referencia y un campo de color con su leyenda.
// Rendering/ es el único lugar que importa SceneKit (plan §2.A).
// ═══════════════════════════════════════════════════════════════════════════════

/// Campo de color por vértice (altura, distancia a la referencia…).
struct ScalarColoring {
    /// Cambia cuando cambia lo que se pinta (para volver a pintar).
    let id: String
    let title: String
    /// Factor y unidad para la leyenda (ej. 100 y "cm").
    let scale: Float
    let unit: String
    /// La leyenda muestra la escala desde 0 (alturas relativas al punto más bajo).
    let relative: Bool
    let value: (SIMD3<Float>) -> Float
}

struct MeshViewer: View {
    let mesh: Mesh
    /// Caja de medición (alineada con la gravedad), dibujada translúcida.
    var region: OrientedBox?
    /// Plano de referencia (suelo o superficie intacta), dibujado dentro de la caja.
    var plane: Plane?
    var coloring: ScalarColoring?
    /// Punto 3D tocado sobre la malla.
    var onPick: ((SIMD3<Float>) -> Void)?

    // La escena se arma una sola vez: el padre se redibuja con cada deslizador.
    @State private var scene: SCNScene?
    @State private var shown: Mesh?
    @State private var simplified = false
    @State private var range: ScalarRange?

    init(mesh: Mesh, region: OrientedBox? = nil, plane: Plane? = nil,
         coloring: ScalarColoring? = nil, onPick: ((SIMD3<Float>) -> Void)? = nil) {
        self.mesh = mesh
        self.region = region
        self.plane = plane
        self.coloring = coloring
        self.onPick = onPick
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let scene, let shown {
                SceneContainer(scene: scene, onPick: onPick)
                    .onChange(of: region) { Self.showOverlays(region: region, plane: plane, in: scene) }
                    .onChange(of: plane) { Self.showOverlays(region: region, plane: plane, in: scene) }
                    .onChange(of: coloring?.id) { range = Self.paint(shown, coloring: coloring, in: scene) }
                VStack(spacing: 4) {
                    if simplified {
                        Text("Versión simplificada para ver (\(shown.triangleCount.formatted()) de \(mesh.triangleCount.formatted()) triángulos). Las mediciones usan la malla completa.")
                    }
                    if let coloring, let range { legend(coloring, range) }
                }
                .font(.caption2)
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(6)
            } else {
                ProgressView("Preparando modelo…")
                    .task { await prepare() }
            }
        }
    }

    private func prepare() async {
        let mesh = mesh
        let (display, wasSimplified) = await Task.detached { MeshOps().decimateForDisplay(mesh) }.value
        let made = Self.makeScene(display)
        Self.showOverlays(region: region, plane: plane, in: made)
        range = Self.paint(display, coloring: coloring, in: made)
        simplified = wasSimplified
        shown = display
        scene = made
    }

    private func legend(_ coloring: ScalarColoring, _ range: ScalarRange) -> some View {
        let lo = coloring.relative ? 0 : range.low * coloring.scale
        let hi = (coloring.relative ? range.high - range.low : range.high) * coloring.scale
        func text(_ v: Float) -> String { "\(v.formatted(.number.precision(.fractionLength(v.magnitude < 10 ? 1 : 0)))) \(coloring.unit)" }
        return VStack(spacing: 2) {
            Text(coloring.title).fontWeight(.semibold)
            HStack {
                Text(text(lo))
                LinearGradient(colors: Self.ramp.map { Color(uiColor: $0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8)
                    .clipShape(Capsule())
                Text(text(hi))
            }
            if range.clippedFraction > 0 {
                Text("\((range.clippedFraction * 100).formatted(.number.precision(.fractionLength(1)))) % de los puntos queda fuera de la escala y se pinta con el color del extremo.")
            }
        }
    }

    // MARK: - Escena

    /// Azul (bajo) → verde → amarillo → rojo (alto).
    static let ramp: [UIColor] = [.systemBlue, .systemGreen, .systemYellow, .systemRed]

    /// Malla de dominio → escena SceneKit con la cámara encuadrada sobre ella.
    static func makeScene(_ mesh: Mesh) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.systemGray6
        let node = SCNNode(geometry: geometry(mesh, colors: nil))
        node.name = "mesh"
        scene.rootNode.addChildNode(node)

        let (minB, maxB) = node.boundingBox
        let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        let size = max(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z, 0.1)
        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(center.x, center.y + size * 0.6, center.z + size * 1.4)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        return scene
    }

    private static func geometry(_ mesh: Mesh, colors: [SIMD4<Float>]?) -> SCNGeometry {
        var sources = [SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })]
        if let normals = mesh.normals, normals.count == mesh.vertices.count {
            sources.append(SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }))
        }
        if let colors {
            let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count,
                                             usesFloatComponents: true, componentsPerVector: 4,
                                             bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                             dataStride: MemoryLayout<SIMD4<Float>>.stride))
        }
        let geometry = SCNGeometry(sources: sources,
                                   elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        // Con colores por vértice, el difuso blanco deja verlos tal cual.
        material.diffuse.contents = colors == nil ? UIColor(red: 0.80, green: 0.66, blue: 0.48, alpha: 1) : UIColor.white
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    /// Pinta la malla con el campo (o la deja en su color si no hay) y devuelve la escala usada.
    private static func paint(_ mesh: Mesh, coloring: ScalarColoring?, in scene: SCNScene) -> ScalarRange? {
        guard let node = scene.rootNode.childNode(withName: "mesh", recursively: false) else { return nil }
        guard let coloring else {
            node.geometry = geometry(mesh, colors: nil)
            return nil
        }
        let values = mesh.vertices.map(coloring.value)
        let range = ScalarRange.robust(values)
        node.geometry = geometry(mesh, colors: values.map { color(at: range.normalized($0)) })
        return range
    }

    private static func color(at t: Float) -> SIMD4<Float> {
        let stops = ramp.map { c -> SIMD4<Float> in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD4(Float(r), Float(g), Float(b), 1)
        }
        let x = t * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let f = x - Float(i)
        return stops[i] + (stops[i + 1] - stops[i]) * f
    }

    private static func showOverlays(region: OrientedBox?, plane: Plane?, in scene: SCNScene) {
        for name in ["region", "plane"] {
            scene.rootNode.childNode(withName: name, recursively: false)?.removeFromParentNode()
        }
        guard let region else { return }
        let d = region.dimensions
        let box = SCNBox(width: CGFloat(d.x), height: CGFloat(d.y), length: CGFloat(d.z), chamferRadius: 0)
        box.materials = [translucent(.systemOrange)]
        let boxNode = SCNNode(geometry: box)
        boxNode.name = "region"
        boxNode.simdPosition = region.center
        scene.rootNode.addChildNode(boxNode)

        guard let plane else { return }
        // Cuadrado del plano bajo el centro de la caja, del tamaño de la caja.
        let side = CGFloat(max(d.x, d.z))
        let quad = SCNPlane(width: side, height: side)
        quad.materials = [translucent(.systemGreen)]
        let planeNode = SCNNode(geometry: quad)
        planeNode.name = "plane"
        let n = simd_normalize(plane.normal)
        planeNode.simdPosition = region.center - simd_dot(region.center - plane.point, n) * n
        planeNode.simdOrientation = simd_quatf(from: SIMD3(0, 0, 1), to: n)
        scene.rootNode.addChildNode(planeNode)
    }

    private static func translucent(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color.withAlphaComponent(0.25)
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }
}

/// SCNView con cámara libre y toque para marcar un punto de la malla.
private struct SceneContainer: UIViewRepresentable {
    let scene: SCNScene
    let onPick: ((SIMD3<Float>) -> Void)?

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .systemGray6
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                         action: #selector(Coordinator.tapped(_:))))
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onPick = onPick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject {
        var onPick: ((SIMD3<Float>) -> Void)?
        init(onPick: ((SIMD3<Float>) -> Void)?) { self.onPick = onPick }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let onPick, let view = gesture.view as? SCNView else { return }
            let hits = view.hitTest(gesture.location(in: view), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            // Solo la malla: la caja y el plano translúcidos no cuentan.
            if let hit = hits.first(where: { $0.node.name == "mesh" }) {
                onPick(hit.simdWorldCoordinates)
            }
        }
    }
}
