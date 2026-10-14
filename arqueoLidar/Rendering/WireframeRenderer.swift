import ARKit
import SceneKit
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════════
// F3 — Rendering mínimo: wireframe de la reconstrucción LiDAR sobre la cámara.
// Rendering/ es el único lugar que importa SceneKit (plan §2.A).
// ═══════════════════════════════════════════════════════════════════════════════

/// Delegado de ARSCNView: crea y actualiza un nodo wireframe por cada ARMeshAnchor.
/// Corre en el hilo de render de SceneKit, por eso es `nonisolated`.
nonisolated final class WireframeRenderer: NSObject, ARSCNViewDelegate {

    func renderer(_ renderer: any SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
        return SCNNode(geometry: Self.geometry(from: meshAnchor.geometry))
    }

    func renderer(_ renderer: any SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        node.geometry = Self.geometry(from: meshAnchor.geometry)
    }

    static func geometry(from mesh: ARMeshGeometry) -> SCNGeometry {
        let v = mesh.vertices
        // Se copian los buffers: ARKit los reutiliza entre actualizaciones.
        let vertexData = Data(bytes: v.buffer.contents().advanced(by: v.offset), count: v.stride * v.count)
        let source = SCNGeometrySource(
            data: vertexData, semantic: .vertex, vectorCount: v.count,
            usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: v.stride)

        let f = mesh.faces
        let faceData = Data(bytes: f.buffer.contents(), count: f.count * f.indexCountPerPrimitive * f.bytesPerIndex)
        let element = SCNGeometryElement(data: faceData, primitiveType: .triangles,
                                         primitiveCount: f.count, bytesPerIndex: f.bytesPerIndex)

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.fillMode = .lines
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.85)
        geometry.materials = [material]
        return geometry
    }
}

/// Envuelve el ARSCNView del controlador para usarlo en SwiftUI.
struct ARViewContainer: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
