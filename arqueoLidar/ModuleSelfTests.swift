import Foundation
import Domain
import Geometry
import Mesh
import Volume
import Stratigraphy
import Segmentation
import Geo
import Registration
import Custody
import Persistence
import Export

// ═══════════════════════════════════════════════════════════════════════════════
// Autodiagnóstico en el dispositivo: cada módulo de PaleoRegistro se ejecuta
// con los mismos escenarios sintéticos (verdad analítica conocida) que usan
// sus tests unitarios en PaleoRegistro/Tests. Así se puede comprobar en el
// iPhone que el código realmente corre y da resultados correctos.
// ═══════════════════════════════════════════════════════════════════════════════

nonisolated struct SelfCheck: Sendable, Identifiable {
    let id = UUID()
    let name: String
    let passed: Bool
    let detail: String
}

nonisolated enum PaleoModule: String, CaseIterable, Sendable, Identifiable {
    case domain = "Domain"
    case geometry = "Geometry"
    case mesh = "Mesh"
    case volume = "Volume"
    case stratigraphy = "Stratigraphy"
    case segmentation = "Segmentation"
    case geo = "Geo"
    case registration = "Registration"
    case custody = "Custody"
    case persistence = "Persistence"
    case export = "Export"

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .domain: "Tipos base, validaciones y matemática"
        case .geometry: "Ajuste de planos (RANSAC) y cajas orientadas"
        case .mesh: "Mallas: cierre, componentes, codec PLY"
        case .volume: "Integración de volúmenes"
        case .stratigraphy: "Perfil de pared y potencia de estratos"
        case .segmentation: "Separación de especímenes y relaciones"
        case .geo: "UTM y calidad de fijaciones GPS"
        case .registration: "ICP y diferencias entre escaneos"
        case .custody: "Sellos firmados y cadena de custodia"
        case .persistence: "Expedientes en disco y JSON canónico"
        case .export: "PLY, STL, OBJ, LAS, GeoJSON y CSV"
        }
    }

    /// Ejecuta las pruebas del módulo. Nunca lanza: cualquier error se
    /// reporta como una verificación fallida con su descripción.
    func run() async -> [SelfCheck] {
        var r = CheckRecorder()
        switch self {
        case .domain: SelfTests.domain(&r)
        case .geometry: SelfTests.geometry(&r)
        case .mesh: SelfTests.mesh(&r)
        case .volume: SelfTests.volume(&r)
        case .stratigraphy: SelfTests.stratigraphy(&r)
        case .segmentation: SelfTests.segmentation(&r)
        case .geo: SelfTests.geo(&r)
        case .registration: SelfTests.registration(&r)
        case .custody: await SelfTests.custody(&r)
        case .persistence: await SelfTests.persistence(&r)
        case .export: SelfTests.export(&r)
        }
        return r.checks
    }
}

nonisolated struct CheckRecorder {
    var checks: [SelfCheck] = []

    mutating func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
        checks.append(SelfCheck(name: name, passed: ok, detail: detail))
    }

    mutating func fail(_ name: String, _ error: any Error) {
        checks.append(SelfCheck(name: name, passed: false, detail: "Error: \(error)"))
    }
}

private nonisolated func fmt(_ v: Double, _ digits: Int = 4) -> String { String(format: "%.\(digits)f", v) }
private nonisolated func fmt(_ v: Float, _ digits: Int = 4) -> String { fmt(Double(v), digits) }

nonisolated enum SelfTests {

    // MARK: - Domain

    static func domain(_ r: inout CheckRecorder) {
        do {
            let p = try Plane(point: .zero, normal: SIMD3(0, 2, 0))
            r.expect("Plane normaliza su normal", abs(vecLength(p.normal) - 1) < 1e-6,
                     "|n| = \(fmt(vecLength(p.normal), 6))")
        } catch { r.fail("Plane normaliza su normal", error) }

        do {
            _ = try Plane(point: .zero, normal: .zero)
            r.expect("Plane rechaza normal nula", false, "No lanzó error")
        } catch {
            r.expect("Plane rechaza normal nula", true, "Error tipado: \(error)")
        }

        do {
            _ = try OrientedBox(center: .zero, axes: .identity, halfExtents: SIMD3(-1, 1, 1))
            r.expect("OrientedBox rechaza semieje negativo", false, "No lanzó error")
        } catch {
            r.expect("OrientedBox rechaza semieje negativo", true, "Error tipado: \(error)")
        }

        let v = VolumeResult(positive: 2.5, negative: 0.75, coveredArea: 1, filledCellRatio: 1,
                             uncertainty: 0, method: .closedMesh, isInferred: false, algorithmVersion: "t")
        r.expect("VolumeResult: net = positivo − negativo", abs(v.net - 1.75) < 1e-12, "net = \(v.net)")

        let t = Matrix4x4(translation: SIMD3(1, 2, 3), quaternion: .identity)
        let moved = t.applyAffine(SIMD3(1, 1, 1))
        r.expect("Matrix4x4 aplica traslación", vecLength(moved - SIMD3(2, 3, 4)) < 1e-6,
                 "(1,1,1) → (\(fmt(moved.x, 2)), \(fmt(moved.y, 2)), \(fmt(moved.z, 2)))")

        var a = SplitMix64(seed: 7), b = SplitMix64(seed: 7)
        r.expect("SplitMix64 determinista", a.next() == b.next())

        do {
            let author = AuthorIdentity(name: "Test", role: "Arqueólogo", institution: "MNHN")
            let f = Finding(siteID: UUID(), title: "Hallazgo", expeditionCode: "EXP-1", author: author)
            let data = try JSONEncoder().encode(f)
            let back = try JSONDecoder().decode(Finding.self, from: data)
            r.expect("Finding: round-trip Codable", back == f, "\(data.count) bytes")
        } catch { r.fail("Finding: round-trip Codable", error) }
    }

    // MARK: - Geometry

    static func geometry(_ r: inout CheckRecorder) {
        let trueNormal = vecNormalize(SIMD3<Float>(0.3, 0.9, 0.2))
        let main = Fx.planePoints(center: SIMD3(0, 1, 0), normal: trueNormal, uExtent: 3, vExtent: 3,
                                  count: 800, noiseSigma: 0.002, seed: 5)
        let outliers = Fx.planePoints(center: SIMD3(0, -2, 0), normal: SIMD3(0, 0, 1), uExtent: 2, vExtent: 2,
                                      count: 200, noiseSigma: 0.002, seed: 9)
        do {
            let plane = try RANSACPlaneFitter().fit(
                points: main + outliers, normals: nil,
                options: PlaneFitOptions(maxIterations: 4000, inlierDistance: 0.01, minInliers: 300,
                                         constraint: .nearNormal(trueNormal, toleranceDegrees: 8),
                                         scoring: .msac, rngSeed: 99))
            let angle = acos(min(1, abs(vecDot(plane.normal, trueNormal)))) * 180 / .pi
            let offset = abs(vecDot(plane.point - SIMD3(0, 1, 0), trueNormal))
            r.expect("RANSAC: plano inclinado con 20% de outliers", angle < 0.5 && offset < 0.005,
                     "error angular \(fmt(angle, 3))° (máx 0.5°), desplazamiento \(fmt(offset * 1000, 2)) mm (máx 5 mm)")
        } catch { r.fail("RANSAC: plano inclinado con 20% de outliers", error) }

        do {
            let half = SIMD3<Float>(0.15, 0.10, 0.05)
            let pts = Fx.rotate(Fx.boxPoints(half: half, perEdge: 6), yaw: 37, pitch: 12)
            let obb = try PCAOBBFitter().fit(points: pts, gravityAlignedUpAxis: false)
            let dims = [obb.halfExtents.x * 2, obb.halfExtents.y * 2, obb.halfExtents.z * 2].sorted()
            let expected: [Float] = [0.10, 0.20, 0.30]
            let maxErr = zip(dims, expected).map { abs($0 - $1) }.max() ?? 1
            r.expect("OBB: caja 30×20×10 cm rotada", maxErr < 0.001,
                     "medida \(dims.map { fmt($0 * 100, 2) }.joined(separator: " × ")) cm, error máx \(fmt(maxErr * 1000, 3)) mm")
        } catch { r.fail("OBB: caja 30×20×10 cm rotada", error) }
    }

    // MARK: - Mesh

    static func mesh(_ r: inout CheckRecorder) {
        let ops = MeshOps()

        var two = Fx.sphere(radius: 0.3)
        let s2 = Fx.sphere(radius: 0.3)
        let off = UInt32(two.vertices.count)
        two.vertices += s2.vertices.map { $0 + SIMD3<Float>(2, 0, 0) }
        two.indices += s2.indices.map { $0 + off }
        let comps = ops.connectedComponents(two)
        r.expect("Componentes conexas: dos esferas → 2", comps.count == 2, "encontradas: \(comps.count)")

        let sphere = Fx.sphere(radius: 0.5, latDiv: 24, lonDiv: 48)
        let w = ops.watertightness(sphere)
        r.expect("Esfera es estanca (watertight)", w.isWatertight && w.eulerCharacteristic == 2,
                 "bordes abiertos \(w.boundaryEdges), χ = \(w.eulerCharacteristic)")

        do {
            let radius: Float = 0.5
            let open = Fx.openUpperHemisphere(radius: radius, latDiv: 24, lonDiv: 48)
            let (closed, report) = try MeshCloser().close(mesh: open, against: nil)
            let vol = Fx.closedVolume(closed)
            let expected = 2.0 / 3.0 * Double.pi * pow(Double(radius), 3)
            let err = abs(vol - expected) / expected
            r.expect("MeshCloser: cierra hemisferio abierto", report.isWatertight && err < 0.01,
                     "volumen \(fmt(vol)) m³ vs \(fmt(expected)) m³ (error \(fmt(err * 100, 2))%)")
        } catch { r.fail("MeshCloser: cierra hemisferio abierto", error) }

        do {
            let m = Fx.sphere(radius: 0.2, latDiv: 8, lonDiv: 12)
            let data = PLYCodec.encode(m)
            let back = try PLYCodec.decode(data)
            r.expect("PLY: encode → decode idéntico", back == m, "\(data.count) bytes, \(m.triangleCount) triángulos")
        } catch { r.fail("PLY: encode → decode idéntico", error) }

        do {
            _ = try PLYCodec.decode(Data("no es un ply".utf8))
            r.expect("PLY: rechaza datos inválidos", false, "No lanzó error")
        } catch {
            r.expect("PLY: rechaza datos inválidos", true, "Error tipado: \(error)")
        }
    }

    // MARK: - Volume

    static func volume(_ r: inout CheckRecorder) {
        do {
            let mesh = Fx.cone(radius: 1, height: 1, rings: 24, segments: 384)
            let ref = ReferenceSurface.plane(try Plane(point: .zero, normal: SIMD3(0, 1, 0)))
            let res = try SignedHeightFieldIntegrator().integrate(mesh: mesh, reference: ref, cellSize: 0.0125, emptyCells: .ignore)
            let truth = Double.pi / 3
            let err = abs(res.positive - truth) / truth
            r.expect("Height field: cono R=1 H=1", err < 0.02,
                     "\(fmt(res.positive)) m³ vs π/3 = \(fmt(truth)) m³ (error \(fmt(err * 100, 2))%, máx 2%)")
        } catch { r.fail("Height field: cono R=1 H=1", error) }

        do {
            let mesh = Fx.sphere(radius: 0.5, latDiv: 64, lonDiv: 128)
            let res = try ClosedMeshIntegrator().integrate(mesh: mesh, reference: .closedSolid, cellSize: 0, emptyCells: .ignore)
            let truth = 4.0 / 3.0 * Double.pi * 0.125
            let err = abs(res.positive - truth) / truth
            r.expect("Malla cerrada: esfera r=0.5", err < 0.01,
                     "\(fmt(res.positive)) m³ vs \(fmt(truth)) m³ (error \(fmt(err * 100, 2))%, máx 1%)")
        } catch { r.fail("Malla cerrada: esfera r=0.5", error) }

        do {
            let open = Fx.openUpperHemisphere(radius: 0.5, latDiv: 16, lonDiv: 24)
            _ = try ClosedMeshIntegrator().integrate(mesh: open, reference: .closedSolid, cellSize: 0, emptyCells: .ignore)
            r.expect("Malla no estanca es rechazada", false, "No lanzó error")
        } catch {
            r.expect("Malla no estanca es rechazada", true, "Error tipado: \(error)")
        }

        let routingOK = VolumePolicy.route(for: .baseline) == .heightField
            && VolumePolicy.route(for: .damageAssessment) == .cavity
            && VolumePolicy.route(for: .specimenInventory) == .closedMesh
        r.expect("Enrutador: propósito → integrador", routingOK)
    }

    // MARK: - Stratigraphy

    static func stratigraphy(_ r: inout CheckRecorder) {
        let name = "Potencia real 12 cm en pared ⊥ al rumbo"
        do {
            let dip: Float = 25, dipDir: Float = 130
            let n_s = Fx.stratumNormal(dip: dip, dipDirection: dipDir)
            let n_w = Fx.horizontalUnit(azimuth: dipDir)
            let p_w = SIMD3<Float>(0, 0.5, 0)
            let wall = Fx.wallPoints(center: p_w, n_w: n_w, width: 1.5, height: 1.0, gridU: 60, gridV: 40)
            let profile = try WallProfileBuilder(resolution: 500).build(points: wall)

            let t: Float = 0.12
            let lines = [p_w + n_s * t, p_w, p_w - n_s * t].map {
                Fx.boundaryLine(n_s: n_s, p_s: $0, n_w: n_w, p_w: p_w, extHalf: 0.6, sampleCount: 5)
            }
            let rect = Rectifier(resolution: profile.orthoImage.resolution)
            var marks: [PixelMark] = []
            for line in lines {
                let id = UUID()
                for p in line {
                    if let px = rect.pixel(for: p, in: profile.orthoImage) {
                        marks.append(PixelMark(boundaryID: id, col: px.0, row: px.1))
                    }
                }
            }
            let boundaries = try StratumBoundaryPicker().pick(marks: marks, in: profile.orthoImage)
            let stratumPlane = try Plane(point: p_w, normal: n_s)
            let results = try ThicknessCalculator().measure(
                boundaries: boundaries, wallPlane: profile.plane,
                stratumPlane: stratumPlane, pixelResolution: profile.orthoImage.resolution)

            let ok = results.count == 2 && results.allSatisfy {
                abs($0.trueThickness - 0.12) < 0.002 && abs($0.apparentThickness - 0.132) < 0.005 && abs($0.dip - dip) < 1
            }
            let txt = results.map {
                "real \(fmt($0.trueThickness * 100, 2)) cm, aparente \(fmt($0.apparentThickness * 100, 2)) cm, manteo \(fmt($0.dip, 1))°"
            }.joined(separator: "\n")
            r.expect(name, ok, txt.isEmpty ? "sin resultados" : txt + "\n(esperado: real 12 cm, aparente ≈13.2 cm, manteo 25°)")
        } catch { r.fail(name, error) }
    }

    // MARK: - Segmentation

    static func segmentation(_ r: inout CheckRecorder) {
        do {
            let plane = Fx.planeMesh(size: 4)
            let specimens = [
                Fx.ellipsoid(center: SIMD3(-1.0, 0.15, -1.0), radii: SIMD3(0.1, 0.15, 0.08)),
                Fx.ellipsoid(center: SIMD3(1.0, 0.12, -0.5), radii: SIMD3(0.08, 0.12, 0.1)),
                Fx.ellipsoid(center: SIMD3(0.0, 0.18, 1.0), radii: SIMD3(0.12, 0.18, 0.06)),
                Fx.ellipsoid(center: SIMD3(-1.5, 0.10, 0.5), radii: SIMD3(0.06, 0.10, 0.08)),
                Fx.ellipsoid(center: SIMD3(1.5, 0.14, -1.5), radii: SIMD3(0.09, 0.14, 0.07)),
            ]
            let comps = try MeshSegmenter().segment(
                mesh: Fx.merge([plane] + specimens), roi: nil,
                removingPlane: try Plane(point: .zero, normal: SIMD3(0, 1, 0)),
                options: SegmentationOptions(maxDihedralAngleDegrees: 45, maxDistance: 0.03, minComponentSize: 20))
            r.expect("5 especímenes sobre un plano → 5 componentes", comps.count >= 5, "encontrados: \(comps.count)")
        } catch { r.fail("5 especímenes sobre un plano → 5 componentes", error) }

        do {
            let ids = [UUID(), UUID(), UUID()]
            let boxes: [(id: UUID, box: OrientedBox)] = [
                (ids[0], try OrientedBox(center: SIMD3(0, 0, 0), axes: .identity, halfExtents: SIMD3(repeating: 0.1))),
                (ids[1], try OrientedBox(center: SIMD3(1, 0, 0), axes: .identity, halfExtents: SIMD3(repeating: 0.1))),
                (ids[2], try OrientedBox(center: SIMD3(0.5, 0, 0.866), axes: .identity, halfExtents: SIMD3(repeating: 0.1))),
            ]
            let rel = SpatialRelationBuilder().buildRelations(specimens: boxes, contactThreshold: 0.01)
            let d01 = rel.first { $0.kind == .distance && $0.fromID == ids[0] && $0.toID == ids[1] }
            let ok = rel.filter { $0.kind == .distance }.count == 3 && abs((d01?.value ?? 0) - 1.0) < 0.01
            r.expect("Relaciones espaciales entre 3 especímenes", ok,
                     "\(rel.count) relaciones; distancia 0↔1 = \(fmt(d01?.value ?? .nan, 3)) m (esperado 1.000)")
        } catch { r.fail("Relaciones espaciales entre 3 especímenes", error) }
    }

    // MARK: - Geo

    static func geo(_ r: inout CheckRecorder) {
        let conv = UTMConverter()
        // Puntos de control calculados con pyproj (EPSG:32719), mismos que GeoTests.
        let control: [(lat: Double, lon: Double, e: Double, n: Double)] = [
            (-53.16000, -70.91667, 371_854.2814, 4_108_214.9013),
            (-53.00000, -68.00000, 567_109.4354, 4_127_261.7386),
            (-52.50000, -71.50000, 330_306.2303, 4_180_410.0708),
        ]
        do {
            var maxErr = 0.0
            for c in control {
                let u = try conv.toUTM(latitude: c.lat, longitude: c.lon)
                maxErr = max(maxErr, abs(u.easting - c.e), abs(u.northing - c.n))
            }
            r.expect("UTM 19S vs puntos de control pyproj", maxErr < 0.001, "error máx \(fmt(maxErr * 1000, 4)) mm (máx 1 mm)")
        } catch { r.fail("UTM 19S vs puntos de control pyproj", error) }

        do {
            var maxErr = 0.0
            for (lat, lon) in [(-22.9087, -68.1997), (-33.4489, -70.6693), (-41.4693, -72.9424), (-27.1127, -109.3497)] {
                let u = try conv.toUTM(latitude: lat, longitude: lon)
                let g = try conv.toGeodetic(u)
                let back = try conv.toUTM(latitude: g.lat, longitude: g.lon)
                maxErr = max(maxErr, abs(back.easting - u.easting), abs(back.northing - u.northing))
            }
            r.expect("UTM ida y vuelta (Calama, Santiago, Pto. Montt, Rapa Nui)", maxErr < 0.0001,
                     "error máx \(fmt(maxErr * 1000, 5)) mm (máx 0.1 mm)")
        } catch { r.fail("UTM ida y vuelta", error) }

        do {
            let good = try GeoFix(latitude: -33.4, longitude: -70.6, altitude: 500, horizontalAccuracy: 4.2,
                                  verticalAccuracy: 8, timestamp: Date(), source: .coreLocation)
            let bad = try GeoFix(latitude: -33.4, longitude: -70.6, altitude: 500, horizontalAccuracy: 25,
                                 verticalAccuracy: 40, timestamp: Date(), source: .coreLocation)
            let v1 = FixQualityGate(maxHorizontalAccuracy: 10).evaluate(burst: [good])
            let v2 = FixQualityGate(maxHorizontalAccuracy: 5).evaluate(burst: [bad])
            r.expect("Calidad GPS: acepta fijación precisa", v1.acceptedCount == 1 && v1.quality == .good,
                     "±4.2 m → \(v1.quality.rawValue)")
            r.expect("Calidad GPS: rechaza fijación imprecisa", v2.rejectedCount == 1 && v2.quality == .degraded,
                     "±25 m → \(v2.quality.rawValue)")
        } catch { r.fail("Calidad GPS", error) }
    }

    // MARK: - Registration

    static func registration(_ r: inout CheckRecorder) {
        let ops = MeshOps()
        do {
            let raw = Fx.planeMesh(size: 3, divisions: 10)
            let normals = ops.computeVertexNormals(raw).map { vecNormalize($0) }
            let plane = Mesh(vertices: raw.vertices, indices: raw.indices, normals: normals)
            let shift = Fx.rigid(yawDeg: 1.5, translation: SIMD3(0.02, 0, 0))
            let shifted = Mesh(vertices: plane.vertices.map { shift.applyAffine($0) }, indices: plane.indices,
                               normals: normals.map { shift.rotation3x3 * $0 })
            _ = try ICPAligner().align(source: shifted, target: plane, initial: .identity,
                                       options: ICPOptions())
            r.expect("ICP rechaza escena degenerada (un solo plano)", false, "Alineó sin detectar degeneración")
        } catch {
            if case .degenerate(let cond, _)? = error as? RegistrationError {
                r.expect("ICP rechaza escena degenerada (un solo plano)", true, "número de condición \(fmt(cond, 1))")
            } else { r.fail("ICP rechaza escena degenerada (un solo plano)", error) }
        }

        do {
            let mesh = Fx.denseCube(size: 0.5, divisions: 8)
            let truth = Fx.rigid(yawDeg: 12.7, pitchDeg: 5.3, rollDeg: -3.1, translation: SIMD3(0.85, 0.12, -0.34))
            let baseNormals = ops.computeVertexNormals(mesh).map { vecNormalize($0) }
            let source = Mesh(vertices: Fx.addNoise(mesh.vertices, sigma: 0.003), indices: mesh.indices, normals: baseNormals)
            let target = Mesh(vertices: mesh.vertices.map { truth.applyAffine($0) }, indices: mesh.indices,
                              normals: baseNormals.map { truth.rotation3x3 * $0 })
            let initial = Fx.rigid(yawDeg: 15.7, pitchDeg: 4.3, rollDeg: -2.1, translation: SIMD3(0.90, 0.10, -0.31))
            let res = try ICPAligner().align(source: source, target: target, initial: initial,
                                             options: ICPOptions(voxelSizes: [0.1, 0.05], maxIterations: 50))
            let err = vecLength(res.transform.translation - truth.translation)
            r.expect("ICP recupera transformación conocida", err < 0.005 && !res.isDegenerate,
                     "error de traslación \(fmt(err * 1000, 1)) mm (umbral: 5 mm, igual que RegistrationTests)")
        } catch { r.fail("ICP recupera transformación conocida", error) }

        do {
            let base = Fx.planeMesh(size: 1, divisions: 5)
            var raised = base.vertices
            for i in raised.indices where raised[i].x > 0 && raised[i].z > 0 { raised[i].y += 0.05 }
            let align = AlignmentResult(transform: .identity, rmse: 0.001, inlierRatio: 1, iterations: 1,
                                        conditionNumber: 100, isDegenerate: false, initializationMethod: .geodetic)
            let d = try DiffEngine().diff(baseline: base, current: Mesh(vertices: raised, indices: base.indices),
                                          alignment: align, cellSize: 0.1)
            r.expect("Diff detecta volumen ganado", d.gainedVolume > 0,
                     "ganado \(fmt(d.gainedVolume * 1e6, 0)) cm³, perdido \(fmt(d.lostVolume * 1e6, 0)) cm³")
        } catch { r.fail("Diff detecta volumen ganado", error) }
    }

    // MARK: - Custody

    static func custody(_ r: inout CheckRecorder) async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("selftest-custody-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: dir) }
        do {
            let scans = dir.appendingPathComponent("scans/test")
            let seals = dir.appendingPathComponent("seals")
            try fm.createDirectory(at: scans, withIntermediateDirectories: true)
            try fm.createDirectory(at: seals, withIntermediateDirectories: true)
            let meshURL = scans.appendingPathComponent("mesh.ply")
            try Data("original mesh".utf8).write(to: meshURL)

            let author = AuthorIdentity(name: "Prueba", role: "Arqueólogo", institution: "MNHN")
            let key = SoftwareSigningKey()
            let signer = SealSigner()
            let seal0 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: nil, key: key)
            r.expect("Sello inicial firmado", seal0.index == 0 && seal0.rootHash.count == 64 && !seal0.signatureDER.isEmpty,
                     "rootHash \(seal0.rootHash.prefix(16))…, firma \(seal0.signatureDER.count) bytes")

            let enc = CanonicalJSONEncoder()
            var chain = try enc.encode(seal0)
            chain.append(Data("\n".utf8))
            try Data("modified mesh v2".utf8).write(to: meshURL)
            let seal1 = try await signer.seal(bundleAt: dir, author: author, geo: nil, previousSeal: seal0, key: key,
                                              clock: Date().addingTimeInterval(3600))
            r.expect("Segundo sello encadena con el anterior", seal1.index == 1 && seal1.prevSealHash?.count == 64
                        && seal1.rootHash != seal0.rootHash)
            chain.append(try enc.encode(seal1))
            try chain.write(to: seals.appendingPathComponent("chain.jsonl"))

            let v = try await ChainVerifier().verify(bundleAt: dir)
            r.expect("Verificación de expediente íntegro", v.isValid, v.isValid ? "válido" : "\(v)")

            try Data("modified mesh v2 + manipulación".utf8).write(to: meshURL)
            let v2 = try await ChainVerifier().verify(bundleAt: dir)
            r.expect("Detecta archivo manipulado", !v2.isValid, v2.isValid ? "NO detectó la manipulación" : "manipulación detectada")
        } catch { r.fail("Cadena de custodia", error) }
    }

    // MARK: - Persistence

    static func persistence(_ r: inout CheckRecorder) async {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("selftest-store-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: base) }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let store = FindingStore(baseURL: base)
            let author = AuthorIdentity(name: "X", role: "Y", institution: "Z")
            let f1 = Finding(siteID: UUID(), title: "F1", expeditionCode: "E1", author: author)
            let f2 = Finding(siteID: UUID(), title: "F2", expeditionCode: "E2", author: author)
            _ = try await store.createFinding(f1)
            _ = try await store.createFinding(f2)
            let list = try await store.listFindings()
            r.expect("Crear y listar hallazgos", list.count == 2, "\(list.count) hallazgos")

            let mesh = Mesh(vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0.3, 0.6, -0.9)],
                            indices: [0, 1, 2, 1, 3, 2])
            let scan = ScanSession(findingID: f1.findingID, purpose: .baseline)
            _ = try await store.appendScan(scan, mesh: mesh, to: f1.findingID)
            let loaded = try await store.loadMesh(scanID: scan.scanID, findingID: f1.findingID)
            r.expect("Guardar escaneo y recuperar malla intacta", loaded == mesh)

            try await store.rebuildIndex()
            let after = try await store.listFindings()
            r.expect("Reconstruir índice desde disco", after.count == 2 && after.contains { $0.title == "F1" && $0.scanCount == 1 },
                     "\(after.count) hallazgos tras reconstruir")
        } catch { r.fail("Persistencia de expedientes", error) }

        do {
            let enc = CanonicalJSONEncoder()
            let a = try enc.encode(["b": 2, "a": 1, "c": 3])
            let b = try enc.encode(["c": 3, "a": 1, "b": 2])
            r.expect("JSON canónico independiente del orden", a == b, String(decoding: a, as: UTF8.self))
        } catch { r.fail("JSON canónico independiente del orden", error) }

        do {
            _ = try CanonicalJSONEncoder().encode(["x": Double.nan])
            r.expect("JSON canónico rechaza NaN", false, "Serializó NaN sin error")
        } catch {
            r.expect("JSON canónico rechaza NaN", true, "Error tipado: \(error)")
        }
    }

    // MARK: - Export

    static func export(_ r: inout CheckRecorder) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("selftest-export-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: dir) }
        let meta: ExportMetadata
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let author = AuthorIdentity(name: "Test", role: "Test", institution: "Test")
            let finding = Finding(siteID: UUID(), title: "Test Finding", expeditionCode: "EXP-TEST", author: author)
            let utm = try UTMCoordinate(easting: 350_000, northing: 6_300_000, ellipsoidalHeight: 500, zone: 19,
                                        isNorthernHemisphere: false, epsg: 32719, datum: "WGS84")
            meta = ExportMetadata(finding: finding, scan: nil, utm: utm, scaleUnits: nil)
        } catch { r.fail("Preparar exportación", error); return }

        let cube = Fx.exportCube()

        func file(_ name: String, _ body: (URL) throws -> ExportSidecar, check: (Data) -> (Bool, String)) {
            do {
                let side = try body(dir.appendingPathComponent(name))
                let data = try Data(contentsOf: side.fileURL)
                let hasSidecar = fm.fileExists(atPath: side.recordURL.path)
                let (ok, detail) = check(data)
                r.expect("Exporta \(name)", ok && hasSidecar,
                         "\(data.count) bytes\(hasSidecar ? " + record.json" : ", SIN sidecar"). \(detail)")
            } catch { r.fail("Exporta \(name)", error) }
        }

        file("malla.ply", { try PLYWriter().write(mesh: cube, metadata: meta, to: $0) }) { d in
            (String(decoding: d.prefix(3), as: UTF8.self) == "ply", "cabecera PLY")
        }
        file("malla.stl", { try STLWriter().write(mesh: cube, metadata: meta, to: $0) }) { d in
            guard d.count >= 84 else { return (false, "archivo muy corto") }
            let n = d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
            return (n == 12, "\(n) triángulos (esperado 12)")
        }
        file("malla.obj", { try OBJWriter().write(mesh: cube, metadata: meta, to: $0) }) { d in
            let v = String(decoding: d, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("v ") }.count
            return (v == 8, "\(v) vértices (esperado 8)")
        }
        file("nube.las", { try LASWriter().write(mesh: cube, metadata: meta, to: $0) }) { d in
            let sig = String(decoding: d.prefix(4), as: UTF8.self)
            return (sig == "LASF" && d.count > 26 && d[24] == 1 && d[25] == 4, "firma \(sig), versión \(d.count > 26 ? "\(d[24]).\(d[25])" : "?")")
        }
        file("sitio.geojson", { try GeoJSONWriter().write(metadata: meta, to: $0) }) { d in
            let s = String(decoding: d, as: UTF8.self)
            return (s.contains("FeatureCollection") && s.contains("32719"), "FeatureCollection con EPSG:32719")
        }
        file("especimenes.csv", { url in
            let box = try OrientedBox(center: SIMD3(0.5, 0.5, 0.5), axes: .identity, halfExtents: SIMD3(0.1, 0.2, 0.3))
            let sp = Specimen(scanID: UUID(), label: "Fémur", pose: box, exposedVolume: 0.002,
                              estimatedTotalVolume: 0.004, volumeEstimationMethod: "closedMesh")
            return try CSVWriter().write(specimens: [sp], measurements: [], metadata: meta, to: url)
        }) { d in
            let s = String(decoding: d, as: UTF8.self)
            return (s.contains("specimen_id,label") && s.contains("Fémur"), "cabecera + 1 espécimen")
        }
    }
}

// MARK: - Fixtures sintéticos (copiados de PaleoRegistro/Tests)

nonisolated enum Fx {

    static func gaussian(_ rng: inout SplitMix64) -> Float {
        let u1 = Float.random(in: 0.0001...1, using: &rng)
        let u2 = Float.random(in: 0.0001...1, using: &rng)
        return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }

    static func planePoints(center: SIMD3<Float>, normal: SIMD3<Float>, uExtent: Float, vExtent: Float,
                            count: Int, noiseSigma: Float, seed: UInt64) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: seed)
        let basis = Rectifier.makeBasis(plane: try! Plane(point: center, normal: normal))
        return (0..<count).map { _ in
            let ru = Float.random(in: -0.5...0.5, using: &rng)
            let rv = Float.random(in: -0.5...0.5, using: &rng)
            let g = gaussian(&rng)
            return center + basis.u * (ru * uExtent) + basis.v * (rv * vExtent) + normal * (g * noiseSigma)
        }
    }

    static func boxPoints(half: SIMD3<Float>, perEdge: Int) -> [SIMD3<Float>] {
        let corners: [SIMD3<Float>] = [
            SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
            SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1),
        ]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        var pts: [SIMD3<Float>] = []
        var seen = Set<Int>()
        for (a, b) in edges {
            for i in [a, b] where !seen.contains(i) { seen.insert(i); pts.append(corners[i] * half) }
            for k in 1..<perEdge {
                let t = Float(k) / Float(perEdge)
                pts.append((corners[a] + (corners[b] - corners[a]) * t) * half)
            }
        }
        return pts
    }

    static func rotate(_ pts: [SIMD3<Float>], yaw: Float, pitch: Float) -> [SIMD3<Float>] {
        let y = yaw * .pi / 180, p = pitch * .pi / 180
        let cy = Foundation.cos(y), sy = Foundation.sin(y), cp = Foundation.cos(p), sp = Foundation.sin(p)
        let m = Matrix3x3(SIMD3(cy, 0, -sy), SIMD3(sy * sp, cp, cy * sp), SIMD3(sy * cp, -sp, cy * cp))
        return pts.map { m * $0 }
    }

    /// Esfera lat/lon con caras orientadas hacia afuera (MeshTests.SyntheticMeshes.sphere).
    static func sphere(radius: Float, latDiv: Int = 16, lonDiv: Int = 24) -> Mesh {
        var v: [SIMD3<Float>] = [SIMD3(0, -radius, 0), SIMD3(0, radius, 0)]
        var idx: [UInt32] = []
        for i in 1..<latDiv {
            let phi = Float.pi * Float(i) / Float(latDiv)
            for j in 0..<lonDiv {
                let th = 2 * Float.pi * Float(j) / Float(lonDiv)
                v.append(SIMD3(radius * Foundation.sin(phi) * Foundation.cos(th), radius * Foundation.cos(phi),
                               radius * Foundation.sin(phi) * Foundation.sin(th)))
            }
        }
        func at(_ ring: Int, _ s: Int) -> UInt32 {
            if ring == 0 { return 0 }
            if ring == latDiv { return 1 }
            return UInt32(2 + (ring - 1) * lonDiv + s)
        }
        for j in 0..<lonDiv {
            let j2 = (j + 1) % lonDiv
            idx += [0, at(1, j), at(1, j2)]
            idx += [1, at(latDiv - 1, j2), at(latDiv - 1, j)]
        }
        for i in 1..<(latDiv - 1) {
            for j in 0..<lonDiv {
                let j2 = (j + 1) % lonDiv
                idx += [at(i, j), at(i + 1, j), at(i + 1, j2)]
                idx += [at(i, j), at(i + 1, j2), at(i, j2)]
            }
        }
        var flipped: [UInt32] = []
        for t in stride(from: 0, to: idx.count, by: 3) { flipped += [idx[t], idx[t + 2], idx[t + 1]] }
        return Mesh(vertices: v, indices: flipped)
    }

    static func openUpperHemisphere(radius: Float, latDiv: Int, lonDiv: Int) -> Mesh {
        let full = sphere(radius: radius, latDiv: latDiv, lonDiv: lonDiv)
        var nv: [SIMD3<Float>] = []
        var remap: [UInt32: UInt32] = [:]
        var ni: [UInt32] = []
        func mapped(_ o: UInt32) -> UInt32 {
            if let n = remap[o] { return n }
            let n = UInt32(nv.count); nv.append(full.vertices[Int(o)]); remap[o] = n; return n
        }
        for t in stride(from: 0, to: full.indices.count, by: 3) {
            let tri = [full.indices[t], full.indices[t + 1], full.indices[t + 2]]
            guard tri.allSatisfy({ full.vertices[Int($0)].y >= -0.001 }) else { continue }
            ni += tri.map(mapped)
        }
        return Mesh(vertices: nv, indices: ni)
    }

    static func closedVolume(_ m: Mesh) -> Double {
        var v = 0.0
        for t in stride(from: 0, to: m.indices.count, by: 3) {
            let a = m.vertices[Int(m.indices[t])], b = m.vertices[Int(m.indices[t + 1])], c = m.vertices[Int(m.indices[t + 2])]
            v += Double(vecDot(vecCross(a, b), c))
        }
        return v / 6
    }

    /// Cono de base circular apoyado en y=0 (VolumeTests.VolFixtures.cone).
    static func cone(radius R: Float, height H: Float, rings: Int, segments: Int) -> Mesh {
        var v: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        var layers: [[UInt32]] = []
        for r in 0...rings {
            let h = H * Float(r) / Float(rings + 1)
            let rad = R * (1 - h / H)
            var layer: [UInt32] = []
            for s in 0..<segments {
                let th = 2 * Float.pi * Float(s) / Float(segments)
                layer.append(UInt32(v.count))
                v.append(SIMD3(rad * Foundation.cos(th), h, rad * Foundation.sin(th)))
            }
            layers.append(layer)
        }
        let apex = UInt32(v.count)
        v.append(SIMD3(0, H, 0))
        for l in 0..<(layers.count - 1) {
            let cur = layers[l], nxt = layers[l + 1]
            for s in 0..<segments {
                let a = cur[s], b = cur[(s + 1) % segments], c = nxt[s], d = nxt[(s + 1) % segments]
                idx += [a, b, c, b, d, c]
            }
        }
        let top = layers[layers.count - 1]
        for s in 0..<segments { idx += [top[s], top[(s + 1) % segments], apex] }
        return Mesh(vertices: v, indices: idx)
    }

    // Estratigrafía (StratigraphyTests.StratFixtures)
    static func horizontalUnit(azimuth deg: Float) -> SIMD3<Float> {
        let r = deg * .pi / 180
        return SIMD3(Foundation.sin(r), 0, -Foundation.cos(r))
    }

    static func stratumNormal(dip: Float, dipDirection: Float) -> SIMD3<Float> {
        let th = dip * .pi / 180, phi = dipDirection * .pi / 180
        return SIMD3(-Foundation.sin(phi) * Foundation.sin(th), Foundation.cos(th), Foundation.cos(phi) * Foundation.sin(th))
    }

    static func wallPoints(center: SIMD3<Float>, n_w: SIMD3<Float>, width: Float, height: Float,
                           gridU: Int, gridV: Int) -> [SIMD3<Float>] {
        let u = vecNormalize(vecCross(SIMD3(0, 1, 0), n_w))
        let v = vecNormalize(vecCross(u, n_w))
        var pts: [SIMD3<Float>] = []
        for i in 0..<gridU {
            for j in 0..<gridV {
                let sU = (Float(i) + 0.5) / Float(gridU) - 0.5
                let sV = (Float(j) + 0.5) / Float(gridV) - 0.5
                pts.append(center + u * (sU * width) + v * (sV * height))
            }
        }
        return pts
    }

    static func boundaryLine(n_s: SIMD3<Float>, p_s: SIMD3<Float>, n_w: SIMD3<Float>, p_w: SIMD3<Float>,
                             extHalf: Float, sampleCount: Int) -> [SIMD3<Float>] {
        let dir = vecNormalize(vecCross(n_s, n_w))
        let u_w = vecNormalize(vecCross(SIMD3(0, 1, 0), n_w))
        let v_w = vecNormalize(vecCross(u_w, n_w))
        let denom = vecDot(n_s, v_w)
        let beta = abs(denom) > 1e-9 ? vecDot(n_s, p_s - p_w) / denom : 0
        let base = p_w + v_w * beta
        return (0..<sampleCount).map { k in
            base + dir * (extHalf * (2 * Float(k) / Float(sampleCount - 1) - 1))
        }
    }

    // Segmentación (SegmentationTests.SynthSpecimens)
    static func ellipsoid(center: SIMD3<Float>, radii: SIMD3<Float>, segments n: Int = 16) -> Mesh {
        var v: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for j in 0..<n {
            let phi = Float(j) / Float(n - 1) * .pi
            for i in 0..<n {
                let th = Float(i) / Float(n - 1) * 2 * .pi
                v.append(center + SIMD3(Foundation.sin(phi) * Foundation.cos(th), Foundation.cos(phi),
                                        Foundation.sin(phi) * Foundation.sin(th)) * radii)
            }
        }
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let a = UInt32(j * n + i), b = a + 1, c = UInt32((j + 1) * n + i), d = c + 1
                idx += [a, b, c, b, d, c]
            }
        }
        return Mesh(vertices: v, indices: idx)
    }

    static func planeMesh(size: Float, divisions: Int = 20) -> Mesh {
        var v: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        let n = divisions + 1
        for j in 0...divisions {
            for i in 0...divisions {
                v.append(SIMD3((Float(i) / Float(divisions) - 0.5) * size, 0, (Float(j) / Float(divisions) - 0.5) * size))
            }
        }
        for j in 0..<divisions {
            for i in 0..<divisions {
                let a = UInt32(j * n + i), b = a + 1, c = UInt32((j + 1) * n + i), d = c + 1
                idx += [a, b, c, b, d, c]
            }
        }
        return Mesh(vertices: v, indices: idx)
    }

    static func merge(_ meshes: [Mesh]) -> Mesh {
        var v: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for m in meshes {
            let off = UInt32(v.count)
            v += m.vertices
            idx += m.indices.map { $0 + off }
        }
        return Mesh(vertices: v, indices: idx)
    }

    // Registro (RegistrationTests)
    static func denseCube(size: Float, divisions n: Int) -> Mesh {
        var v: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for face in 0..<6 {
            let base = v.count
            for j in 0...n {
                for i in 0...n {
                    let a = Float(i) / Float(n) * size, b = Float(j) / Float(n) * size
                    switch face {
                    case 0: v.append(SIMD3(a, b, 0))
                    case 1: v.append(SIMD3(a, b, size))
                    case 2: v.append(SIMD3(a, 0, b))
                    case 3: v.append(SIMD3(a, size, b))
                    case 4: v.append(SIMD3(0, a, b))
                    default: v.append(SIMD3(size, a, b))
                    }
                }
            }
            let s = n + 1
            for j in 0..<n {
                for i in 0..<n {
                    let a = UInt32(base + j * s + i), b = a + 1, c = UInt32(base + (j + 1) * s + i), d = c + 1
                    idx += [a, b, c, b, d, c]
                }
            }
        }
        return Mesh(vertices: v, indices: idx)
    }

    static func addNoise(_ pts: [SIMD3<Float>], sigma: Float, seed: UInt64 = 42) -> [SIMD3<Float>] {
        var rng = SplitMix64(seed: seed)
        return pts.map { p in
            let gx = gaussian(&rng) * sigma, gy = gaussian(&rng) * sigma, gz = gaussian(&rng) * sigma
            return SIMD3(p.x + gx, p.y + gy, p.z + gz)
        }
    }

    static func rigid(yawDeg: Float, pitchDeg: Float = 0, rollDeg: Float = 0, translation: SIMD3<Float> = .zero) -> Matrix4x4 {
        let d = Float.pi / 180
        let cy = Foundation.cos(yawDeg * d), sy = Foundation.sin(yawDeg * d)
        let cp = Foundation.cos(pitchDeg * d), sp = Foundation.sin(pitchDeg * d)
        let cr = Foundation.cos(rollDeg * d), sr = Foundation.sin(rollDeg * d)
        return Matrix4x4(
            SIMD4(cy * cp, sy * cp, -sp, 0),
            SIMD4(cy * sp * sr - sy * cr, sy * sp * sr + cy * cr, cp * sr, 0),
            SIMD4(cy * sp * cr + sy * sr, sy * sp * cr - cy * sr, cp * cr, 0),
            SIMD4(translation.x, translation.y, translation.z, 1))
    }

    // Exportación (ExportTests.sampleMesh)
    static func exportCube() -> Mesh {
        Mesh(vertices: [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ], indices: [0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 2, 3, 7, 2, 7, 6, 1, 2, 6, 1, 6, 5, 0, 3, 7, 0, 7, 4])
    }
}
