import SwiftUI
import SceneKit
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Visor 3D offline de un escaneo guardado (sin cámara): girar con un dedo,
// acercar con dos. Rendering/ es el único lugar que importa SceneKit (plan §2.A).
// ═══════════════════════════════════════════════════════════════════════════════

struct MeshViewer: View {
    let mesh: Mesh
    /// Caja de medición (alineada con la gravedad), dibujada translúcida.
    var region: OrientedBox?
    // La escena se arma una sola vez: el padre se redibuja con cada deslizador.
    @State private var scene: SCNScene?

    init(mesh: Mesh, region: OrientedBox? = nil) {
        self.mesh = mesh
        self.region = region
    }

    var body: some View {
        if let scene {
            SceneView(scene: scene, pointOfView: scene.rootNode.childNode(withName: "camera", recursively: false),
                      options: [.allowsCameraControl, .autoenablesDefaultLighting])
                .onChange(of: region) { Self.show(region, in: scene) }
        } else {
            Color.clear.onAppear {
                let made = Self.makeScene(mesh)
                Self.show(region, in: made)
                scene = made
            }
        }
    }

    private static func show(_ region: OrientedBox?, in scene: SCNScene) {
        scene.rootNode.childNode(withName: "region", recursively: false)?.removeFromParentNode()
        guard let region else { return }
        let d = region.dimensions
        let box = SCNBox(width: CGFloat(d.x), height: CGFloat(d.y), length: CGFloat(d.z), chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemOrange.withAlphaComponent(0.25)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.name = "region"
        node.position = SCNVector3(region.center.x, region.center.y, region.center.z)
        scene.rootNode.addChildNode(node)
    }

    /// Malla de dominio → escena SceneKit con la cámara encuadrada sobre ella.
    static func makeScene(_ mesh: Mesh) -> SCNScene {
        var sources = [SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })]
        if let normals = mesh.normals {
            sources.append(SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }))
        }
        let geometry = SCNGeometry(sources: sources,
                                   elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.80, green: 0.66, blue: 0.48, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]

        let scene = SCNScene()
        scene.background.contents = UIColor.systemGray6
        let node = SCNNode(geometry: geometry)
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
}
