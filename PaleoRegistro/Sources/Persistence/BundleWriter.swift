import Foundation
import Domain
import Mesh

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
    // En plataformas Apple FileManager no es Sendable, así que no se guarda como
    // propiedad: se usa siempre FileManager.default (thread-safe para estas operaciones).
    private var fileManager: FileManager { .default }
    private let baseURL: URL
    private let jsonEncoder: CanonicalJSONEncoder

    public init(baseURL: URL) {
        self.baseURL = baseURL.appendingPathComponent("Findings", isDirectory: true)
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

    /// Escribe la malla en un scan como `mesh.ply` (vía `Mesh/PLYCodec`, la
    /// misma codificación que usa `Export/PLYWriter` para el export público —
    /// una sola fuente de verdad para el formato, para que
    /// `FindingStore.loadMesh` pueda leer exactamente lo que aquí se escribe).
    public func writeMesh(_ mesh: Mesh, to scanDir: URL) throws(StoreError) {
        try ensureDirectory(scanDir)
        let path = scanDir.appendingPathComponent("mesh.ply")
        try atomicWrite(data: PLYCodec.encode(mesh), to: path)
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

    /// `seals/SHA256SUMS` en el formato de `shasum -a 256 -c`: un perito puede
    /// revisar los archivos sin instalar nada. Va dentro de `seals/`, que no
    /// entra al manifiesto, así que reescribirlo no altera ningún sello.
    public func writeChecksums(_ manifest: [FileDigest], to findingDir: URL) throws(StoreError) {
        let text = manifest.map { "\($0.sha256)  \($0.relativePath)\n" }.joined()
        try atomicWrite(data: Data(text.utf8), to: findingDir.appendingPathComponent("seals/SHA256SUMS"))
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
        - No se ha modificado ningún archivo después del sellado.
        - El orden de los sellos: desde el formato v2, cada firma cubre su
          número y el hash del sello anterior; borrar o intercalar un sello
          rompe la firma. Desde el formato v3, la firma cubre el sello entero,
          incluida la ubicación GPS y la hora que entregó el GPS ("gnssTime"),
          un segundo reloj que no depende del reloj del teléfono.
        - Si el sello dice keyProtection = "secureEnclave": la clave vive en el
          chip seguro de un iPhone, no se puede copiar, y sellar exigió Face ID
          o el código de ese iPhone.
        - Si dice "software": la clave no está en el chip seguro. Prueba
          integridad, pero prueba menos sobre qué dispositivo selló.
        - Un cambio de clave (teléfono nuevo) queda declarado en previousKeyID.

        QUÉ NO PRUEBA
        -------------
        - Fecha absoluta confiable (el reloj del dispositivo es manipulable).
        - Ausencia de manipulación física de la escena antes de la captura.
        - Autoría profesional certificada por una autoridad externa.
        - Quién sostenía el iPhone: Face ID o el código prueban que se
          desbloqueó, no la identidad del operador declarado.

        CÓMO VERIFICAR
        --------------
        Hay dos niveles. Ambos se hacen sin la app, en un computador.

        A. Revisión rápida (Mac o Linux, sin instalar nada)
           Comprueba que ningún archivo sellado cambió ni falta.
           1. Abra una terminal en esta carpeta (la que contiene VERIFY.txt).
           2. Ejecute:   shasum -a 256 -c seals/SHA256SUMS
           3. Cada línea debe terminar en "OK". Un "FAILED" indica un archivo
              modificado; "No such file" indica uno que falta.
           Esta revisión NO detecta archivos agregados ni comprueba las firmas
           ni el orden de los sellos: para eso está el nivel B.

        B. Verificación completa (firmas, cadena y archivos agregados)
           Requiere Python 3 (incluido en macOS; en Windows, python.org).
           1. Abra una terminal en esta carpeta.
           2. Instale la librería de firmas, una sola vez:
                 pip3 install cryptography
           3. Ejecute:   python3 seals/verify_chain.py .
           4. Debe terminar en "VERIFICACIÓN: OK". Si dice "FALLO", lista qué
              archivo o qué sello no corresponde.
           Para un peritaje: seals/verify_chain.py viaja dentro del expediente,
           así que quien lo entregó pudo cambiarlo. Use de preferencia una copia
           del verificador obtenida por otro medio (por ejemplo, del equipo que
           desarrolló la app) y compare ambas con:
                 shasum -a 256 seals/verify_chain.py

        QUÉ HAY EN LA CARPETA seals/
        ----------------------------
        - chain.jsonl: un sello por línea, del primero al último. Cada uno
          trae la lista de archivos con su huella SHA-256 ("manifest"), la
          fecha, el autor, la clave pública y la firma.
        - SHA256SUMS: la lista de huellas del último sello, para el nivel A.
        - verify_chain.py: copia del verificador, para el nivel B.

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