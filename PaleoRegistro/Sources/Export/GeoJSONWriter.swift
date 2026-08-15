import Foundation
import Domain
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — GeoJSONWriter. FeatureCollection con CRS UTM.
// Incluye polígono del sitio y puntos de especímenes.
// ═══════════════════════════════════════════════════════════════════════════════

public struct GeoJSONWriter {

    public init() {}

    public func write(
        metadata: ExportMetadata,
        to url: URL
    ) throws(ExportError) -> ExportSidecar {

        guard let utm = metadata.utm else {
            throw .invalidCoordinate
        }

        // Aplicar perfil de precisión de ubicación
        let displayUTM = applyPrecision(utm, profile: metadata.precisionProfile)

        var features: [String] = []

        // Feature: punto del hallazgo
        let pointFeature = """
        {"type":"Feature","geometry":{"type":"Point","coordinates":[\
        \(CanonicalFormat.doubleStr(displayUTM.easting)),\
        \(CanonicalFormat.doubleStr(displayUTM.northing))]},\
        "properties":{"title":"\(metadata.finding.title)","id":"\(metadata.finding.findingID.uuidString)"}}
        """
        features.append(pointFeature)

        // FeatureCollection
        let geoJSON = """
        {"type":"FeatureCollection","crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:EPSG::\(displayUTM.epsg)"}},\
        "features":[\(features.joined(separator: ","))]}\n
        """
        try ExportWrite.data(geoJSON.data(using: .utf8)!, to: url)

        let sidecarURL = url.deletingPathExtension().appendingPathExtension("record.json")
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "geojson")
        
        try ExportWrite.sidecar(sidecar, to: sidecarURL)

        return ExportSidecar(fileURL: url, recordURL: sidecarURL)
    }

    private func applyPrecision(_ utm: UTMCoordinate, profile: ExportPrecisionProfile) -> UTMCoordinate {
        switch profile {
        case .exact:
            return utm
        case .degraded:
            // Redondear a 100 m para difusión pública
            return try! UTMCoordinate(
                easting: (utm.easting / 100).rounded() * 100,
                northing: (utm.northing / 100).rounded() * 100,
                ellipsoidalHeight: utm.ellipsoidalHeight,
                zone: utm.zone,
                isNorthernHemisphere: utm.isNorthernHemisphere,
                epsg: utm.epsg,
                datum: utm.datum
            )
        case .omitted:
            // Coordenadas a (0,0) con marca
            return try! UTMCoordinate(
                easting: 0, northing: 0,
                ellipsoidalHeight: 0,
                zone: utm.zone,
                isNorthernHemisphere: utm.isNorthernHemisphere,
                epsg: utm.epsg,
                datum: utm.datum
            )
        }
    }
}