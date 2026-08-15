import Foundation
import Domain
import Mesh
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — PLYWriter. Formato PLY binario little-endian.
// Byte-determinista: misma entrada ⇒ mismos bytes.
// Contiene vértices (x,y,z) y caras indexadas.
//
// El formato en sí (codificación de bytes) vive en Mesh/PLYCodec — única
// fuente de verdad, compartida con Persistence/FindingStore.loadMesh — para
// que escribir y leer el mismo PLY no dependan de dos implementaciones que
// puedan divergir. Este writer solo agrega el sidecar record.json.
// ═══════════════════════════════════════════════════════════════════════════════

public struct PLYWriter {

    public init() {}

    public func write(
        mesh: Mesh,
        metadata: ExportMetadata,
        to url: URL
    ) throws(ExportError) -> ExportSidecar {

        guard !mesh.isEmpty else { throw .writeFailed("Malla vacía") }

        let data = PLYCodec.encode(mesh)
        try ExportWrite.data(data, to: url)

        let sidecarURL = url.deletingPathExtension().appendingPathExtension("record.json")
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "ply")
        
        try ExportWrite.sidecar(sidecar, to: sidecarURL)

        return ExportSidecar(fileURL: url, recordURL: sidecarURL)
    }
}