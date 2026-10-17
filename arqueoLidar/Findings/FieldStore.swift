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

/// Lo que entrega la captura al guardar.
nonisolated struct CaptureRecord: Sendable {
    let parts: [MeshPart]
    let fixes: [GeoFix]
    let purpose: ScanPurpose
    let mark: ObjectMark?
    let trajectory: [CameraSample]
    let controlPoints: [ControlPoint]
    let quality: QualityReport
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
    static func saveScan(_ capture: CaptureRecord, finding: Finding,
                         replacing: ScanEntry? = nil, reason: String? = nil) async throws -> SavedScan {
        let fixes = capture.fixes
        let merged = MeshMergerCore().merge(parts: capture.parts)
        guard !merged.isEmpty else {
            throw FieldError("No hay malla para guardar. Recorre la zona con la cámara hasta ver el wireframe.")
        }
        // Face ID o código antes de escribir nada (ver SealingKeyStore).
        let key = try await SealingKeyStore.key(reason: "Sellar el escaneo de «\(finding.title)»")
        let mesh = Mesh(vertices: merged.vertices, indices: merged.indices,
                        normals: MeshOps().computeVertexNormals(merged).map(vecNormalize))

        let verdict = FixQualityGate().evaluate(burst: fixes)
        let north = resolveNorth(capture)
        let scan = ScanSession(findingID: finding.findingID, purpose: capture.purpose,
                               supersedes: replacing?.scan.scanID,
                               // Con puntos de control la ubicación es la del topógrafo, no la del teléfono.
                               georeferenceQuality: capture.controlPoints.isEmpty ? verdict.quality : .good,
                               siteAlignment: north.matrix, objectMark: capture.mark,
                               supersedesReason: replacing == nil ? nil : reason,
                               siteFrame: north.frame, northMethod: north.method, northNote: north.note)

        let scanDir = try writer.createScanDir(scan, findingID: finding.findingID)
        try writer.writeMesh(mesh, to: scanDir)
        // El plan (§2.C.5) pide persistir la serie entera, no solo la fijación elegida.
        try CanonicalJSONEncoder().encode(fixes)
            .write(to: scanDir.appendingPathComponent("geo.json"), options: .atomic)
        // Recorrido de la cámara (norte verdadero) y calidad de la sesión, sellados con el escaneo.
        try CanonicalJSONEncoder().encode(capture.trajectory)
            .write(to: scanDir.appendingPathComponent("trajectory.json"), options: .atomic)
        try CanonicalJSONEncoder().encode(capture.quality)
            .write(to: scanDir.appendingPathComponent("quality.json"), options: .atomic)
        if !capture.controlPoints.isEmpty {
            try CanonicalJSONEncoder().encode(capture.controlPoints)
                .write(to: scanDir.appendingPathComponent("control_points.json"), options: .atomic)
        }

        // `.sealed` se escribe ANTES de sellar para que quede dentro del manifiesto:
        // Hasher solo excluye el `.sealed` de la raíz del bundle, no el de cada
        // escaneo, y uno escrito después aparecería como archivo no declarado.
        try writer.markSealed(scanDir: scanDir)

        let dir = findingDir(finding)
        let seal = try await sealAndRecord(finding, adding: [scanDir], key: key,
                                           geo: capture.controlPoints.first?.fix ?? representativeFix(fixes))
        return SavedScan(scanID: scan.scanID, title: finding.title, folder: dir,
                         meshURL: scanDir.appendingPathComponent("mesh.ply"),
                         vertexCount: mesh.vertices.count, triangleCount: mesh.triangleCount,
                         rootHash: seal.rootHash, keyProtection: key.protection)
    }

    /// Norte verdadero: con 2+ puntos de control, por ellos; si no, por el
    /// recorrido de la cámara contra el GPS. Si no se puede, dice por qué en
    /// palabras (queda en scan.json como `northNote`).
    static func resolveNorth(_ capture: CaptureRecord)
        -> (frame: SiteFrame?, matrix: Matrix4x4, method: NorthMethod?, note: String?) {
        func why(_ error: Error) -> String {
            switch error as? GeoError {
            case .degenerateTrack(let detail): detail
            case .noFixAvailable, .fixQualityInsufficient: "no hubo GPS de buena calidad"
            default: "\(error)"
            }
        }
        if capture.controlPoints.count >= 2 {
            do {
                let r = try ControlPointAligner().resolve(capture.controlPoints)
                return (r.frame, r.arWorldToSite, .controlPoints, nil)
            } catch {
                return (nil, .identity, nil, "Los puntos de control no alcanzan para el norte (\(why(error))).")
            }
        }
        let track = capture.trajectory.map {
            (time: $0.time, transform: Matrix4x4(translation: $0.position, quaternion: Quatf(vector: .zero, scalar: 1)))
        }
        do {
            let r = try SiteFrameResolver().resolve(cameraTrack: track, fixes: capture.fixes, magneticHeading: nil)
            return (r.frame, r.arWorldToSite, .gpsTrack, nil)
        } catch {
            return (nil, .identity, nil,
                    "Sin norte verdadero (\(why(error))). Para tenerlo, camina al menos 10 m al aire libre mientras escaneas, o marca 2 puntos de control del topógrafo.")
        }
    }

    /// Coordenada UTM (WGS84, hemisferio sur) entregada por un topógrafo, como fijación manual.
    static func controlPointFix(easting: Double, northing: Double, height: Double,
                                zone: Int, accuracy: Double) throws -> GeoFix {
        let utm = try UTMCoordinate(easting: easting, northing: northing, ellipsoidalHeight: height, zone: zone,
                                    isNorthernHemisphere: false, epsg: 32700 + zone, datum: "WGS84")
        let geo = try UTMConverter().toGeodetic(utm)
        return try GeoFix(latitude: geo.lat, longitude: geo.lon, altitude: geo.h, horizontalAccuracy: accuracy,
                          verticalAccuracy: accuracy, timestamp: Date(), source: .manual)
    }

    static func controlPoints(_ entry: ScanEntry) -> [ControlPoint] {
        load([ControlPoint].self, from: entry.dir.appendingPathComponent("control_points.json")) ?? []
    }

    /// Ubicación del escaneo: el primer punto de control si lo hay (±cm), si no el GPS.
    static func location(_ entry: ScanEntry) -> GeoFix? {
        controlPoints(entry).first?.fix ?? representativeFix(fixes(entry))
    }

    /// "Reemplazado por …" / "Reemplaza al …: motivo", o nil si no aplica.
    static func replacementText(_ entry: ScanEntry, among scans: [ScanEntry]) -> String? {
        func when(_ e: ScanEntry) -> String { e.scan.capturedAt.formatted(date: .abbreviated, time: .shortened) }
        if let newer = scans.first(where: { $0.scan.supersedes == entry.scan.scanID }) {
            return "Reemplazado por el escaneo del \(when(newer)) (sigue sellado)"
        }
        if let id = entry.scan.supersedes {
            let older = scans.first { $0.scan.scanID == id }.map { "del \(when($0))" } ?? "anterior"
            let reason = entry.scan.supersedesReason.map { ": \($0)" } ?? ""
            return "Reemplaza al escaneo \(older)\(reason)"
        }
        return nil
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
        _ = try await sealAndRecord(finding, adding: [file], key: key, geo: nil)
    }

    // MARK: - Notas de custodia

    /// Notas selladas del expediente, por nombre de archivo (`NOTE-….json`).
    static func notes(_ finding: Finding) -> [String: CustodyNote] {
        let dir = findingDir(finding).appendingPathComponent("notes")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Dictionary(files.compactMap { url in load(CustodyNote.self, from: url).map { (url.lastPathComponent, $0) } },
                          uniquingKeysWith: { a, _ in a })
    }

    /// Sella el expediente tal como está, con una nota (antes / después de
    /// intervenir) y la ubicación GPS del momento si la hay.
    static func sealNote(_ note: CustodyNote, geo: GeoFix?, finding: Finding) async throws {
        let key = try await SealingKeyStore.key(reason: "Sellar «\(note.kind.label)» en «\(finding.title)»")
        let folder = findingDir(finding).appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("NOTE-\(note.noteID.uuidString.prefix(8)).json")
        try CanonicalJSONEncoder().encode(note).write(to: file, options: .atomic)
        _ = try await sealAndRecord(finding, adding: [file], key: key, geo: geo)
    }

    // MARK: - Custodia

    /// Sella el expediente y deja junto a la cadena lo que necesita un tercero
    /// para verificarlo sin la app (VERIFY.txt, seals/SHA256SUMS y una copia de
    /// verify_chain.py). Si el sello no llega a escribirse, borra `newItems`:
    /// sin sello serían archivos "añadidos no declarados".
    private static func sealAndRecord(_ finding: Finding, adding newItems: [URL],
                                      key: any SigningKey, geo: GeoFix?) async throws -> SealRecord {
        let dir = findingDir(finding)
        let seal: SealRecord
        do {
            seal = try await SealSigner().seal(bundleAt: dir, author: finding.author, geo: geo,
                                               previousSeal: lastSeal(dir), key: key)
            try writer.appendSeal(seal, to: dir)
        } catch {
            for url in newItems { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        writer.lockSealed(seal.manifest, in: dir)
        try writer.writeVerifyDoc(to: dir, author: finding.author, rootHash: seal.rootHash)
        try writer.writeChecksums(seal.manifest, to: dir)
        copyVerifier(to: dir)
        return seal
    }

    /// `seals/` no entra al manifiesto: la copia se puede renovar sin romper sellos.
    private static func copyVerifier(to findingDir: URL) {
        guard let source = Bundle.main.url(forResource: "verify_chain", withExtension: "py") else { return }
        let target = findingDir.appendingPathComponent("seals/verify_chain.py")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
    }

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
        writer.unlockForDeletion(findingDir(finding)) // los sellados quedaron de solo lectura
        try fm.removeItem(at: findingDir(finding))
        let exports = documents.appendingPathComponent("Exports").appendingPathComponent(findingDir(finding).lastPathComponent)
        if fm.fileExists(atPath: exports.path) { try fm.removeItem(at: exports) }
    }

    /// Aparta a Documents/Recuperados/FND-…/ los escaneos, mediciones o notas que
    /// quedaron en disco sin sellar (guardado cortado por cierre de la app o
    /// batería). Dentro del expediente harían fallar la verificación; afuera se
    /// conservan para revisarlos. Lo sellado nunca se mueve (SealHistory.unsealedItems).
    static func recoverUnsealed(_ finding: Finding) -> [String] {
        let dir = findingDir(finding)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("seals/chain.jsonl").path) else { return [] }
        let items = SealHistory.unsealedItems(bundleAt: dir)
        let target = documents.appendingPathComponent("Recuperados").appendingPathComponent(dir.lastPathComponent)
        return items.compactMap { item in
            let destination = target.appendingPathComponent(item + "-" + String(UUID().uuidString.prefix(4)))
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: dir.appendingPathComponent(item), to: destination)
                return item
            } catch {
                return nil
            }
        }
    }

    static func quality(_ entry: ScanEntry) -> QualityReport? {
        load(QualityReport.self, from: entry.dir.appendingPathComponent("quality.json"))
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
        let utm = location(entry).flatMap {
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
    nonisolated var label: String {
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

extension CustodyNoteKind {
    nonisolated var label: String {
        switch self {
        case .beforeIntervention: "Antes de intervenir"
        case .afterIntervention: "Después de intervenir"
        case .checkpoint: "Control"
        }
    }
}

extension GeoreferenceQuality {
    nonisolated var label: String {
        switch self {
        case .good: "GPS bueno"
        case .degraded: "GPS degradado"
        case .unvalidated: "Sin GPS"
        }
    }
}
