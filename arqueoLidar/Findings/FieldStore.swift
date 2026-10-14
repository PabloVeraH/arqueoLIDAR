import Foundation
import Domain
import Mesh
import Geo
import Custody
import Persistence
import Export

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

    // ponytail: clave de software nueva por cada arranque de la app. Cada sello
    // lleva su propia clave pública, así que la cadena verifica igual; el plan
    // (§2.C.6) pide Secure Enclave + Face ID para no-repudio real.
    static let signingKey = SoftwareSigningKey()

    // MARK: - Hallazgos

    static func findings() -> [Finding] {
        let dir = documents.appendingPathComponent("Findings")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { load(Finding.self, from: $0.appendingPathComponent("finding.json")) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func createFinding(_ finding: Finding) throws {
        _ = try writer.createFinding(finding)
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
                         finding: Finding) async throws -> SavedScan {
        let merged = MeshMergerCore().merge(parts: parts)
        guard !merged.isEmpty else {
            throw FieldError("No hay malla para guardar. Recorre la zona con la cámara hasta ver el wireframe.")
        }
        let mesh = Mesh(vertices: merged.vertices, indices: merged.indices,
                        normals: MeshOps().computeVertexNormals(merged).map(vecNormalize))

        let verdict = FixQualityGate().evaluate(burst: fixes)
        let scan = ScanSession(findingID: finding.findingID, purpose: purpose,
                               georeferenceQuality: verdict.quality)

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
                                               key: signingKey)
        try writer.appendSeal(seal, to: dir)
        try writer.writeVerifyDoc(to: dir, author: finding.author, rootHash: seal.rootHash)
        return SavedScan(scanID: scan.scanID, title: finding.title, folder: dir,
                         meshURL: scanDir.appendingPathComponent("mesh.ply"),
                         vertexCount: mesh.vertices.count, triangleCount: mesh.triangleCount,
                         rootHash: seal.rootHash)
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

    // MARK: - Custodia

    static func verify(_ finding: Finding) async -> CustodyVerdict {
        do { return try await ChainVerifier().verify(bundleAt: findingDir(finding)) }
        catch { return .invalid([(error as? CustodyError) ?? .verificationFailed("\(error)")]) }
    }

    private static func lastSeal(_ findingDir: URL) -> SealRecord? {
        let chain = findingDir.appendingPathComponent("seals/chain.jsonl")
        guard let text = try? String(contentsOf: chain, encoding: .utf8),
              let line = text.split(separator: "\n").last else { return nil }
        return try? CanonicalDateCoding.decoder().decode(SealRecord.self, from: Data(line.utf8))
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
