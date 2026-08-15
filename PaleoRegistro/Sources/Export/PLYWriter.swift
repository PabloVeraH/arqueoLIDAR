import Foundation
import Domain
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — PLYWriter. Formato PLY binario little-endian.
// Byte-determinista: misma entrada ⇒ mismos bytes.
// Contiene vértices (x,y,z) y caras indexadas.
// ═══════════════════════════════════════════════════════════════════════════════

public struct PLYWriter {

    public init() {}

    public func write(
        mesh: Mesh,
        metadata: ExportMetadata,
        to url: URL
    ) throws(ExportError) -> ExportSidecar {

        guard !mesh.isEmpty else { throw .writeFailed("Malla vacía") }

        var data = Data()

        // Cabecera ASCII
        let header = """
        ply
        format binary_little_endian 1.0
        comment PaleoRegistro PLY export
        element vertex \(mesh.vertices.count)
        property float x
        property float y
        property float z
        element face \(mesh.triangleCount)
        property list uchar int vertex_indices
        end_header\n
        """
        data.append(header.data(using: .ascii)!)

        // Vértices: x, y, z como Float32 LE
        for v in mesh.vertices {
            var x = v.x.bitPattern; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
            var y = v.y.bitPattern; withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            var z = v.z.bitPattern; withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
        }

        // Caras: 3 (uchar) + 3 índices (int32 LE)
        var three: UInt8 = 3
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            data.append(&three, count: 1)
            var a = mesh.indices[i];   withUnsafeBytes(of: &a) { data.append(contentsOf: $0) }
            var b = mesh.indices[i+1]; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
            var c = mesh.indices[i+2]; withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        }

        try ExportWrite.data(data, to: url)

        let sidecarURL = url.deletingPathExtension().appendingPathExtension("record.json")
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "ply")
        
        try ExportWrite.sidecar(sidecar, to: sidecarURL)

        return ExportSidecar(fileURL: url, recordURL: sidecarURL)
    }
}