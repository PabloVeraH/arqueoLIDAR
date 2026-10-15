import Foundation
import Domain
import Persistence
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// ═══════════════════════════════════════════════════════════════════════════════
// F10 — Hasher. SHA-256 en streaming por archivo.
// Pico de memoria acotado independientemente del tamaño del archivo.
// ═══════════════════════════════════════════════════════════════════════════════

public struct Hasher: Sendable {

    public init() {}

    /// Calcula SHA-256 de un archivo en streaming (no carga el archivo completo en memoria).
    public func hash(fileAt url: URL) throws(CustodyError) -> String {
        guard let stream = InputStream(url: url) else {
            throw .bundleNotFound
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576) // 1 MB chunks

        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                hasher.update(data: Data(buffer[0..<count]))
            } else if count < 0 {
                throw .verificationFailed("Error de lectura en \(url.lastPathComponent): \(stream.streamError?.localizedDescription ?? "desconocido")")
            } else {
                break
            }
        }

        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Calcula SHA-256 de Data en memoria.
    public func hash(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Construye un manifiesto ordenado estable a partir del contenido de un directorio.
    /// Itera en orden lexicográfico de ruta relativa para determinismo.
    /// Excluye `seals/` (chain.jsonl se verifica aparte por encadenamiento),
    /// `.sealed` y `VERIFY.txt` (generados tras el sellado, romperían el hash).
    public func buildManifest(directoryAt url: URL) throws(CustodyError) -> [FileDigest] {
        let fm = FileManager.default
        // Se enumera por ruta (`enumerator(atPath:)`), que entrega rutas ya
        // relativas a la raíz. Antes se derivaban con un reemplazo de texto
        // sobre `fileURL.path`, lo que fallaba cuando la raíz y los archivos
        // enumerados usaban formas distintas de la misma ruta (en iOS,
        // `/var/mobile/…` vs `/private/var/mobile/…`): el manifiesto quedaba
        // con rutas como "/privatefinding.json" y la verificación fallaba.
        guard let enumerator = fm.enumerator(atPath: url.path) else {
            throw .bundleNotFound
        }

        var digests: [FileDigest] = []

        while let relPath = enumerator.nextObject() as? String {
            // Excluir sellos y marcadores generados tras el sellado.
            if relPath == "seals" {
                enumerator.skipDescendants()
                continue
            }
            if relPath.hasPrefix("seals/") { continue }
            if relPath == ".sealed" || relPath == "VERIFY.txt" { continue }

            let fileURL = url.appendingPathComponent(relPath)
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }

            let fileSize = values.fileSize.map(Int64.init) ?? 0

            let sha = try hash(fileAt: fileURL)

            digests.append(FileDigest(relativePath: relPath, bytes: fileSize, sha256: sha))
        }

        // Orden estable por ruta relativa
        digests.sort { $0.relativePath < $1.relativePath }
        return digests
    }

    /// Hash raíz del manifiesto: SHA-256 del manifiesto codificado canónicamente.
    public func rootHash(manifest: [FileDigest], encoder: CanonicalJSONEncoder) throws(CustodyError) -> String {
        do {
            let data = try encoder.encode(manifest)
            return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        } catch {
            throw .verificationFailed("Error al codificar manifiesto: \(error)")
        }
    }
}