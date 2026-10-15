import Foundation
import Domain
import Mesh
import Persistence
import Custody

// ═══════════════════════════════════════════════════════════════════════════════
// Une captura → expediente en disco → sello de custodia, usando los módulos
// del paquete PaleoRegistro. Los expedientes viven en Documentos/Findings, que
// es visible desde la app Archivos y desde Finder (UIFileSharingEnabled).
// ═══════════════════════════════════════════════════════════════════════════════

nonisolated struct SavedScan: Sendable, Identifiable {
    let findingID: UUID
    let title: String
    let folder: URL
    let meshURL: URL
    let vertexCount: Int
    let triangleCount: Int
    let rootHash: String
    var id: UUID { findingID }
}

nonisolated struct FindingItem: Sendable, Identifiable {
    let summary: FindingSummary
    let folder: URL
    let meshFiles: [URL]
    var id: UUID { summary.findingID }
}

nonisolated enum FindingServiceError: LocalizedError {
    case emptyMesh

    var errorDescription: String? {
        switch self {
        case .emptyMesh: "No hay malla para guardar. Recorre la zona con la cámara hasta ver el wireframe."
        }
    }
}

actor FindingService {
    static let shared = FindingService()

    let baseURL: URL
    private let store: FindingStore
    private let writer: BundleWriter
    private var indexLoaded = false

    /// Clave P-256 de software, una por sesión de la app.
    /// Pendiente (F10): clave persistente en Secure Enclave protegida con Face ID.
    private let key = SoftwareSigningKey()

    init() {
        baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = FindingStore(baseURL: baseURL)
        writer = BundleWriter(baseURL: baseURL)
    }

    /// Fusiona las piezas de la captura, crea el expediente, guarda la malla
    /// y sella el expediente (cadena de custodia con un primer eslabón).
    func saveScan(parts: [MeshPart], title: String, author: AuthorIdentity) async throws -> SavedScan {
        let mesh = MeshMergerCore().merge(parts: parts)
        guard !mesh.isEmpty else { throw FindingServiceError.emptyMesh }

        try await ensureIndex()
        let finding = Finding(siteID: UUID(), title: title, expeditionCode: "TERRENO", author: author)
        _ = try await store.createFinding(finding)
        let scan = ScanSession(findingID: finding.findingID, purpose: .baseline)
        let scanDir = try await store.appendScan(scan, mesh: mesh, to: finding.findingID)

        // El marcador .sealed se escribe ANTES del sello para que quede cubierto
        // por el manifiesto (dentro de scans/<id>/ no está excluido del hash).
        try writer.markSealed(scanDir: scanDir)

        let folder = writer.findingURL(finding.findingID)
        let seal = try await SealSigner().seal(bundleAt: folder, author: author, geo: nil, previousSeal: nil, key: key)
        try writer.appendSeal(seal, to: folder)
        try writer.writeVerifyDoc(to: folder, author: author, rootHash: seal.rootHash)

        return SavedScan(findingID: finding.findingID, title: title, folder: folder,
                         meshURL: scanDir.appendingPathComponent("mesh.ply"),
                         vertexCount: mesh.vertices.count, triangleCount: mesh.triangleCount,
                         rootHash: seal.rootHash)
    }

    func list() async throws -> [FindingItem] {
        try await store.rebuildIndex()
        indexLoaded = true
        return try await store.listFindings()
            .sorted { $0.createdAt > $1.createdAt }
            .map { FindingItem(summary: $0, folder: writer.findingURL($0.findingID), meshFiles: meshFiles(for: $0.findingID)) }
    }

    /// Verifica la cadena de custodia del expediente con ChainVerifier.
    func verify(findingID: UUID) async -> (ok: Bool, detail: String) {
        do {
            let verdict = try await ChainVerifier().verify(bundleAt: writer.findingURL(findingID))
            switch verdict {
            case .valid:
                return (true, "Íntegro: archivos, cadena y firmas verificados.")
            case .invalid(let errors):
                return (false, errors.map { "• \($0)" }.joined(separator: "\n"))
            }
        } catch {
            return (false, "Error al verificar: \(error)")
        }
    }

    /// Elimina la carpeta completa del expediente (acción explícita del usuario).
    func delete(findingID: UUID) async throws {
        try FileManager.default.removeItem(at: writer.findingURL(findingID))
        try await store.rebuildIndex()
    }

    private func ensureIndex() async throws {
        guard !indexLoaded else { return }
        try await store.rebuildIndex()
        indexLoaded = true
    }

    private func meshFiles(for findingID: UUID) -> [URL] {
        let scans = writer.findingURL(findingID).appendingPathComponent("scans")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: scans, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("mesh.ply") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }
}
