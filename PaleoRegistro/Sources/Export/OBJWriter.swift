import Foundation
import Domain
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — OBJWriter. Formato Wavefront OBJ + MTL opcional.
// ═══════════════════════════════════════════════════════════════════════════════

public struct OBJWriter {

    public init() {}

    public func write(
        mesh: Mesh,
        metadata: ExportMetadata,
        to url: URL
    ) throws(ExportError) -> ExportSidecar {

        guard !mesh.isEmpty else { throw .writeFailed("Malla vacía") }

        var lines: [String] = []

        lines.append("# PaleoRegistro OBJ export")
        lines.append("# vertices: \(mesh.vertices.count), faces: \(mesh.triangleCount)")
        lines.append("o PaleoRegistro_Mesh")

        // Vértices (en metros)
        for v in mesh.vertices {
            lines.append("v \(CanonicalFormat.floatStr(v.x)) \(CanonicalFormat.floatStr(v.y)) \(CanonicalFormat.floatStr(v.z))")
        }

        // Normales
        if let normals = mesh.normals {
            for n in normals {
                lines.append("vn \(CanonicalFormat.floatStr(n.x)) \(CanonicalFormat.floatStr(n.y)) \(CanonicalFormat.floatStr(n.z))")
            }
        }

        // Caras (1-indexed)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = Int(mesh.indices[i]) + 1
            let b = Int(mesh.indices[i+1]) + 1
            let c = Int(mesh.indices[i+2]) + 1
            if mesh.normals != nil {
                lines.append("f \(a)//\(a) \(b)//\(b) \(c)//\(c)")
            } else {
                lines.append("f \(a) \(b) \(c)")
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try ExportWrite.data(content.data(using: .ascii)!, to: url)

        let sidecarURL = url.deletingPathExtension().appendingPathExtension("record.json")
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "obj")
        
        try ExportWrite.sidecar(sidecar, to: sidecarURL)

        return ExportSidecar(fileURL: url, recordURL: sidecarURL)
    }
}

/// Formato canónico de floats para serializadores ASCII.
/// Locale-independiente: usa `.description` (siempre `.` como separador decimal).
enum CanonicalFormat {
    static func floatStr(_ v: Float) -> String {
        if v == 0 { return "0.0" }
        return v.description
    }

    static func doubleStr(_ v: Double) -> String {
        if v == 0 { return "0.0" }
        return v.description
    }
}