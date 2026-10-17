import Testing
import Foundation

@testable import Domain

@Suite("F1 Domain: tipos puros e invariantes")
struct DomainTests {

    @Test("Round-trip Codable de un Finding completo")
    func findingCodableRoundTrip() throws {
        let author = AuthorIdentity(name: "P. Pérez", role: "Arqueólogo", institution: "MNHN", cmnPermitNumber: "CMN-2026-0001")
        let geo = try GeoFix(latitude: -33.4, longitude: -70.6, altitude: 520, horizontalAccuracy: 4.2,
                             verticalAccuracy: 8.0, timestamp: Date(timeIntervalSince1970: 1_700_000_000), source: .coreLocation)
        let frame = try SiteFrame(siteID: UUID(), origin: try UTMCoordinate(easting: 350000, northing: 6300000, ellipsoidalHeight: 520, zone: 19, isNorthernHemisphere: false, epsg: 32719, datum: "WGS84"), yawFromTrueNorth: 0.3, yawSigma: 0.01, meridianConvergence: 0.017)
        let finding = Finding(siteID: UUID(), title: "Hallazgo", expeditionCode: "EXP-1", author: author,
                              cmnNotification: CMNNotification(date: Date(), channel: "web", folio: "F-9"))

        let data = try JSONEncoder().encode(finding)
        let decoded = try JSONDecoder().decode(Finding.self, from: data)
        #expect(decoded == finding)
        _ = geo
        _ = frame
    }

    @Test("Site guarda su ubicación y lee fichas antiguas sin ella")
    func siteLocationCodable() throws {
        let fix = try GeoFix(latitude: -22.89, longitude: -69.32, altitude: 1200, horizontalAccuracy: 4,
                             verticalAccuracy: 6, timestamp: Date(timeIntervalSince1970: 1_700_000_000), source: .coreLocation)
        let site = Site(name: "Quebrada", code: "QLR-01", location: fix)
        #expect(try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site)) == site)

        // Ficha escrita antes de que existiera `location`.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Site(name: "A", code: "B"))) as! [String: Any]
        old.removeValue(forKey: "location")
        let decoded = try JSONDecoder().decode(Site.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.location == nil)
    }

    @Test("Plane normaliza su normal")
    func planeNormalizes() throws {
        let p = try Plane(point: SIMD3(0,0,0), normal: SIMD3(0, 2, 0))
        #expect(abs(vecLength(p.normal) - 1) < 1e-6)
    }

    @Test("Plane rechaza normal de norma 0 con error tipado")
    func planeRejectsZeroNormal() {
        #expect(throws: DomainValidationError.zeroNormal) {
            _ = try Plane(point: .zero, normal: .zero)
        }
    }

    @Test("OrientedBox rechaza semieje negativo con error tipado")
    func orientedBoxRejectsNegative() {
        #expect(throws: DomainValidationError.negativeHalfExtent) {
            _ = try OrientedBox(center: .zero, axes: .identity, halfExtents: SIMD3(1, -1, 1))
        }
    }

    @Test("UTMCoordinate rechaza huso fuera de rango y coordenadas negativas")
    func utmRejectsInvalid() {
        #expect(throws: DomainValidationError.invalidZone(61)) {
            _ = try UTMCoordinate(easting: 100, northing: 200, ellipsoidalHeight: 0, zone: 61,
                                  isNorthernHemisphere: false, epsg: 32761, datum: "WGS84")
        }
        #expect(throws: DomainValidationError.negativeCoordinate) {
            _ = try UTMCoordinate(easting: -1, northing: 200, ellipsoidalHeight: 0, zone: 19,
                                  isNorthernHemisphere: false, epsg: 32719, datum: "WGS84")
        }
    }

    @Test("GeoFix rechaza precisión negativa con error tipado")
    func geoFixRejectsNegativeAccuracy() {
        #expect(throws: DomainValidationError.negativeAccuracy) {
            _ = try GeoFix(latitude: 0, longitude: 0, altitude: 0, horizontalAccuracy: -1,
                           verticalAccuracy: 1, timestamp: Date(), source: .coreLocation)
        }
    }

    @Test("VolumeResult: net = positive - negative")
    func volumeNet() {
        let v = VolumeResult(positive: 3.0, negative: 1.0, coveredArea: 10, filledCellRatio: 1,
                             uncertainty: 0.1, method: .heightField, isInferred: false, algorithmVersion: "1.0")
        #expect(v.net == 2.0)
    }

    @Test("Matrix4x4 rígida: transformación e inversa")
    func matrix4x4Rigid() {
        let m = Matrix4x4(translation: SIMD3(1, 2, 3), quaternion: Quatf(vector: SIMD3(0, 0, 0), scalar: 1))
        let inv = m.rigidInverse()
        let p = SIMD3<Float>(5, 6, 7)
        let back = inv.applyAffine(m.applyAffine(p))
        #expect(vecLength(back - p) < 1e-4)
    }

    @Test("SplitMix64: determinista con misma semilla, distinto con semilla distinta")
    func splitMixDeterminism() {
        var a1 = SplitMix64(seed: 42)
        var a2 = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 43)
        var seq1: [UInt64] = []
        var seq2: [UInt64] = []
        var seq3: [UInt64] = []
        for _ in 0..<100 {
            seq1.append(a1.next()); seq2.append(a2.next()); seq3.append(b.next())
        }
        #expect(seq1 == seq2)
        #expect(seq1 != seq3)
    }
}

@Suite("F15 Domain: informe de calidad de la sesión")
struct QualityReportTests {

    @Test("Sesión corta y limpia: sin advertencias")
    func cleanSession() {
        let q = QualityReport(duration: 120, pathLength: 8, interruptions: 0, limitedTrackingSeconds: 5,
                              sunSaturationSeconds: 0, maxThermal: .fair)
        #expect(q.flags.isEmpty)
    }

    @Test("Cada límite superado deja su advertencia, y se declara que los límites son provisorios")
    func everyLimitFlags() {
        let q = QualityReport(duration: 900, pathLength: 75, interruptions: 2, limitedTrackingSeconds: 400,
                              sunSaturationSeconds: 30, maxThermal: .serious)
        #expect(q.flags.count == 7, "\(q.flags)")
        #expect(q.flags.contains { $0.hasPrefix("Escaneo largo (15 min") })
        #expect(q.flags.contains { $0.contains("2 interrupción") })
        #expect(q.flags.last?.contains("provisorios") == true)
    }

    @Test("Con límites validados no se agrega la nota de provisorios")
    func validatedLimits() {
        var limits = QualityLimits.provisional
        limits.validated = true
        let q = QualityReport(duration: 900, pathLength: 1, interruptions: 0, limitedTrackingSeconds: 0,
                              sunSaturationSeconds: 0, maxThermal: .nominal, limits: limits)
        #expect(q.flags.count == 1)
    }
}
