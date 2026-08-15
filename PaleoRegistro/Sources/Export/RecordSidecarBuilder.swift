import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — RecordSidecarBuilder. Construye el sidecar record.json obligatorio
// en todo export.
// ═══════════════════════════════════════════════════════════════════════════════

public struct RecordSidecarBuilder {

    public static func build(
        metadata: ExportMetadata,
        format: String,
        algorithms: [AlgorithmRun] = [],
        measurements: [Domain.Measurement] = [],
        custody: RecordSidecar.CustodyStats? = nil
    ) throws(ExportError) -> RecordSidecar {

        let device = RecordSidecar.DeviceInfo(
            model: RuntimeInfo.model,
            osVersion: RuntimeInfo.osVersion,
            hasLiDAR: RuntimeInfo.hasLiDAR,
            arKitVersion: RuntimeInfo.arKitVersion
        )

        let captureStats = RecordSidecar.CaptureStats(
            duration: 0,
            anchorCount: 0,
            coverageFraction: 0,
            thermalState: "nominal"
        )

        let geoStats = RecordSidecar.GeoStats(
            fixCount: 0,
            chosenFix: nil,
            utm: metadata.utm,
            meridianConvergence: 0,
            yawMethod: "gps_track",
            yawSigma: nil,
            quality: .unvalidated
        )

        return RecordSidecar(
            schemaVersion: 1,
            appVersion: RuntimeInfo.appVersion,
            buildID: RuntimeInfo.buildID,
            device: device,
            capture: captureStats,
            geo: geoStats,
            algorithms: algorithms,
            measurements: measurements,
            custody: custody,
            authorship: metadata.finding.author,
            disclaimer: RecordSidecar.defaultDisclaimer
        )
    }
}

/// Información de runtime sin dependencias de UIKit. Inmutable por defecto:
/// la capa de `App/` (proyecto Xcode) construye su propio `RecordSidecar`
/// con los valores reales del dispositivo, o pasa un `DeviceInfo` explícito.
enum RuntimeInfo {
    static let model: String = "unknown"
    static let osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    static let hasLiDAR: Bool = false
    static let arKitVersion: String = "unknown"
    static let appVersion: String = "0.0.0"
    static let buildID: String = "0"
}