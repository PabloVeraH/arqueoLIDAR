import Testing
import Foundation
import Domain
import Mesh
import Volume
import Segmentation
import Geo
import Registration
import Custody
import Persistence
import Export
import Crypto

// ═══════════════════════════════════════════════════════════════════════════════
// Integración — el pipeline completo sin UI/ARKit (mesh → volumen →
// segmentación → custodia → export), tal como exige la regla general del
// plan de que "ninguna fase algorítmica se declara terminada contra datos
// reales" (§3) y el propósito del target IntegrationTests en Package.swift
// (depende de los 11 módulos puros). Antes de esto el target solo contenía
// un comentario (fixes.md).
// ═══════════════════════════════════════════════════════════════════════════════

func tempIntegrationDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("integration-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Cubo sintético con volumen analítico conocido, usado en varias pruebas.
func synthCube(size: Float) -> Mesh {
    synthBox(sx: size, sy: size, sz: size)
}

/// Caja rectangular con dimensiones distintas por eje — a diferencia de un
/// cubo perfecto, no tiene ejes principales ambiguos para el ajuste de OBB
/// por PCA (un cubo tiene varianza igual en las 3 direcciones, así que sus
/// autovectores no están únicamente determinados y el OBB resultante puede
/// no alinearse con sus caras).
func synthBox(sx: Float, sy: Float, sz: Float) -> Mesh {
    let hx = sx / 2, hy = sy / 2, hz = sz / 2
    let v: [SIMD3<Float>] = [
        SIMD3(-hx, -hy, -hz), SIMD3(hx, -hy, -hz), SIMD3(hx, hy, -hz), SIMD3(-hx, hy, -hz),
        SIMD3(-hx, -hy, hz), SIMD3(hx, -hy, hz), SIMD3(hx, hy, hz), SIMD3(-hx, hy, hz),
    ]
    let idx: [UInt32] = [
        0, 2, 1, 0, 3, 2, // -z
        4, 5, 6, 4, 6, 7, // +z
        0, 1, 5, 0, 5, 4, // -y
        3, 7, 6, 3, 6, 2, // +y
        0, 4, 7, 0, 7, 3, // -x
        1, 2, 6, 1, 6, 5, // +x
    ]
    return Mesh(vertices: v, indices: idx)
}

@Suite("Integración: captura → persistencia → custodia → export")
struct FindingLifecycleIntegrationTests {

    @Test("Un hallazgo completo: guardar escaneo, sellar, verificar y exportar")
    func fullLifecycle() async throws {
        let base = tempIntegrationDir()
        defer { try? FileManager.default.removeItem(at: base) }

        // 1. Persistencia: crear el expediente y guardar la malla del escaneo.
        let store = FindingStore(baseURL: base)
        let author = AuthorIdentity(name: "P. Pérez", role: "Arqueólogo", institution: "MNHN")
        let finding = Finding(siteID: UUID(), title: "Hallazgo de integración", expeditionCode: "INT-1", author: author)
        let findingDir = try await store.createFinding(finding)

        let mesh = synthCube(size: 0.3)
        let scan = ScanSession(findingID: finding.findingID, purpose: .baseline)
        _ = try await store.appendScan(scan, mesh: mesh, to: finding.findingID)

        // El bundle en disco es la fuente de verdad legal (plan §2.B): la
        // malla debe poder recargarse exactamente igual desde el mismo
        // archivo que la escribió, no solo existir.
        let reloaded = try await store.loadMesh(scanID: scan.scanID, findingID: finding.findingID)
        #expect(reloaded == mesh, "La malla recargada debe ser idéntica a la guardada")

        // 2. Custodia: sellar el expediente completo y verificarlo.
        let scanDir = findingDir.appendingPathComponent("scans/\(scan.scanID.uuidString)")
        let sealsDir = findingDir.appendingPathComponent("seals")
        try FileManager.default.createDirectory(at: sealsDir, withIntermediateDirectories: true)

        let key = SoftwareSigningKey()
        let signer = SealSigner()
        let seal = try await signer.seal(bundleAt: findingDir, author: author, geo: nil, previousSeal: nil, key: key)

        let encoder = CanonicalJSONEncoder()
        let chainPath = sealsDir.appendingPathComponent("chain.jsonl")
        try encoder.encode(seal).write(to: chainPath)

        let verifier = ChainVerifier()
        let verdictIntact = try await verifier.verify(bundleAt: findingDir)
        #expect(verdictIntact.isValid, "Un expediente recién sellado, sin manipular, debe verificar en verde")

        // La cadena de custodia debe seguir detectando manipulación después
        // del ciclo completo (no solo en aislamiento, como en CustodyTests).
        var meshData = try Data(contentsOf: scanDir.appendingPathComponent("mesh.ply"))
        meshData[meshData.count - 1] ^= 0xFF
        try meshData.write(to: scanDir.appendingPathComponent("mesh.ply"))

        let verdictTampered = try await verifier.verify(bundleAt: findingDir)
        #expect(!verdictTampered.isValid, "Un mesh.ply alterado después del sello debe fallar la verificación")

        // 3. Export: PLY + sidecar record.json obligatorio (plan §2.D).
        let exportsDir = findingDir.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let metadata = ExportMetadata(finding: finding, scan: scan, utm: nil, scaleUnits: nil)
        let plyResult = try PLYWriter().write(mesh: mesh, metadata: metadata, to: exportsDir.appendingPathComponent("hallazgo.ply"))

        #expect(FileManager.default.fileExists(atPath: plyResult.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: plyResult.recordURL.path))
        let sidecarData = try Data(contentsOf: plyResult.recordURL)
        let sidecar = try CanonicalDateCoding.decoder().decode(RecordSidecar.self, from: sidecarData)
        #expect(!sidecar.disclaimer.isEmpty, "El sidecar debe llevar el disclaimer legal fijo")
    }
}

@Suite("Integración: segmentación multi-especimen → volumen → inventario")
struct SegmentationVolumeIntegrationTests {

    @Test("Segmentar un espécimen y calcular su volumen y caja orientada")
    func segmentAndMeasure() throws {
        // Caja con dimensiones distintas por eje, no un cubo perfecto: un
        // cubo tiene varianza igual en las 3 direcciones, así que el ajuste
        // de OBB por PCA no tiene ejes principales únicos y puede devolver
        // una caja rotada 45° que no se ciñe a sus caras (más grande que el
        // volumen real) — una caja asimétrica evita esa ambigüedad.
        let specimen = synthBox(sx: 0.4, sy: 0.25, sz: 0.15)
        let segmenter = MeshSegmenter()
        // minComponentSize por defecto es 50 (pensado para mallas densas de
        // escaneo real); esta caja sintética mínima tiene solo 8 vértices.
        // maxDihedralAngleDegrees por defecto es 45°: las caras de una caja
        // se encuentran en ángulos de 90°, así que con el valor por defecto
        // cada cara queda en su propio componente (comportamiento correcto
        // para separar parches de superficie reales — una caja de bordes
        // filosos es la forma equivocada para probar "un solo espécimen
        // conectado"). Se sube el ángulo para tratarla como una sola pieza.
        let options = SegmentationOptions(maxDihedralAngleDegrees: 180, minComponentSize: 8)
        let components = try segmenter.segment(mesh: specimen, roi: nil, removingPlane: nil, options: options)

        let firstComponent = try #require(components.first, "Debe encontrar al menos un componente")
        let box = firstComponent.box
        // Prueba de integración, no de precisión — GeometryTests ya cubre
        // la exactitud del ajuste de OBB con tolerancias finas. Aquí solo se
        // verifica que el pipeline completo (segmentar → ajustar caja →
        // derivar volumen) entrega un resultado no degenerado y del orden
        // de magnitud correcto (real: 0.4×0.25×0.15 = 0.015 m³).
        let boxVolume = Double(box.dimensions.x * box.dimensions.y * box.dimensions.z)
        #expect(boxVolume > 0.005 && boxVolume < 0.05, "Volumen de la caja (\(boxVolume) m³) fuera del orden de magnitud esperado (~0.015 m³)")
    }
}

@Suite("Integración: dos campañas → registro → diff de volumen")
struct RegistrationDiffIntegrationTests {

    @Test("Monitoreo: un montículo nuevo entre dos escaneos produce volumen ganado")
    func monitoringDetectsGain() throws {
        // Baseline: piso plano.
        var baseVerts: [SIMD3<Float>] = []
        var baseIdx: [UInt32] = []
        let n = 12
        for j in 0...n {
            for i in 0...n {
                baseVerts.append(SIMD3((Float(i) / Float(n) - 0.5) * 2.0, 0, (Float(j) / Float(n) - 0.5) * 2.0))
            }
        }
        for j in 0..<n {
            for i in 0..<n {
                let a = UInt32(j * (n + 1) + i), b = a + 1
                let c = UInt32((j + 1) * (n + 1) + i), d = c + 1
                baseIdx.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        let baseline = Mesh(vertices: baseVerts, indices: baseIdx)

        // Campaña posterior: aparece un montículo localizado (material nuevo).
        var currentVerts = baseVerts
        for i in 0..<currentVerts.count {
            let d = vecLength(currentVerts[i] - SIMD3(0, 0, 0))
            if d < 0.3 {
                currentVerts[i].y += 0.15 * (1.0 - d / 0.3)
            }
        }
        let current = Mesh(vertices: currentVerts, indices: baseIdx)

        // Alineación ya conocida (ambos escaneos comparten marco de sitio) —
        // el foco de esta prueba es el diff, no el registro en sí (F11 ya
        // tiene su propia cobertura dedicada en RegistrationTests).
        let alignment = AlignmentResult(
            transform: Matrix4x4.identity, rmse: 0.002, inlierRatio: 0.98, iterations: 1,
            conditionNumber: 50, isDegenerate: false, initializationMethod: .controlTargets
        )

        let diff = try DiffEngine().diff(baseline: baseline, current: current, alignment: alignment, cellSize: 0.05)
        #expect(diff.gainedVolume > 0, "El montículo nuevo debe registrarse como volumen ganado")
        #expect(diff.lostVolume < diff.gainedVolume, "No debería reportarse pérdida significativa donde solo hubo ganancia")
    }
}
