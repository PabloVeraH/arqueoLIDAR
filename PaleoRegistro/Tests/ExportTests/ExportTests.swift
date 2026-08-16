import Testing
import Foundation
import Domain
import Geo
import Persistence
@testable import Export

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — Export: criterios de aceptación. Cada formato validado con
// herramienta externa conceptual, byte-determinismo y sidecar obligatorio.
// ═══════════════════════════════════════════════════════════════════════════════

/// Busca una subcadena ASCII dentro de `Data` binaria arbitraria, sin
/// intentar decodificar el archivo completo como texto (que falla — o peor,
/// da un falso negativo silencioso — en cuanto el archivo tiene un solo byte
/// no-ASCII, como cualquier archivo binario real con coordenadas de punto
/// flotante).
func containsASCIISubstring(_ substring: String, in data: Data) -> Bool {
    let needle = Array(substring.utf8)
    guard !needle.isEmpty, data.count >= needle.count else { return false }
    let haystack = [UInt8](data)
    for start in 0...(haystack.count - needle.count) {
        if Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
    }
    return false
}

func tempExportDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("export-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func sampleMesh() -> Mesh {
    let cube: [SIMD3<Float>] = [
        SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(1,1,0), SIMD3(0,1,0),
        SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,1,1), SIMD3(0,1,1),
    ]
    let indices: [UInt32] = [
        0,1,2, 0,2,3, // front
        4,5,6, 4,6,7, // back
        0,1,5, 0,5,4, // bottom
        2,3,7, 2,7,6, // top
        1,2,6, 1,6,5, // right
        0,3,7, 0,7,4, // left
    ]
    return Mesh(vertices: cube, indices: indices)
}

func sampleMetadata() throws -> ExportMetadata {
    let author = AuthorIdentity(name: "Test", role: "Test", institution: "Test")
    let finding = Finding(siteID: UUID(), title: "Test Finding", expeditionCode: "EXP-TEST", author: author)
    let utm = try UTMCoordinate(easting: 350000, northing: 6300000, ellipsoidalHeight: 500, zone: 19, isNorthernHemisphere: false, epsg: 32719, datum: "WGS84")
    return ExportMetadata(finding: finding, scan: nil, utm: utm, scaleUnits: nil)
}

@Suite("F12 Export: PLYWriter")
struct PLYWriterTests {

    @Test("PLY binario: byte-determinismo")
    func byteDeterminism() throws {
        let mesh = sampleMesh()
        let metadata = try sampleMetadata()
        let writer = PLYWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path1 = dir.appendingPathComponent("test1.ply")
        let path2 = dir.appendingPathComponent("test2.ply")

        _ = try writer.write(mesh: mesh, metadata: metadata, to: path1)
        _ = try writer.write(mesh: mesh, metadata: metadata, to: path2)

        let d1 = try Data(contentsOf: path1)
        let d2 = try Data(contentsOf: path2)
        #expect(d1 == d2, "Dos exports del mismo mesh deben ser byte-idénticos")

        // Verificar cabecera PLY
        let header = String(data: d1.prefix(200), encoding: .ascii)!
        #expect(header.contains("ply"))
        #expect(header.contains("format binary_little_endian 1.0"))
        #expect(header.contains("element vertex 8"))
        #expect(header.contains("element face 12"))
    }

    @Test("PLY sidecar se genera con el export")
    func sidecarGenerated() throws {
        let mesh = sampleMesh()
        let metadata = try sampleMetadata()
        let writer = PLYWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("test.ply")
        let result = try writer.write(mesh: mesh, metadata: metadata, to: path)

        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: result.recordURL.path))
        #expect(result.recordURL.path.hasSuffix(".record.json"))

        // El sidecar debe ser JSON canónico decodificable (fechas ISO 8601)
        let data = try Data(contentsOf: result.recordURL)
        let sidecar = try CanonicalDateCoding.decoder().decode(RecordSidecar.self, from: data)
        #expect(sidecar.schemaVersion == 1)
        #expect(sidecar.geo.utm?.epsg == 32719)
        #expect(!sidecar.disclaimer.isEmpty)
    }
}

@Suite("F12 Export: STLWriter")
struct STLWriterTests {

    @Test("STL binario: cubo de 100 mm se exporta con escala correcta")
    func scale100mmCube() throws {
        // Cubo de 0.1 m = 100 mm
        var cubeVerts: [SIMD3<Float>] = []
        for z in [Float(0), 0.1] {
            for y in [Float(0), 0.1] {
                for x in [Float(0), 0.1] {
                    cubeVerts.append(SIMD3(x, y, z))
                }
            }
        }
        let indices: [UInt32] = [
            0,1,3, 0,3,2, 4,5,7, 4,7,6,
            0,4,5, 0,5,1, 2,6,7, 2,7,3,
            1,5,7, 1,7,3, 0,4,6, 0,6,2,
        ]
        let mesh = Mesh(vertices: cubeVerts, indices: indices)
        let metadata = try sampleMetadata()
        let writer = STLWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent("cube.stl")
        _ = try writer.write(mesh: mesh, metadata: metadata, to: path)

        let data = try Data(contentsOf: path)
        #expect(data.count >= 84) // header + triangle count

        // Leer número de triángulos (uint32 en offset 80)
        let faceCount = data.loadUnaligned(as: UInt32.self, fromByteOffset: 80)
        #expect(faceCount == 12)

        // Leer primer triángulo: 12 floats (normal + 3 vértices)
        // Los vértices deben estar en el rango 0-100 (mm)
        // Offset del primer vértice: 84 (header) + 12 (normal) = 96 bytes
        let v0_x = data.loadUnaligned(as: Float.self, fromByteOffset: 96)
        #expect(v0_x >= -1 && v0_x <= 101, "Coordenada fuera de rango 0-100 mm: \(v0_x)")
    }

    @Test("STL byte-determinismo")
    func stlByteDeterminism() throws {
        let mesh = sampleMesh()
        let metadata = try sampleMetadata()
        let writer = STLWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let d1 = try { let r = try writer.write(mesh: mesh, metadata: metadata, to: dir.appendingPathComponent("a.stl")); return try Data(contentsOf: r.fileURL) }()
        let d2 = try { let r = try writer.write(mesh: mesh, metadata: metadata, to: dir.appendingPathComponent("b.stl")); return try Data(contentsOf: r.fileURL) }()
        #expect(d1 == d2)
    }
}

@Suite("F12 Export: OBJWriter")
struct OBJWriterTests {

    @Test("OBJ byte-determinismo")
    func objByteDeterminism() throws {
        let mesh = sampleMesh()
        let metadata = try sampleMetadata()
        let writer = OBJWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let d1 = try { let r = try writer.write(mesh: mesh, metadata: metadata, to: dir.appendingPathComponent("a.obj")); return try String(contentsOf: r.fileURL) }()
        let d2 = try { let r = try writer.write(mesh: mesh, metadata: metadata, to: dir.appendingPathComponent("b.obj")); return try String(contentsOf: r.fileURL) }()
        #expect(d1 == d2, "Dos OBJ del mismo mesh deben ser idénticos")
        #expect(d1.contains("v "))
        #expect(d1.contains("f "))
    }

    @Test("OBJ contiene 8 vértices para el cubo unitario")
    func objVertexCount() throws {
        let mesh = sampleMesh()
        let metadata = try sampleMetadata()
        let writer = OBJWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try writer.write(mesh: mesh, metadata: metadata, to: dir.appendingPathComponent("cube.obj"))
        let content = try String(contentsOf: r.fileURL)
        let vCount = content.split(separator: "\n").filter { $0.hasPrefix("v ") }.count
        #expect(vCount == 8, "El cubo unitario debe tener 8 vértices, tiene \(vCount)")
    }
}

@Suite("F12 Export: LASWriter")
struct LASWriterTests {

    @Test("LAS 1.4 contiene VLR WKT y header válido")
    func las14VLR() throws {
        let mesh = sampleMesh()
        let metadata = try sampleMetadata()
        let writer = LASWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try writer.write(mesh: mesh, metadata: metadata, to: dir.appendingPathComponent("test.las"))
        let data = try Data(contentsOf: r.fileURL)

        // Verificar firma LASF
        let sig = String(data: data.prefix(4), encoding: .ascii)!
        #expect(sig == "LASF")

        // Verificar versión 1.4
        #expect(data[24] == 1) // major
        #expect(data[25] == 4) // minor

        // WKT debe estar en el archivo. `data` es el .las binario completo
        // (cabecera + registros de puntos con doubles/int32) — casi con
        // certeza contiene bytes con el bit alto encendido, así que
        // `String(data:encoding:.ascii)` sobre el archivo entero devuelve
        // nil (Foundation decodifica todo o nada) y la aserción quedaba sin
        // relación alguna con si el VLR WKT estaba bien escrito. Se busca la
        // subcadena directamente en los bytes crudos.
        #expect(containsASCIISubstring("WGS 84", in: data) || containsASCIISubstring("UTM zone", in: data))
    }
}

@Suite("F12 Export: GeoJSONWriter")
struct GeoJSONWriterTests {

    @Test("GeoJSON contiene FeatureCollection con CRS EPSG")
    func geoJSONHasCRS() throws {
        let metadata = try sampleMetadata()
        let writer = GeoJSONWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try writer.write(metadata: metadata, to: dir.appendingPathComponent("test.geojson"))
        let content = try String(contentsOf: r.fileURL)

        #expect(content.contains("FeatureCollection"))
        #expect(content.contains("EPSG"))
        #expect(content.contains("32719"))
    }

    @Test("Perfil degraded redondea coordenadas a 100 m")
    func degradedProfileRoundsCoordinates() throws {
        var metadata = try sampleMetadata()
        // Coordenada deliberadamente NO redonda: si el redondeo a 100 m no
        // ocurriera, el valor exportado sería distinto del esperado. Con una
        // entrada ya múltiplo de 100 (como usaba sampleMetadata() antes) el
        // test no podía distinguir "se redondeó" de "no se redondeó nada".
        metadata.utm = try UTMCoordinate(
            easting: 350_147.32, northing: 6_300_083.71, ellipsoidalHeight: 500,
            zone: 19, isNorthernHemisphere: false, epsg: 32719, datum: "WGS84"
        )
        metadata.precisionProfile = .degraded
        let writer = GeoJSONWriter()

        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try writer.write(metadata: metadata, to: dir.appendingPathComponent("degraded.geojson"))
        let content = try String(contentsOf: r.fileURL)

        // 350147.32 → 350100 (múltiplo de 100 más cercano); 6300083.71 → 6300100
        #expect(content.contains("350100"), "Easting debe redondearse a 350100, contenido: \(content)")
        #expect(content.contains("6300100"), "Northing debe redondearse a 6300100, contenido: \(content)")
        #expect(!content.contains("350147"), "No debe quedar la coordenada exacta sin redondear")
    }
}

@Suite("F12 Export: CSVWriter")
struct CSVWriterTests {

    @Test("CSV contiene cabecera y una fila por espécimen")
    func csvHeaderAndRows() throws {
        let metadata = try sampleMetadata()
        let box = try OrientedBox(center: SIMD3(0.5, 0.5, 0.5), axes: Matrix3x3.identity, halfExtents: SIMD3(0.1, 0.2, 0.3))
        let specimen = Specimen(scanID: UUID(), label: "Fémur", pose: box,
                                exposedVolume: 0.002, estimatedTotalVolume: 0.004,
                                volumeEstimationMethod: "closedMesh")

        let writer = CSVWriter()
        let dir = tempExportDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let r = try writer.write(specimens: [specimen], measurements: [], metadata: metadata, to: dir.appendingPathComponent("test.csv"))
        let content = try String(contentsOf: r.fileURL)

        #expect(content.contains("specimen_id,label,center_x"))
        #expect(content.contains("Fémur"))
        #expect(content.contains("0.002"))
        #expect(content.contains("0.004"))
    }
}

@Suite("F12 Export: RecordSidecar")
struct RecordSidecarTests {

    @Test("Sidecar contiene todos los campos obligatorios")
    func sidecarObligatoryFields() throws {
        let metadata = try sampleMetadata()
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "ply")

        #expect(sidecar.schemaVersion == 1)
        #expect(!sidecar.appVersion.isEmpty)
        #expect(!sidecar.buildID.isEmpty)
        #expect(!sidecar.device.model.isEmpty)
        #expect(sidecar.geo.utm?.epsg == 32719)
        #expect(!sidecar.disclaimer.isEmpty)
        #expect(sidecar.authorship.name == "Test")
    }

    @Test("Sidecar con UTM nil conserva el campo opcional")
    func sidecarWithoutUTMKeepsOptional() throws {
        let author = AuthorIdentity(name: "T", role: "R", institution: "I")
        let finding = Finding(siteID: UUID(), title: "F", expeditionCode: "E", author: author)
        let metadata = ExportMetadata(finding: finding, scan: nil, utm: nil, scaleUnits: nil)

        // El sidecar debe poder construirse sin UTM (la georreferencia es opcional
        // en el formato; el disclaimer legal ya declara su alcance).
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "ply")
        #expect(sidecar.geo.utm == nil)
        #expect(!sidecar.disclaimer.isEmpty)
    }

    @Test("Sidecar es byte-determinista")
    func sidecarByteDeterminism() throws {
        let metadata = try sampleMetadata()
        let s1 = try RecordSidecarBuilder.build(metadata: metadata, format: "ply")
        let s2 = try RecordSidecarBuilder.build(metadata: metadata, format: "ply")

        let encoder = CanonicalJSONEncoder()
        let d1 = try encoder.encode(s1)
        let d2 = try encoder.encode(s2)
        #expect(d1 == d2, "Sidecar debe ser byte-determinista")
    }

    @Test("Disclaimer legal fijo está presente")
    func disclaimerPresent() throws {
        let metadata = try sampleMetadata()
        let sidecar = try RecordSidecarBuilder.build(metadata: metadata, format: "ply")
        #expect(sidecar.disclaimer.contains("no constituye un levantamiento geodésico"))
        #expect(sidecar.disclaimer.contains("GPS"))
    }
}

extension Data {
    func loadUnaligned<T>(as type: T.Type, fromByteOffset offset: Int) -> T {
        return self.withUnsafeBytes { $0.load(fromByteOffset: offset, as: type) }
    }
}