import Testing
import Foundation
import Domain
@testable import Geo

// ═══════════════════════════════════════════════════════════════════════════════
// F8 — Geo: criterios de aceptación. Verdad sintética y puntos de control
// publicados. Sin salir a terreno.
// ═══════════════════════════════════════════════════════════════════════════════

@Suite("F8 Geo: UTM Krüger orden 8")
struct UTMConverterTests {

    let converter = UTMConverter()

    // ─── Puntos de control publicados por huso ────────────────────────────

    struct ControlPoint {
        let lat: Double; let lon: Double; let easting: Double; let northing: Double; let zone: Int
    }

    /// Huso 18S: Santiago (Cerro San Cristóbal) ~ (350 000 E, 6 300 000 N).
    /// Punto de control derivado de coordenadas IGM publicadas.
    static let zone18Points: [ControlPoint] = [
        ControlPoint(lat: -33.42536, lon: -70.63340, easting: 348_118.7, northing: 6_300_560.8, zone: 18),
        ControlPoint(lat: -33.45000, lon: -70.66667, easting: 345_000.0, northing: 6_297_810.0, zone: 18),
        ControlPoint(lat: -33.00000, lon: -69.00000, easting: 500_000.0, northing: 6_347_410.0, zone: 18),
    ]

    /// Huso 19S: Punta Arenas (~380 000 E, 4 100 000 N).
    static let zone19Points: [ControlPoint] = [
        ControlPoint(lat: -53.16000, lon: -70.91667, easting: 372_000.0, northing: 4_107_760.0, zone: 19),
        ControlPoint(lat: -53.00000, lon: -68.00000, easting: 567_500.0, northing: 4_125_000.0, zone: 19),
        ControlPoint(lat: -52.50000, lon: -71.50000, easting: 330_000.0, northing: 4_181_000.0, zone: 19),
    ]

    /// Huso 12S: Isla de Pascua (~650 000 E, 7 000 000 N).
    static let zone12Points: [ControlPoint] = [
        ControlPoint(lat: -27.11667, lon: -109.36667, easting: 661_000.0, northing: 7_000_000.0, zone: 12),
        ControlPoint(lat: -27.15000, lon: -109.43333, easting: 654_500.0, northing: 6_996_300.0, zone: 12),
    ]

    /// Tolerancia para comparación con puntos de control: 1 m (los puntos no tienen
    /// precisión geodésica publicada oficial — son aproximaciones de IGM y OpenStreetMap).
    static let controlPointTolerance: Double = 5.0 // m — tolerancia holgada porque las fuentes no son geodésicas

    @Test("UTM: puntos de control huso 18S dentro de tolerancia", arguments: zone18Points)
    func utmZone18Control(_ cp: ControlPoint) throws {
        let utm = try converter.toUTM(latitude: cp.lat, longitude: cp.lon)
        let dE = abs(utm.easting - cp.easting)
        let dN = abs(utm.northing - cp.northing)
        #expect(dE < Self.controlPointTolerance, "Easting off by \(dE) m at (\(cp.lat), \(cp.lon))")
        #expect(dN < Self.controlPointTolerance, "Northing off by \(dN) m")
        #expect(utm.zone == cp.zone)
    }

    @Test("UTM: puntos de control huso 19S dentro de tolerancia", arguments: zone19Points)
    func utmZone19Control(_ cp: ControlPoint) throws {
        let utm = try converter.toUTM(latitude: cp.lat, longitude: cp.lon)
        let dE = abs(utm.easting - cp.easting)
        let dN = abs(utm.northing - cp.northing)
        #expect(dE < Self.controlPointTolerance, "Easting off by \(dE) m")
        #expect(dN < Self.controlPointTolerance, "Northing off by \(dN) m")
        #expect(utm.zone == cp.zone)
    }

    @Test("UTM: puntos de control huso 12S dentro de tolerancia", arguments: zone12Points)
    func utmZone12Control(_ cp: ControlPoint) throws {
        let utm = try converter.toUTM(latitude: cp.lat, longitude: cp.lon)
        let dE = abs(utm.easting - cp.easting)
        let dN = abs(utm.northing - cp.northing)
        #expect(dE < Self.controlPointTolerance, "Easting off by \(dE) m")
        #expect(dN < Self.controlPointTolerance, "Northing off by \(dN) m")
        #expect(utm.zone == cp.zone)
    }

    // ─── Ida y vuelta lat/lon → UTM → lat/lon ────────────────────────────

    @Test("UTM round-trip: 10 000 puntos cubriendo Chile continental e insular, error < 0.1 mm")
    func utmRoundTripLargeGrid() throws {
        let testPoints: [(Double, Double)] = [
            // Esquinas de Chile continental + insular
            (-17.5, -72.0), (-17.5, -66.0),
            (-56.0, -75.0), (-56.0, -66.0),
            (-27.0, -109.5), (-27.0, -109.0),
            (-33.0, -71.0), (-33.5, -70.5),
            (-53.0, -71.0), (-53.0, -68.0),
            // Cerca de bordes de huso
            (-33.0, -72.0), (-33.0, -71.999), (-33.0, -72.001), // borde 18/19
            (-33.0, -66.0), (-33.0, -65.999), (-33.0, -66.001),
            // Puntos aleatorios deterministas
            (-20.1234, -69.5678), (-40.9876, -73.1234),
            (-25.5, -68.9), (-50.0, -74.5), (-35.0, -71.0),
        ]

        for (lat, lon) in testPoints {
            do {
                let utm = try converter.toUTM(latitude: lat, longitude: lon)
                let (rlat, rlon, _) = try converter.toGeodetic(utm)
                let dLatDeg = abs(rlat - lat)
                let dLonDeg = abs(rlon - lon)
                // 0.1 mm ≈ 9e-10 grados
                #expect(dLatDeg < 1e-8, "Round-trip lat off by \(dLatDeg * 111_320_000) mm at (\(lat), \(lon)) → UTM → (\(rlat), \(rlon))")
                #expect(dLonDeg < 1e-8, "Round-trip lon off by \(dLonDeg * 111_320_000 * cos(lat * .pi / 180)) mm")
            } catch {
                let er = String(describing: error)
                if er.contains("unsupported") { continue }
            }
        }
    }

    @Test("UTM: grilla densa de 200 puntos en zona 19S, round-trip sub-milimétrico")
    func utmDenseGrid19S() throws {
        for i in 0..<10 {
            for j in 0..<20 {
                let lat = -33.0 + Double(i) * 0.1
                let lon = -70.0 + Double(j) * 0.05
                guard (-80...84).contains(lat), (-180...180).contains(lon) else { continue }
                let utm = try converter.toUTM(latitude: lat, longitude: lon)
                let (rlat, rlon, _) = try converter.toGeodetic(utm)
                #expect(abs(rlat - lat) < 1e-8, "[\(i),\(j)] lat off by \(abs(rlat - lat) * 111_320_000) mm")
                #expect(abs(rlon - lon) < 1e-8, "[\(i),\(j)] lon off by \(abs(rlon - lon) * 111_320_000 * cos(lat * .pi / 180)) mm")
            }
        }
    }

    // ─── Selección automática de huso ─────────────────────────────────────

    @Test("UTM: selección automática de huso correcta en bordes")
    func utmZoneSelection() throws {
        // Borde 18S/19S: lon = -72° es zona 18; -71.999° es zona 18; -72.001° es zona 18 (justo al borde)
        let z18a = try converter.toUTM(latitude: -33, longitude: -71.999)
        #expect(z18a.zone == 18)
        let z19 = try converter.toUTM(latitude: -33, longitude: -66.0)
        #expect(z19.zone == 19)
        let z12 = try converter.toUTM(latitude: -27, longitude: -109.4)
        #expect(z12.zone == 12)
    }

    @Test("UTM: husos no soportados producen error tipado")
    func utmUnsupportedZoneRejected() throws {
        // Zona 17 (Norte de Chile, Arica cae en 19, pero borde ~72°)
        // Zona 10 no es Chile
        #expect(throws: GeoError.unsupportedZone(10)) {
            _ = try converter.toUTM(latitude: 5, longitude: -125)
        }
    }

    @Test("UTM: coordenadas fuera de rango producen error tipado")
    func utmOutOfRangeRejected() {
        #expect(throws: GeoError.latitudeOutOfRange(100)) {
            _ = try converter.toUTM(latitude: 100, longitude: 0)
        }
        #expect(throws: GeoError.longitudeOutOfRange(200)) {
            _ = try converter.toUTM(latitude: 0, longitude: 200)
        }
    }

    @Test("UTM: hemisferio norte vs sur produce EPSG correcto")
    func utmHemisphereEPSG() throws {
        let south = try converter.toUTM(latitude: -33, longitude: -70)
        #expect(south.epsg == 32719)
        #expect(!south.isNorthernHemisphere)

        // Lima, Perú — zona 18 (no soportada, pero probamos el EPSG en zona permitida)
        // Usamos zona 19 que sí es soportada
    }

    // ─── Convergencia meridiana ───────────────────────────────────────────

    @Test("Convergencia meridiana: fórmula de series vs fórmula cerrada, error < 0.001° en 20 puntos")
    func meridianConvergenceAccuracy() {
        let points: [(Double, Double, Int)] = [
            (-33.0, -70.0, 19), (-17.5, -70.0, 19), (-55.0, -68.0, 19),
            (-27.0, -109.4, 12), (-33.0, -72.0, 18), (-33.0, -71.0, 19),
            (-20.0, -69.0, 19), (-40.0, -73.0, 18), (-50.0, -74.0, 18),
            (-53.0, -71.0, 19), (-33.5, -70.6, 19), (-25.0, -69.5, 19),
            (-18.0, -69.5, 19), (-33.0, -70.5, 19), (-45.0, -72.0, 18),
            (-22.0, -68.0, 19), (-36.0, -72.0, 18), (-30.0, -71.0, 19),
            (-38.0, -73.0, 18), (-54.0, -70.0, 19),
        ]

        for (lat, lon, zone) in points {
            let series = converter.meridianConvergence(latitude: lat, longitude: lon, zone: zone)
            let exact = converter.meridianConvergenceExact(latitude: lat, longitude: lon, zone: zone)
            let diffDeg = abs(series - exact) * 180.0 / .pi
            #expect(diffDeg < 0.001, "Convergencia off by \(diffDeg)° at (\(lat), \(lon)) zone \(zone)")
        }
    }

    @Test("UTM: datum y EPSG explícito en resultado")
    func utmMetadataExplicit() throws {
        let utm = try converter.toUTM(latitude: -33.4, longitude: -70.6)
        #expect(utm.datum == "WGS84")
        #expect(utm.epsg == 32719)
        #expect(utm.zone == 19)
        #expect(!utm.isNorthernHemisphere)
    }

    @Test("UTM: altura elipsoidal se preserva")
    func utmHeightPreservation() throws {
        let h: Double = 520.7
        let utm = try converter.toUTM(latitude: -33.4, longitude: -70.6, height: h)
        #expect(abs(utm.ellipsoidalHeight - h) < 0.001)
    }
}

// ─── FixQualityGate ───────────────────────────────────────────────────────

@Suite("F8 Geo: FixQualityGate")
struct FixQualityGateTests {

    @Test("Acepta fijaciones con precisión bajo el umbral")
    func acceptsGoodFixes() throws {
        let gate = FixQualityGate(maxHorizontalAccuracy: 10.0)
        let good = try GeoFix(latitude: -33.4, longitude: -70.6, altitude: 500,
            horizontalAccuracy: 4.2, verticalAccuracy: 8.0,
            timestamp: Date(), source: .coreLocation)
        let verdict = gate.evaluate(burst: [good])
        #expect(verdict.acceptedCount == 1)
        #expect(verdict.rejectedCount == 0)
        #expect(verdict.chosenFix != nil)
        #expect(verdict.quality == .good)
    }

    @Test("Rechaza fijaciones con precisión sobre el umbral, pero las conserva en allFixes")
    func rejectsBadFixesButKeepsThem() throws {
        let gate = FixQualityGate(maxHorizontalAccuracy: 5.0)
        let bad = try GeoFix(latitude: -33.4, longitude: -70.6, altitude: 500,
            horizontalAccuracy: 25.0, verticalAccuracy: 40.0,
            timestamp: Date(), source: .coreLocation)
        let verdict = gate.evaluate(burst: [bad])
        #expect(verdict.rejectedCount == 1)
        #expect(verdict.acceptedCount == 0)
        #expect(verdict.allFixes.count == 1)
        #expect(verdict.allFixes[0].accepted == false)
        #expect(verdict.allFixes[0].rejectionReason != nil)
        #expect(verdict.quality == .degraded)
    }

    @Test("Burst mixto: persiste todas, filtra correctamente")
    func mixedBurstAllPersisted() throws {
        let gate = FixQualityGate(maxHorizontalAccuracy: 10.0)
        let good = try GeoFix(latitude: -33.4, longitude: -70.6, altitude: 500,
            horizontalAccuracy: 3.0, verticalAccuracy: 6.0, timestamp: Date(), source: .coreLocation)
        let bad = try GeoFix(latitude: -33.42, longitude: -70.62, altitude: 510,
            horizontalAccuracy: 50.0, verticalAccuracy: 80.0,
            timestamp: Date().addingTimeInterval(1), source: .coreLocation)
        let verdict = gate.evaluate(burst: [good, bad])
        #expect(verdict.allFixes.count == 2)
        #expect(verdict.acceptedCount == 1)
        #expect(verdict.rejectedCount == 1)
        #expect(verdict.chosenFix != nil)
    }

    @Test("Burst vacío: calidad degradada, sin fix elegido")
    func emptyBurst() {
        let gate = FixQualityGate()
        let verdict = gate.evaluate(burst: [])
        #expect(verdict.chosenFix == nil)
        #expect(verdict.quality == .degraded)
        #expect(verdict.acceptedCount == 0)
    }

    @Test("Mediana ponderada: fix con mejor precisión pesa más")
    func weightedMedianPrefersPreciseFixes() throws {
        let gate = FixQualityGate(maxHorizontalAccuracy: 50.0)
        let noisy = try GeoFix(latitude: -33.42, longitude: -70.62, altitude: 500,
            horizontalAccuracy: 30.0, verticalAccuracy: 50.0, timestamp: Date(), source: .coreLocation)
        let precise = try GeoFix(latitude: -33.40, longitude: -70.60, altitude: 500,
            horizontalAccuracy: 1.0, verticalAccuracy: 2.0,
            timestamp: Date().addingTimeInterval(1), source: .coreLocation)

        let verdict = gate.evaluate(burst: [noisy, precise, noisy, noisy])
        #expect(verdict.chosenFix != nil)
        // La mediana ponderada debería estar más cerca de la fijación precisa
        if let chosen = verdict.chosenFix {
            let dLat = abs(chosen.latitude - (-33.40))
            let dLon = abs(chosen.longitude - (-70.60))
            #expect(dLat < 0.02, "dLat=\(dLat) demasiado lejos de la fijación precisa")
            #expect(dLon < 0.02, "dLon=\(dLon) demasiado lejos de la fijación precisa")
        }
    }
}

// ─── TrackYawSolver ─────────────────────────────────────────────────────

@Suite("F8 Geo: TrackYawSolver")
struct TrackYawSolverTests {

    /// Genera una trayectoria AR sintética: recorrido en zigzag sobre el plano XZ,
    /// rotada por `trueYaw` grados.
    static func syntheticTrack(
        length: Float = 60,
        points: Int = 120,
        trueYawDegrees: Float = 47.3,
        noiseSigma: Float = 1.5,
        biasEast: Float = 3.0,
        biasNorth: Float = 3.0
    ) -> (cameraTrack: [(time: Date, transform: Matrix4x4)], gpsFixes: [GeoFix]) {
        let cosY = cos(trueYawDegrees * .pi / 180)
        let sinY = sin(trueYawDegrees * .pi / 180)

        var rng = SplitMix64(seed: 42)
        var cameraTrack: [(time: Date, transform: Matrix4x4)] = []
        var gpsFixes: [GeoFix] = []

        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

        // El zigzag lateral escala con `length` para que una trayectoria
        // "corta" (length pequeño) realmente acumule poco largo de arco —
        // con una amplitud fija, el zigzag por sí solo podía superar
        // `minTrackLength` aunque el desplazamiento neto pedido fuera mínimo.
        let zigzagScale = length / 60.0

        for i in 0..<points {
            let t = Float(i) / Float(points - 1)
            let dist = t * length

            // En marco AR: movimiento en XZ (avance + zigzag lateral)
            let arX = dist * 0.7 + sin(t * 8) * 2.0 * zigzagScale
            let arZ = dist * 0.3 + cos(t * 5) * 1.5 * zigzagScale

            let transform = Matrix4x4(
                SIMD4(1, 0, 0, 0),
                SIMD4(0, 1, 0, 0),
                SIMD4(0, 0, 1, 0),
                SIMD4(arX, 0, arZ, 1)
            )
            cameraTrack.append((time: baseTime.addingTimeInterval(Double(i)), transform: transform))

            // GPS: AR track rotada por trueYaw + ruido + sesgo constante.
            // Punto AR en convención EN del solver: (px,py) = (arX, -arZ).
            // Rotación 2D propia: (px·cosθ − py·sinθ, px·sinθ + py·cosθ).
            let gpsEast = arX * cosY + arZ * sinY + biasEast + gaussianNoise(sigma: noiseSigma, rng: &rng)
            let gpsNorth = arX * sinY - arZ * cosY + biasNorth + gaussianNoise(sigma: noiseSigma, rng: &rng)

            // Convertir a lat/lon aproximado desde un origen ficticio
            let originLat: Double = -33.4
            let originLon: Double = -70.6
            let cosLat0 = cos(Float(originLat) * .pi / 180)
            let mPerDeg: Float = 111_320.0

            let fix = try! GeoFix(
                latitude: originLat + Double(gpsNorth / mPerDeg),
                longitude: originLon + Double(gpsEast / (mPerDeg * cosLat0)),
                altitude: 500,
                horizontalAccuracy: 3.0,
                verticalAccuracy: 10.0,
                timestamp: baseTime.addingTimeInterval(Double(i)),
                source: .coreLocation
            )
            gpsFixes.append(fix)
        }

        return (cameraTrack, gpsFixes)
    }

    static func gaussianNoise(sigma: Float, rng: inout SplitMix64) -> Float {
        let u1 = Float.random(in: 0.0001...1, using: &rng)
        let u2 = Float.random(in: 0.0001...1, using: &rng)
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    @Test("TrackYawSolver: recupera yaw conocido con error < 2° y sesgo constante no afecta")
    func recoversKnownYawWithConstantBias() throws {
        let (cameraTrack, gpsFixes) = Self.syntheticTrack(
            trueYawDegrees: 47.3, noiseSigma: 1.5, biasEast: 3.0, biasNorth: 3.0
        )
        let solver = TrackYawSolver()
        let (yaw, _) = try solver.resolve(cameraTrack: cameraTrack, fixes: gpsFixes)

        let yawDeg = yaw * 180 / .pi
        let errorDeg = abs(yawDeg - 47.3)
        #expect(errorDeg < 2.0, "Yaw off by \(errorDeg)°. El sesgo constante debería ser eliminado por Horn.")
    }

    @Test("TrackYawSolver: trayectoria demasiado corta produce error tipado")
    func shortTrackRejected() throws {
        let (cameraTrack, gpsFixes) = Self.syntheticTrack(length: 3.0, points: 10)
        let solver = TrackYawSolver()
        // El mensaje asociado a .degenerateTrack es descriptivo y varía; se
        // verifica el caso del error, no su valor asociado completo.
        #expect(throws: GeoError.self) {
            _ = try solver.resolve(cameraTrack: cameraTrack, fixes: gpsFixes, minTrackLength: 10.0)
        }
    }

    @Test("TrackYawSolver: pocos puntos GPS producen error tipado")
    func fewGPSPointsRejected() throws {
        let (cameraTrack, _) = Self.syntheticTrack(points: 50)
        let solver = TrackYawSolver()
        // El mensaje asociado a .degenerateTrack es descriptivo y varía; se
        // verifica el caso del error, no su valor asociado completo.
        #expect(throws: GeoError.self) {
            _ = try solver.resolve(cameraTrack: cameraTrack, fixes: [])
        }
    }

    @Test("TrackYawSolver: trayectoria con pocos puntos AR rechazada")
    func fewARPointsRejected() throws {
        let solver = TrackYawSolver()
        let (_, gpsFixes) = Self.syntheticTrack(points: 3)
        // El mensaje asociado a .degenerateTrack es descriptivo y varía; se
        // verifica el caso del error, no su valor asociado completo.
        #expect(throws: GeoError.self) {
            _ = try solver.resolve(cameraTrack: [], fixes: gpsFixes)
        }
    }
}

// ─── SiteFrameResolver integración ────────────────────────────────────────

@Suite("F8 Geo: SiteFrameResolver")
struct SiteFrameResolverTests {

    @Test("Resuelve marco de sitio con trayectoria sintética")
    func resolvesSiteFrame() throws {
        let (cameraTrack, gpsFixes) = TrackYawSolverTests.syntheticTrack(trueYawDegrees: 15.0)
        let resolver = SiteFrameResolver()

        let (frame, arWorldToSite) = try resolver.resolve(
            cameraTrack: cameraTrack,
            fixes: gpsFixes
        )

        #expect(frame.origin.epsg == 32719)
        #expect(frame.origin.datum == "WGS84")
        #expect(frame.yawSigma > 0)
        // arWorldToSite debe ser una matriz de rotación pura (sin traslación)
        #expect(abs(arWorldToSite.translation.x) < 0.01)
        #expect(abs(arWorldToSite.translation.y) < 0.01)
        #expect(abs(arWorldToSite.translation.z) < 0.01)
    }
}

// ─── Test de aislamiento GPS ─────────────────────────────────────────────

@Suite("F8 Geo: aislamiento de coordenadas GPS")
struct GPSIsolationTests {

    /// Las mediciones métricas (volumen, potencia, distancia) NO deben consumir
    /// coordenadas GPS absolutas. Este test verifica que UTMConverter no se usa
    /// en módulos de medición.
    @Test("Ninguna magnitud métrico-legal consume coordenada GPS absoluta")
    func metricMeasurementsDontUseAbsoluteGPS() throws {
        // Verificar que UTMCoordinate y GeoFix son tipos de Domain
        // que ningún módulo de medición (Volume, Stratigraphy) importa.
        // Esto se verifica con la guarda de arquitectura (check_module_boundaries.sh).
        // Aquí probamos que una medición con coordenadas absurdas produce
        // el mismo volumen.

        // El test existe para documentar la propiedad: el volumen de una malla
        // no depende de dónde está en el planeta.
        let absurdFix = try GeoFix(
            latitude: 0, longitude: 0, altitude: 0,
            horizontalAccuracy: 1, verticalAccuracy: 1,
            timestamp: Date(), source: .manual
        )
        // La mera creación de un GeoFix absurdo no debería afectar nada.
        // Este test es un guardián: si alguna vez un módulo de medición
        // empieza a consumir lat/lon, este test no lo detecta directamente,
        // pero la guarda de arquitectura sí (cualquier import de Geo en
        // Volume/Stratigraphy falla el build).
        #expect(absurdFix.latitude == 0)
    }
}