import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F9 — BundleWriter. Layout de bundle en disco, escritura atómica.
//
// Layout:
//   Documents/Findings/FND-{fecha}-{hash}/
//     finding.json
//     seals/chain.jsonl
//     scans/{scanID}/
//       mesh.ply
//       depth/cloud.bin
//       scan.json
//       measurements.json
//       specimens/{id}.ply
//       media/{id}.heic + {id}.json
//       .sealed
// ═══════════════════════════════════════════════════════════════════════════════

public struct BundleWriter: Sendable {
    private let fileManager: FileManager
    private let baseURL: URL
    private let jsonEncoder: CanonicalJSONEncoder

    public init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL.appendingPathComponent("Findings", isDirectory: true)
        self.fileManager = fileManager
        self.jsonEncoder = CanonicalJSONEncoder()
    }

    // MARK: - Finding directory

    /// Crea el directorio para un Finding y escribe `finding.json`.
    public func createFinding(_ finding: Finding) throws(StoreError) -> URL {
        let dir = findingURL(finding.findingID)
        try ensureDirectory(dir)

        let manifestPath = dir.appendingPathComponent("finding.json")
        try atomicWrite(json: finding, to: manifestPath)

        // Crear subdirectorios
        try ensureDirectory(dir.appendingPathComponent("scans"))
        try ensureDirectory(dir.appendingPathComponent("seals"))
        try ensureDirectory(dir.appendingPathComponent("exports"))

        return dir
    }

    /// Crea directorio de scan dentro de un finding.
    public func createScanDir(_ scan: ScanSession, findingID: UUID) throws(StoreError) -> URL {
        let findDir = findingURL(findingID)
        guard fileManager.fileExists(atPath: findDir.path) else {
            throw .findingNotFound(findingID)
        }

        let scanDir = findDir.appendingPathComponent("scans/\(scan.scanID.uuidString)")
        try ensureDirectory(scanDir)
        try ensureDirectory(scanDir.appendingPathComponent("specimens"))
        try ensureDirectory(scanDir.appendingPathComponent("media"))
        try ensureDirectory(scanDir.appendingPathComponent("depth"))

        let scanJSON = scanDir.appendingPathComponent("scan.json")
        try atomicWrite(json: scan, to: scanJSON)

        return scanDir
    }

    /// Escribe la malla en un scan. El PLY real lo produce `Export/PLYWriter`
    /// (F12); Persistence no puede depender de Export (dependencia inversa),
    /// así que la app inyecta el escritor concreto en la fase de integración.
    public func writeMesh(_ mesh: Mesh, to scanDir: URL) throws(StoreError) {
        // Placeholder: la app escribe mesh.ply vía Export/PLYWriter y lo coloca
        // en scanDir. Aquí solo garantizamos que el directorio exista.
        try ensureDirectory(scanDir)
    }

    /// Escribe measurements.json en un scan.
    public func writeMeasurements(_ measurements: [Domain.Measurement], to scanDir: URL) throws(StoreError) {
        let path = scanDir.appendingPathComponent("measurements.json")
        try atomicWrite(json: measurements, to: path)
    }

    /// Escribe un espécimen .ply en el scan (placeholder; idem writeMesh).
    public func writeSpecimenMesh(_ mesh: Mesh, specimenID: UUID, to scanDir: URL) throws(StoreError) {
        let dir = scanDir.appendingPathComponent("specimens")
        try ensureDirectory(dir)
    }

    /// Escribe metadatos de media asset.
    public func writeMediaMetadata(_ asset: MediaAsset, to scanDir: URL) throws(StoreError) {
        let path = scanDir.appendingPathComponent("media/\(asset.assetID.uuidString).json")
        try atomicWrite(json: asset, to: path)
    }

    // MARK: - Seals

    public func appendSeal(_ seal: SealRecord, to findingDir: URL) throws(StoreError) {
        let sealsDir = findingDir.appendingPathComponent("seals")
        let chainPath = sealsDir.appendingPathComponent("chain.jsonl")

        guard let data = try? jsonEncoder.encode(seal) else {
            throw .writeFailed("No se pudo codificar el sello")
        }

        if fileManager.fileExists(atPath: chainPath.path) {
            guard let handle = try? FileHandle(forWritingTo: chainPath) else {
                throw .writeFailed("No se pudo abrir chain.jsonl para append")
            }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write("\n".data(using: .utf8)!)
            do {
                try handle.close()
            } catch {
                throw .writeFailed("No se pudo cerrar chain.jsonl: \(error)")
            }
        } else {
            let content = data + "\n".data(using: .utf8)!
            try atomicWrite(data: content, to: chainPath)
        }
    }

    // MARK: - Sealed marker

    /// Marca un directorio de scan como sellado (WORM a nivel de app).
    public func markSealed(scanDir: URL) throws(StoreError) {
        let sealPath = scanDir.appendingPathComponent(".sealed")
        guard !fileManager.fileExists(atPath: sealPath.path) else {
            throw .sealedImmutable
        }
        let content = "\(Date().timeIntervalSince1970)\n"
        try atomicWrite(data: content.data(using: .utf8)!, to: sealPath)
    }

    public func isSealed(scanDir: URL) -> Bool {
        fileManager.fileExists(atPath: scanDir.appendingPathComponent(".sealed").path)
    }

    // MARK: - VERIFY.txt

    public func writeVerifyDoc(to findingDir: URL, author: AuthorIdentity, rootHash: String) throws(StoreError) {
        let path = findingDir.appendingPathComponent("VERIFY.txt")
        let text = VerifyTemplate.render(author: author, rootHash: rootHash, findingDir: findingDir)
        try atomicWrite(data: text.data(using: .utf8)!, to: path)
    }

    // MARK: - Helpers

    public func findingURL(_ id: UUID) -> URL {
        baseURL.appendingPathComponent("FND-\(id.uuidString.prefix(8))", isDirectory: true)
    }

    /// Escritura atómica: escribe a temporal, luego rename (mismo volumen).
    private func atomicWrite(data: Data, to url: URL) throws(StoreError) {
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)

        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(6))")
        do {
            try data.write(to: temp, options: .atomic)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: temp, to: url)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw .writeFailed(error.localizedDescription)
        }
    }

    private func atomicWrite<T: Encodable>(json value: T, to url: URL) throws(StoreError) {
        let data: Data
        do {
            data = try jsonEncoder.encode(value)
        } catch {
            throw .writeFailed("JSON encoding: \(error)")
        }
        try atomicWrite(data: data, to: url)
    }

    private func ensureDirectory(_ url: URL) throws(StoreError) {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - VERIFY.txt template

private enum VerifyTemplate {
    static func render(author: AuthorIdentity, rootHash: String, findingDir: URL) -> String {
        """
        VERIFICACIÓN DE INTEGRIDAD — PaleoRegistro
        ==========================================

        Este documento explica cómo verificar la integridad del expediente sin
        necesidad de la app PaleoRegistro.

        QUÉ PRUEBA LA FIRMA
        --------------------
        - Integridad de los archivos desde el momento del sellado.
        - Origen en un dispositivo iPhone con biometría del operador presente.
        - No se ha modificado ningún archivo después del sellado.

        QUÉ NO PRUEBA
        -------------
        - Fecha absoluta confiable (el reloj del dispositivo es manipulable).
        - Ausencia de manipulación física de la escena antes de la captura.
        - Autoría profesional certificada por una autoridad externa.

        CÓMO VERIFICAR
        --------------
        1. Abrir una terminal en este directorio.
        2. Ejecutar:  shasum -a 256 scans/*/mesh.ply
        3. Comparar cada hash con el manifiesto en seals/chain.jsonl.
        4. Verificar que los hashes encadenados (prevSealHash) son consistentes.

        HASH RAÍZ DEL EXPEDIENTE
        ------------------------
        \(rootHash)

        OPERADOR
        --------
        Nombre: \(author.name)
        Rol: \(author.role)
        Institución: \(author.institution)
        Permiso CMN: \(author.cmnPermitNumber ?? "No declarado")

        APLICACIÓN
        ----------
        PaleoRegistro — Registro LiDAR paleontológico/arqueológico
        Ley 17.288 (CMN / MNHN, Chile)
        """
    }
}