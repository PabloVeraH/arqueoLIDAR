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
