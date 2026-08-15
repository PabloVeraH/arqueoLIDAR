import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F9 — FindingStore. Implementación de FindingStoring.
// Bundle en disco como fuente de verdad; índice en memoria (reconstruible).
// En una app real, IndexStore se respalda con SwiftData o similar.
// ═══════════════════════════════════════════════════════════════════════════════

public actor FindingStore: FindingStoring {

    private let writer: BundleWriter
    private var index: [UUID: FindingSummary] = [:]
    private var scanIndex: [UUID: UUID] = [:]

    public init(baseURL: URL) {
        self.writer = BundleWriter(baseURL: baseURL)
    }

    public func createFinding(_ finding: Finding) async throws(StoreError) -> URL {
        let dir = try writer.createFinding(finding)
        let summary = FindingSummary(
            findingID: finding.findingID,
            title: finding.title,
            expeditionCode: finding.expeditionCode,
            createdAt: finding.createdAt,
            scanCount: 0,
            sealedCount: 0,
            georeferenceQuality: finding.georeferenceQuality
        )
        index[finding.findingID] = summary
        return dir
    }

    public func appendScan(_ scan: ScanSession, mesh: Mesh, to findingID: UUID) async throws(StoreError) -> URL {
        guard index[findingID] != nil else { throw .findingNotFound(findingID) }

        let scanDir = try writer.createScanDir(scan, findingID: findingID)
        try writer.writeMesh(mesh, to: scanDir)

        scanIndex[scan.scanID] = findingID
        if var summary = index[findingID] {
            summary = FindingSummary(
                findingID: summary.findingID,
                title: summary.title,
                expeditionCode: summary.expeditionCode,
                createdAt: summary.createdAt,
                scanCount: summary.scanCount + 1,
                sealedCount: summary.sealedCount,
                georeferenceQuality: summary.georeferenceQuality
            )
            index[findingID] = summary
        }

        return scanDir
    }

    public func loadMesh(scanID: UUID, findingID: UUID) async throws(StoreError) -> Mesh {
        let findDir = writer.findingURL(findingID)
        let meshPath = findDir.appendingPathComponent("scans/\(scanID.uuidString)/mesh.ply")

        guard fileManager().fileExists(atPath: meshPath.path) else {
            throw .scanNotFound(scanID)
        }
        throw .bundleCorrupt("Carga de PLY no implementada en Persistence; usar Export/PLYWriter en fase 12")
    }

    public func listFindings() async throws(StoreError) -> [FindingSummary] {
        Array(index.values).sorted { $0.createdAt > $1.createdAt }
    }

    public func rebuildIndex() async throws(StoreError) {
        index.removeAll()
        scanIndex.removeAll()

        let findingsDir = writer.findingURL(UUID()).deletingLastPathComponent()
        guard let contents = try? fileManager().contentsOfDirectory(at: findingsDir, includingPropertiesForKeys: nil) else {
            return
        }

        let decoder = CanonicalDateCoding.decoder()
        for dir in contents {
            let manifestPath = dir.appendingPathComponent("finding.json")
            guard let data = try? Data(contentsOf: manifestPath),
                  let finding = try? decoder.decode(Finding.self, from: data) else { continue }

            let scansDir = dir.appendingPathComponent("scans")
            let scanCount = (try? fileManager().contentsOfDirectory(at: scansDir, includingPropertiesForKeys: nil))?.count ?? 0

            var sealedCount = 0
            if let scans = try? fileManager().contentsOfDirectory(at: scansDir, includingPropertiesForKeys: nil) {
                sealedCount = scans.filter { writer.isSealed(scanDir: $0) }.count
            }

            let summary = FindingSummary(
                findingID: finding.findingID,
                title: finding.title,
                expeditionCode: finding.expeditionCode,
                createdAt: finding.createdAt,
                scanCount: scanCount,
                sealedCount: sealedCount,
                georeferenceQuality: finding.georeferenceQuality
            )
            index[finding.findingID] = summary
        }
    }

    // MARK: - Helpers

    private func fileManager() -> FileManager { .default }
}