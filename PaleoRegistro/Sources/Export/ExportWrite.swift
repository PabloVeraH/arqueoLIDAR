import Foundation
import Domain
import Persistence

/// Helper interno: escribe `Data` a disco y convierte errores de Foundation
/// a `ExportError` para los writers con `throws(ExportError)`.
enum ExportWrite {
    static func data(_ d: Data, to url: URL) throws(ExportError) {
        do {
            try d.write(to: url)
        } catch {
            throw .writeFailed("\(error)")
        }
    }

    /// Codifica y escribe el sidecar `record.json` (JSON canónico).
    static func sidecar(_ sidecar: RecordSidecar, to url: URL) throws(ExportError) {
        let sidecarData: Data
        do {
            sidecarData = try CanonicalJSONEncoder().encode(sidecar)
        } catch {
            throw .writeFailed("JSON canónico del sidecar: \(error)")
        }
        try data(sidecarData, to: url)
    }
}