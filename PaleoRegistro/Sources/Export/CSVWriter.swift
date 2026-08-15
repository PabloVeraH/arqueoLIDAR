import Foundation
import Domain
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — CSVWriter. Una fila por espécimen para catastro del museo.
// ═══════════════════════════════════════════════════════════════════════════════

public struct CSVWriter {

    public init() {}

    public func write(
        specimens: [Specimen],
        measurements: [Domain.Measurement],
        metadata: ExportMetadata,
        to url: URL
    ) throws(ExportError) -> ExportSidecar {

        var lines: [String] = []

        // Cabecera
        lines.append("specimen_id,label,center_x_m,center_y_m,center_z_m,length_m,width_m,height_m,dim_x_m,dim_y_m,dim_z_m,exposed_volume_m3,estimated_volume_m3,volume_method,classification_hint,finding_id,expedition_code")

        for s in specimens {
            let pose = s.pose
            let dims = pose.dimensions

            let row = [
                s.specimenID.uuidString,
                escapeCSV(s.label),
                CanonicalFormat.floatStr(pose.center.x),
                CanonicalFormat.floatStr(pose.center.y),
                CanonicalFormat.floatStr(pose.center.z),
                CanonicalFormat.floatStr(dims.x),
                CanonicalFormat.floatStr(dims.y),
                CanonicalFormat.floatStr(dims.z),
                CanonicalFormat.floatStr(dims.x),
                CanonicalFormat.floatStr(dims.y),
                CanonicalFormat.floatStr(dims.z),
                s.exposedVolume.map { CanonicalFormat.doubleStr($0) } ?? "",
                s.estimatedTotalVolume.map { CanonicalFormat.doubleStr($0) } ?? "",
                escapeCSV(s.volumeEstimationMethod ?? ""),
                escapeCSV(s.classificationHint ?? ""),
                metadata.finding.findingID.uuidString,
                escapeCSV(metadata.finding.expeditionCode),
            ]
            lines.append(row.joined(separator: ","))
        }

        // Añadir mediciones como filas extra
        if !measurements.isEmpty {
            lines.append("")
            lines.append("measurement_id,kind,value,unit,method,is_inferred,uncertainty")
            for m in measurements {
                let row = [
                    m.measurementID.uuidString,
                    m.kind.rawValue,
                    CanonicalFormat.doubleStr(m.value),
                    m.unit,
                    escapeCSV(m.method),
                    m.isInferred ? "true" : "false",
                    m.uncertainty.map { CanonicalFormat.doubleStr($0) } ?? "",
                ]
                lines.append(row.joined(separator: ","))
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try ExportWrite.data(content.data(using: .utf8)!, to: url)

        let sidecarURL = url.deletingPathExtension().appendingPathExtension("record.json")
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "csv")
        
        try ExportWrite.sidecar(sidecar, to: sidecarURL)

        return ExportSidecar(fileURL: url, recordURL: sidecarURL)
    }

    private func escapeCSV(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }
}