import Foundation
import Domain
import Mesh
import Geo
import Custody
import Persistence
import Export
import Volume

// ═══════════════════════════════════════════════════════════════════════════════
// Puente entre la interfaz de terreno y el paquete PaleoRegistro: crea
// expedientes, guarda y sella escaneos, carga mallas y exporta archivos.
//
// Expedientes: Documents/Findings/FND-xxxxxxxx/ (visibles en Finder y en la app
// Archivos gracias a UIFileSharingEnabled).
// Exportaciones: Documents/Exports/FND-xxxxxxxx/<escaneo>/, FUERA del expediente:
// cualquier archivo nuevo dentro del bundle sellado haría que ChainVerifier lo
// reporte como "archivo añadido no declarado".
// ═══════════════════════════════════════════════════════════════════════════════

nonisolated struct FieldError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Resumen de un escaneo recién guardado y sellado (lo muestra SavedScanView).
nonisolated struct SavedScan: Sendable, Identifiable {
    let scanID: UUID
    let title: String
    let folder: URL
    let meshURL: URL
    let vertexCount: Int
    let triangleCount: Int
    let rootHash: String
    let keyProtection: KeyProtection
    var id: UUID { scanID }
}

nonisolated struct ScanEntry: Identifiable, Sendable {
    let scan: ScanSession
    let dir: URL
    let isSealed: Bool
    var id: UUID { scan.scanID }
}

nonisolated enum FieldStore {

    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let writer = BundleWriter(baseURL: documents)

    // MARK: - Sitios

    /// Documents/Sites/SIT-xxxxxxxx.json. Los sitios no se sellan: son la carpeta
    /// que agrupa hallazgos. Cada expediente lleva su propia copia (`site.json`).
    static let sitesDir = documents.appendingPathComponent("Sites")

    static func sites() -> [Site] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sitesDir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { load(Site.self, from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Crea o actualiza la ficha. Las copias `site.json` ya selladas dentro de cada
    /// expediente no cambian: registran el sitio tal como era al crear el hallazgo.
    static func saveSite(_ site: Site) throws {
        try FileManager.default.createDirectory(at: sitesDir, withIntermediateDirectories: true)
        try CanonicalJSONEncoder().encode(site).write(to: siteFile(site), options: .atomic)
    }

    /// Solo se borra un sitio vacío. La regla vive aquí para que ningún llamador la salte.
    static func deleteSite(_ site: Site) throws {
        let n = findings(in: site).count
        guard n == 0 else {
            throw FieldError("El sitio tiene \(n) hallazgo(s). Solo se pueden eliminar sitios sin hallazgos.")
        }
        try FileManager.default.removeItem(at: siteFile(site))
    }

    private static func siteFile(_ site: Site) -> URL {
        sitesDir.appendingPathComponent("SIT-\(site.siteID.uuidString.prefix(8)).json")
    }

    // MARK: - Hallazgos

    static func findings() -> [Finding] {
        let dir = documents.appendingPathComponent("Findings")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { load(Finding.self, from: $0.appendingPathComponent("finding.json")) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Hallazgos de un sitio; con `nil`, los que no pertenecen a ningún sitio
    /// registrado (los creados antes de que existieran los sitios).
    static func findings(in site: Site?) -> [Finding] {
        let all = findings()
        if let site { return all.filter { $0.siteID == site.siteID } }
        let known = Set(sites().map(\.siteID))
        return all.filter { !known.contains($0.siteID) }
    }

    /// Crea el expediente con una copia de la ficha del sitio dentro: queda en el
    /// manifiesto del primer sello, así el expediente compartido dice dónde se hizo.
    static func createFinding(_ finding: Finding, site: Site) throws {
        let dir = try writer.createFinding(finding)
        try CanonicalJSONEncoder().encode(site).write(to: dir.appendingPathComponent("site.json"), options: .atomic)
    }

    static func findingDir(_ finding: Finding) -> URL {
        writer.findingURL(finding.findingID)
    }

    // MARK: - Escaneos

    static func scans(of finding: Finding) -> [ScanEntry] {
        let dir = findingDir(finding).appendingPathComponent("scans")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            load(ScanSession.self, from: d.appendingPathComponent("scan.json"))
                .map { ScanEntry(scan: $0, dir: d, isSealed: writer.isSealed(scanDir: d)) }
        }
        .sorted { $0.scan.capturedAt < $1.scan.capturedAt }
    }

    /// Fusiona los trozos de malla de ARKit, guarda el escaneo con la serie GPS
    /// completa y sella el expediente (nuevo eslabón en seals/chain.jsonl).
    static func saveScan(parts: [MeshPart], fixes: [GeoFix], purpose: ScanPurpose,
                         mark: ObjectMark?, finding: Finding) async throws -> SavedScan {
        let merged = MeshMergerCore().merge(parts: parts)
        guard !merged.isEmpty else {
            throw FieldError("No hay malla para guardar. Recorre la zona con la cámara hasta ver el wireframe.")
        }
        // Face ID o código antes de escribir nada (ver SealingKeyStore).
        let key = try await SealingKeyStore.key(reason: "Sellar el escaneo de «\(finding.title)»")
        let mesh = Mesh(vertices: merged.vertices, indices: merged.indices,
                        normals: MeshOps().computeVertexNormals(merged).map(vecNormalize))

        let verdict = FixQualityGate().evaluate(burst: fixes)
        let scan = ScanSession(findingID: finding.findingID, purpose: purpose,
                               georeferenceQuality: verdict.quality, objectMark: mark)

        let scanDir = try writer.createScanDir(scan, findingID: finding.findingID)
        try writer.writeMesh(mesh, to: scanDir)
        // El plan (§2.C.5) pide persistir la serie entera, no solo la fijación elegida.
        try CanonicalJSONEncoder().encode(fixes)
            .write(to: scanDir.appendingPathComponent("geo.json"), options: .atomic)

        // `.sealed` se escribe ANTES de sellar para que quede dentro del manifiesto:
        // Hasher solo excluye el `.sealed` de la raíz del bundle, no el de cada
        // escaneo, y uno escrito después aparecería como archivo no declarado.
        try writer.markSealed(scanDir: scanDir)

        let dir = findingDir(finding)
        let seal = try await SealSigner().seal(bundleAt: dir, author: finding.author,
                                               geo: representativeFix(fixes), previousSeal: lastSeal(dir),
                                               key: key)
        try writer.appendSeal(seal, to: dir)
        try writer.writeVerifyDoc(to: dir, author: finding.author, rootHash: seal.rootHash)
        return SavedScan(scanID: scan.scanID, title: finding.title, folder: dir,
                         meshURL: scanDir.appendingPathComponent("mesh.ply"),
                         vertexCount: mesh.vertices.count, triangleCount: mesh.triangleCount,
                         rootHash: seal.rootHash, keyProtection: key.protection)
    }

    static func loadMesh(_ entry: ScanEntry) throws -> Mesh {
        try PLYCodec.decode(Data(contentsOf: entry.dir.appendingPathComponent("mesh.ply")))
    }

    static func fixes(_ entry: ScanEntry) -> [GeoFix] {
        load([GeoFix].self, from: entry.dir.appendingPathComponent("geo.json")) ?? []
    }

    /// Mediana ponderada de las fijaciones aceptadas; si el GPS fue malo, la más
    /// precisa disponible (el escaneo ya quedó marcado `.degraded`).
    static func representativeFix(_ fixes: [GeoFix]) -> GeoFix? {
        FixQualityGate().evaluate(burst: fixes).chosenFix
            ?? fixes.min { $0.horizontalAccuracy < $1.horizontalAccuracy }
    }

    // MARK: - Mediciones

    /// Mediciones de volumen guardadas para un escaneo (`measurements/` del expediente).
    static func measurements(of entry: ScanEntry, finding: Finding) -> [VolumeMeasurement] {
        let dir = findingDir(finding).appendingPathComponent("measurements")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { load(VolumeMeasurement.self, from: $0) }
            .filter { $0.scanID == entry.scan.scanID }
            .sorted { $0.measuredAt < $1.measuredAt }
    }

    /// Guarda la medición en `measurements/MSR-….json` (fuera del escaneo sellado,
    /// que no se toca) y la sella como un eslabón nuevo de la cadena.
    static func saveMeasurement(_ measurement: VolumeMeasurement, finding: Finding) async throws {
        // Face ID o código antes de escribir nada (ver SealingKeyStore).
        let key = try await SealingKeyStore.key(reason: "Sellar la medición de «\(finding.title)»")
        let dir = findingDir(finding)
        let folder = dir.appendingPathComponent("measurements")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("MSR-\(measurement.measurementID.uuidString.prefix(8)).json")
        try CanonicalJSONEncoder().encode(measurement).write(to: file, options: .atomic)
        let seal: SealRecord
        do {
            seal = try await SealSigner().seal(bundleAt: dir, author: finding.author, geo: nil,
                                               previousSeal: lastSeal(dir), key: key)
            try writer.appendSeal(seal, to: dir)
        } catch {
            // Sin sello, el archivo sería "añadido no declarado" y el expediente dejaría de verificar.
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        try writer.writeVerifyDoc(to: dir, author: finding.author, rootHash: seal.rootHash)
    }

    // MARK: - Custodia

    static func verify(_ finding: Finding) async -> CustodyVerdict {
        do { return try await ChainVerifier().verify(bundleAt: findingDir(finding)) }
        catch { return .invalid([(error as? CustodyError) ?? .verificationFailed("\(error)")]) }
    }

    /// Borra un expediente solo si NO verifica como íntegro (sin escaneos, sellos
    /// rotos o archivos alterados): son pruebas fallidas, no evidencia. Un
    /// expediente íntegro es evidencia sellada y no se borra nunca (plan §2.B).
    /// La regla se aplica aquí, no en la vista, para que ningún llamador la salte.
    static func deleteIfNotIntact(_ finding: Finding) async throws {
        if await verify(finding).isValid {
            throw FieldError("Este expediente está íntegro y sellado: es evidencia y no se puede eliminar.")
        }
        let fm = FileManager.default
        try fm.removeItem(at: findingDir(finding))
        let exports = documents.appendingPathComponent("Exports").appendingPathComponent(findingDir(finding).lastPathComponent)
        if fm.fileExists(atPath: exports.path) { try fm.removeItem(at: exports) }
    }

    /// Qué selló cada eslabón de la cadena, del primero al último.
    static func sealHistory(_ finding: Finding) -> [SealChange] {
        SealHistory.changes(SealHistory.read(bundleAt: findingDir(finding)))
    }

    private static func lastSeal(_ findingDir: URL) -> SealRecord? {
        SealHistory.read(bundleAt: findingDir).last
    }

    // MARK: - Exportación

    /// Escribe PLY, STL, OBJ, LAS y GeoJSON (cada uno con su `record.json`).
    /// Un formato que falla no detiene a los demás: se informa en `problems`.
    static func export(_ entry: ScanEntry, finding: Finding) throws -> (files: [URL], problems: [String]) {
        let mesh = try loadMesh(entry)
        let utm = representativeFix(fixes(entry)).flatMap {
            try? UTMConverter().toUTM(latitude: $0.latitude, longitude: $0.longitude, height: $0.altitude)
        }
        let meta = ExportMetadata(finding: finding, scan: entry.scan, utm: utm, scaleUnits: nil)

        let out = documents.appendingPathComponent("Exports")
            .appendingPathComponent(findingDir(finding).lastPathComponent)
            .appendingPathComponent(String(entry.scan.scanID.uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var files: [URL] = []
        var problems: [String] = []
        func run(_ name: String, _ body: (URL) throws -> ExportSidecar) {
            do {
                let side = try body(out.appendingPathComponent(name))
                files += [side.fileURL, side.recordURL]
            } catch {
                problems.append("\(name): \(error)")
            }
        }
        run("malla.ply") { try PLYWriter().write(mesh: mesh, metadata: meta, to: $0) }
        run("replica_mm.stl") { try STLWriter().write(mesh: mesh, metadata: meta, to: $0) }
        run("malla.obj") { try OBJWriter().write(mesh: mesh, metadata: meta, to: $0) }
        run("nube.las") { try LASWriter().write(mesh: mesh, metadata: meta, to: $0) }
        if utm == nil {
            problems.append("sitio.geojson: el escaneo no tiene coordenadas GPS")
        } else {
            run("sitio.geojson") { try GeoJSONWriter().write(metadata: meta, to: $0) }
        }
        return (files, problems)
    }

    // MARK: - Helpers

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? CanonicalDateCoding.decoder().decode(T.self, from: data)
    }
}

extension ScanPurpose {
    var label: String {
        switch self {
        case .baseline: "Registro inicial"
        case .postIntervention: "Post-intervención"
        case .monitoring: "Monitoreo"
        case .damageAssessment: "Evaluación de daño"
        case .rescueDocumentation: "Documentación de rescate"
        case .specimenInventory: "Inventario de especímenes"
        case .stratigraphicProfile: "Perfil estratigráfico"
        }
    }
}

extension GeoreferenceQuality {
    var label: String {
        switch self {
        case .good: "GPS bueno"
        case .degraded: "GPS degradado"
        case .unvalidated: "Sin GPS"
        }
    }
}
