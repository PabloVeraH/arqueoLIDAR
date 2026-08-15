import Foundation
import Domain
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — LASWriter. LAS 1.4 con VLR OGC WKT del CRS.
// Formato binario de nube de puntos estándar en topografía.
// ═══════════════════════════════════════════════════════════════════════════════

public struct LASWriter {

    public init() {}

    public func write(
        mesh: Mesh,
        metadata: ExportMetadata,
        to url: URL
    ) throws(ExportError) -> ExportSidecar {

        guard let utm = metadata.utm else {
            throw .invalidCoordinate
        }

        // Extraer puntos únicos de la malla (deduplicados por posición)
        var uniquePoints: [SIMD3<Float>] = []
        var seen: Set<SIMD3<Float>> = []
        for v in mesh.vertices {
            if !seen.contains(v) {
                seen.insert(v)
                uniquePoints.append(v)
            }
        }

        guard !uniquePoints.isEmpty else { throw .writeFailed("Sin puntos") }

        let pointCount = UInt32(uniquePoints.count)

        // Construir WKT del CRS
        let wkt = wktForEPSG(utm.epsg)

        // Calcular offsets de cada sección
        let headerSize: UInt32 = 375 // LAS 1.4 header size
        let vlrCount: UInt32 = 1
        let vlrSize: UInt32 = 54 + UInt32(wkt.utf8.count) + 1 // +1 por el null terminator
        let pointDataOffset = headerSize + vlrSize
        let pointRecordLength: UInt16 = 34 // Point Data Record Format 2 (XYZ + RGB)

        var data = Data(capacity: Int(pointDataOffset) + Int(pointCount) * Int(pointRecordLength))

        // ====== LAS 1.4 Header ======
        // File Signature ("LASF")
        data.append("LASF".data(using: .ascii)!)
        // File Source ID (2 bytes)
        data.append(contentsOf: [0, 0])
        // Global Encoding (2 bytes LE)
        data.append(contentsOf: [0, 0])
        // Project ID GUID (16 bytes, zero)
        data.append(Data(repeating: 0, count: 16))
        // Version Major (1 byte) = 1
        data.append(1)
        // Version Minor (1 byte) = 4
        data.append(4)
        // System Identifier (32 bytes)
        var sysId = "PaleoRegistro LAS 1.4".data(using: .utf8)!
        sysId.append(Data(repeating: 0, count: max(0, 32 - sysId.count)))
        data.append(sysId.prefix(32))
        // Generating Software (32 bytes)
        var gen = "PaleoRegistro iOS".data(using: .utf8)!
        gen.append(Data(repeating: 0, count: max(0, 32 - gen.count)))
        data.append(gen.prefix(32))
        // File Creation Day of Year (2 bytes)
        let calendar = Calendar.current
        let doy = UInt16(calendar.ordinality(of: .day, in: .year, for: Date()) ?? 1)
        var doyLE = doy.littleEndian; withUnsafeBytes(of: &doyLE) { data.append(contentsOf: $0) }
        // File Creation Year (2 bytes)
        let year = UInt16(calendar.component(.year, from: Date()))
        var yearLE = year.littleEndian; withUnsafeBytes(of: &yearLE) { data.append(contentsOf: $0) }
        // Header Size (2 bytes) = 375
        var hSize: UInt16 = 375; withUnsafeBytes(of: &hSize) { data.append(contentsOf: $0) }
        // Offset to Point Data (4 bytes)
        var offsetPD = pointDataOffset.littleEndian; withUnsafeBytes(of: &offsetPD) { data.append(contentsOf: $0) }
        // Number of VLRs (4 bytes)
        var nVLR = vlrCount.littleEndian; withUnsafeBytes(of: &nVLR) { data.append(contentsOf: $0) }
        // Point Data Record Format (1 byte) = 2
        data.append(2)
        // Point Data Record Length (2 bytes)
        var pdrLen = pointRecordLength.littleEndian; withUnsafeBytes(of: &pdrLen) { data.append(contentsOf: $0) }
        // Legacy Number of Point Records (4 bytes)
        var legacyCount = pointCount.littleEndian; withUnsafeBytes(of: &legacyCount) { data.append(contentsOf: $0) }
        // Legacy Number of Points by Return (5 × 4 bytes, zero)
        data.append(Data(repeating: 0, count: 20))

        // Scale factors (8 bytes each) — 3 doubles: metros → enteros con 1 mm de precisión
        var scaleX: Double = 0.001; withUnsafeBytes(of: &scaleX) { data.append(contentsOf: $0) }
        var scaleY: Double = 0.001; withUnsafeBytes(of: &scaleY) { data.append(contentsOf: $0) }
        var scaleZ: Double = 0.001; withUnsafeBytes(of: &scaleZ) { data.append(contentsOf: $0) }

        // Offsets (8 bytes each)
        let originX = utm.easting
        let originY = utm.northing
        let originZ = utm.ellipsoidalHeight
        var offX = originX; withUnsafeBytes(of: &offX) { data.append(contentsOf: $0) }
        var offY = originY; withUnsafeBytes(of: &offY) { data.append(contentsOf: $0) }
        var offZ = originZ; withUnsafeBytes(of: &offZ) { data.append(contentsOf: $0) }

        // Max/Min X, Y, Z (8 bytes each * 6 = 48 bytes)
        let (minX, maxX) = (uniquePoints.map(\.x).min() ?? 0, uniquePoints.map(\.x).max() ?? 0)
        let (minY, maxY) = (uniquePoints.map(\.y).min() ?? 0, uniquePoints.map(\.y).max() ?? 0)
        let (minZ, maxZ) = (uniquePoints.map(\.z).min() ?? 0, uniquePoints.map(\.z).max() ?? 0)
        var maxXD = Double(maxX) + originX; withUnsafeBytes(of: &maxXD) { data.append(contentsOf: $0) }
        var minXD = Double(minX) + originX; withUnsafeBytes(of: &minXD) { data.append(contentsOf: $0) }
        var maxYD = Double(maxY) + originY; withUnsafeBytes(of: &maxYD) { data.append(contentsOf: $0) }
        var minYD = Double(minY) + originY; withUnsafeBytes(of: &minYD) { data.append(contentsOf: $0) }
        var maxZD = Double(maxZ) + originZ; withUnsafeBytes(of: &maxZD) { data.append(contentsOf: $0) }
        var minZD = Double(minZ) + originZ; withUnsafeBytes(of: &minZD) { data.append(contentsOf: $0) }

        // Start of Waveform Data Packet Record (8 bytes, 0)
        data.append(Data(repeating: 0, count: 8))

        // Start of first Extended VLR (8 bytes, 0)
        data.append(Data(repeating: 0, count: 8))

        // Number of Extended VLRs (4 bytes, 0)
        data.append(Data(repeating: 0, count: 4))

        // Number of Point Records (8 bytes)
        var pointCount64 = UInt64(pointCount).littleEndian; withUnsafeBytes(of: &pointCount64) { data.append(contentsOf: $0) }
        // Number of Points by Return (15 × 8 bytes = 120 bytes, zero)
        data.append(Data(repeating: 0, count: 120))

        assert(data.count == Int(headerSize), "Header size mismatch: \(data.count) != \(headerSize)")

        // ====== VLR: OGC WKT Coordinate System ======
        // Reserved (2 bytes, 0)
        data.append(contentsOf: [0, 0])
        // User ID (16 bytes)
        var userId = "LASF_Projection".data(using: .utf8)!
        userId.append(Data(repeating: 0, count: max(0, 16 - userId.count)))
        data.append(userId.prefix(16))
        // Record ID (2 bytes) = 2112 (OGC WKT)
        var recId: UInt16 = 2112; withUnsafeBytes(of: &recId) { data.append(contentsOf: $0) }
        // Record Length After Header (2 bytes) = WKT length + null terminator
        var wktLen: UInt16 = UInt16(wkt.utf8.count + 1); withUnsafeBytes(of: &wktLen) { data.append(contentsOf: $0) }
        // Description (32 bytes)
        var desc = "OGC WKT CRS".data(using: .utf8)!
        desc.append(Data(repeating: 0, count: max(0, 32 - desc.count)))
        data.append(desc.prefix(32))
        // VLR body: WKT string + null terminator
        data.append(wkt.data(using: .utf8)!)
        data.append(0) // null terminator

        // ====== Point Data Records ======
        let invScale: Double = 1.0 / 0.001
        for v in uniquePoints {
            // X, Y, Z como int32 (coordenadas UTM reales)
            let ix = Int32(((Double(v.x) + originX) - originX) * invScale)
            let iy = Int32(((Double(v.y) + originY) - originY) * invScale)
            let iz = Int32(((Double(v.z) + originZ) - originZ) * invScale)
            var xi = ix.littleEndian; withUnsafeBytes(of: &xi) { data.append(contentsOf: $0) }
            var yi = iy.littleEndian; withUnsafeBytes(of: &yi) { data.append(contentsOf: $0) }
            var zi = iz.littleEndian; withUnsafeBytes(of: &zi) { data.append(contentsOf: $0) }

            // Intensity (2 bytes, 0)
            data.append(contentsOf: [0, 0])
            // Return Number + Number of Returns + Scan Direction + Edge of Flight + Classification (2 bytes + 1 byte + 1 byte + 1 byte)
            data.append(contentsOf: [1, 1, 0, 0, 0]) // 5 bytes de flags

            // Scan Angle Rank (1 byte, 0)
            data.append(0)
            // User Data (1 byte, 0)
            data.append(0)
            // Point Source ID (2 bytes, 0)
            data.append(contentsOf: [0, 0])

            // RGB (2 bytes each, 0 = no color)
            data.append(contentsOf: [0, 0, 0, 0, 0, 0])
        }

        try ExportWrite.data(data, to: url)

        let sidecarURL = url.deletingPathExtension().appendingPathExtension("record.json")
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "las")
        
        try ExportWrite.sidecar(sidecar, to: sidecarURL)

        return ExportSidecar(fileURL: url, recordURL: sidecarURL)
    }

    private func wktForEPSG(_ epsg: Int) -> String {
        switch epsg {
        case 32718: return #"PROJCS["WGS 84 / UTM zone 18S",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",-75],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",10000000],UNIT["metre",1]]"#
        case 32719: return #"PROJCS["WGS 84 / UTM zone 19S",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",-69],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",10000000],UNIT["metre",1]]"#
        case 32712: return #"PROJCS["WGS 84 / UTM zone 12S",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],PARAMETER["central_meridian",-111],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],PARAMETER["false_northing",10000000],UNIT["metre",1]]"#
        default: return "LOCAL_CS[\"Unknown\",UNIT[\"metre\",1]]"
        }
    }
}