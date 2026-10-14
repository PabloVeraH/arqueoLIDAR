import SwiftUI
import SceneKit
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Visor 3D offline de un escaneo guardado (sin cámara): girar con un dedo,
// acercar con dos. Rendering/ es el único lugar que importa SceneKit (plan §2.A).
// ═══════════════════════════════════════════════════════════════════════════════

struct MeshViewer: View {
    @State private var scene: SCNScene

    init(mesh: Mesh) {
        _scene = State(initialValue: Self.makeScene(mesh))
    }

    var body: some View {
        SceneView(scene: scene, pointOfView: scene.rootNode.childNode(withName: "camera", recursively: false),
                  options: [.allowsCameraControl, .autoenablesDefaultLighting])
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
