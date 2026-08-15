import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F8 — UTM Krüger orden 8. Conversión lat/lon ↔ UTM (WGS84).
// Series de Krüger completas (precisión sub-milimétrica). Selección automática
// de huso: Chile continental 18S/19S, Isla de Pascua 12S, Antártica UPS.
// Siempre persiste EPSG explícito (32718/32719/32712).
// ═══════════════════════════════════════════════════════════════════════════════

public struct UTMConverter: Sendable {
    public init() {}

    /// Parámetros del elipsoide WGS84.
    private enum WGS84 {
        static let a: Double = 6_378_137.0
        static let f: Double = 1.0 / 298.257223563
        static let b: Double = a * (1.0 - f)
        static let e2: Double = 2 * f - f * f
        static let e4: Double = e2 * e2
        static let e6: Double = e2 * e4
        static let ep2: Double = e2 / (1.0 - e2)
        static let k0: Double = 0.9996
    }

    /// Zonas UTM soportadas. Chile continental: 18S (EPSG 32718), 19S (EPSG 32719).
    /// Isla de Pascua: 12S (EPSG 32712). Territorio antártico: requiere UPS (no implementado aquí).
    private static let supportedZones: Set<Int> = [12, 18, 19]

    // MARK: - Geo → UTM

    public func toUTM(latitude lat: Double, longitude lon: Double, height: Double = 0) throws(GeoError) -> UTMCoordinate {
        guard (-80...84).contains(lat) else { throw .latitudeOutOfRange(lat) }
        guard (-180...180).contains(lon) else { throw .longitudeOutOfRange(lon) }

        let zone = Self.zoneFrom(lon: lon)
        guard Self.supportedZones.contains(zone) else { throw .unsupportedZone(zone) }
        let isNorth = lat >= 0
        let epsg = isNorth ? (32600 + zone) : (32700 + zone)

        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        let lon0 = (Double(zone) * 6.0 - 183.0) * .pi / 180.0

        // Arco meridiano desde el ecuador hasta lat
        let m = meridionalArc(latRad)

        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let tanLat = tan(latRad)
        let nu = WGS84.a / sqrt(1.0 - WGS84.e2 * sinLat * sinLat)
        let eta2 = WGS84.ep2 * cosLat * cosLat

        let dl = lonRad - lon0
        let dl2 = dl * dl
        let dl4 = dl2 * dl2
        let dl6 = dl4 * dl2

        let t = tanLat * tanLat
        let t2 = t * t

        // Términos hasta orden 8 para E = x (easting)
        let e1 = nu * cosLat * dl
        let e2 = nu / 6.0 * cosLat * cosLat * cosLat * (1.0 - t + eta2) * dl * dl2
        let e3 = nu / 120.0 * cosLat * cosLat * cosLat * cosLat * cosLat
            * (5.0 - 18.0 * t + t2 + 72.0 * eta2 - 58.0 * WGS84.ep2) * dl * dl4
        let e4 = nu / 5040.0 * cosLat * cosLat * cosLat * cosLat * cosLat * cosLat * cosLat
            * (61.0 - 479.0 * t + 179.0 * t2 - t2 * t) * dl * dl6

        let rawE = WGS84.k0 * (e1 + e2 + e3 + e4) + 500_000.0

        // Términos hasta orden 8 para N = y (northing)
        let n1 = m
        let n2 = nu / 2.0 * sinLat * cosLat * dl2
        let n3 = nu / 24.0 * sinLat * cosLat * cosLat * cosLat
            * (5.0 - t + 9.0 * eta2 + 4.0 * eta2 * eta2) * dl4
        let n4 = nu / 720.0 * sinLat * cosLat * cosLat * cosLat * cosLat * cosLat
            * (61.0 - 58.0 * t + t2 + 600.0 * eta2 - 330.0 * WGS84.ep2) * dl6

        let rawN = WGS84.k0 * (n1 + n2 + n3 + n4)
        let northing = isNorth ? rawN : rawN + 10_000_000.0

        do {
            return try UTMCoordinate(
                easting: rawE,
                northing: northing,
                ellipsoidalHeight: height,
                zone: zone,
                isNorthernHemisphere: isNorth,
                epsg: epsg,
                datum: "WGS84"
            )
        } catch {
            throw .invalidInput("Error al construir UTMCoordinate: \(error)")
        }
    }

    // MARK: - UTM → Geo

    public func toGeodetic(_ utm: UTMCoordinate) throws(GeoError) -> (lat: Double, lon: Double, h: Double) {
        guard (1...60).contains(utm.zone) else { throw .zoneOutOfRange(utm.zone) }

        let y = utm.isNorthernHemisphere ? utm.northing : utm.northing - 10_000_000.0
        let x = utm.easting - 500_000.0

        let m = y / WGS84.k0
        let mu = m / (WGS84.a * (1.0 - WGS84.e2 / 4.0 - 3.0 * WGS84.e4 / 64.0 - 5.0 * WGS84.e6 / 256.0))

        let e1 = (1.0 - sqrt(1.0 - WGS84.e2)) / (1.0 + sqrt(1.0 - WGS84.e2))
        let e12 = e1 * e1
        let e13 = e1 * e12
        let e14 = e12 * e12

        let sin2mu = sin(2 * mu)
        let sin4mu = sin(4 * mu)
        let sin6mu = sin(6 * mu)
        let sin8mu = sin(8 * mu)

        let phi1 = mu
            + (3.0 * e1 / 2.0 - 27.0 * e13 / 32.0) * sin2mu
            + (21.0 * e12 / 16.0 - 55.0 * e14 / 32.0) * sin4mu
            + (151.0 * e13 / 96.0) * sin6mu
            + (1097.0 * e14 / 512.0) * sin8mu

        let sinPhi1 = sin(phi1)
        let cosPhi1 = cos(phi1)
        let tanPhi1 = tan(phi1)
        let nu1 = WGS84.a / sqrt(1.0 - WGS84.e2 * sinPhi1 * sinPhi1)
        let eta12 = WGS84.ep2 * cosPhi1 * cosPhi1

        let t1 = tanPhi1 * tanPhi1
        let t2 = t1 * t1

        let xOverNu = x / nu1
        let xOverNu2 = xOverNu * xOverNu
        let xOverNu4 = xOverNu2 * xOverNu2
        let xOverNu6 = xOverNu4 * xOverNu2

        let lat = phi1
            - (nu1 * tanPhi1 / (nu1 * 1.0)) * (
                xOverNu2 / 2.0
                - (5.0 + 3.0 * t1 + 10.0 * eta12 - 4.0 * eta12 * eta12 - 9.0 * WGS84.ep2) * xOverNu4 / 24.0
                + (61.0 + 90.0 * t1 + 45.0 * t2 + 298.0 * eta12) * xOverNu6 / 720.0
            )

        let lon0 = (Double(utm.zone) * 6.0 - 183.0) * .pi / 180.0
        let lon = lon0
            + (xOverNu
                - (1.0 + 2.0 * t1 + eta12) * xOverNu2 * xOverNu / 6.0
                + (5.0 - 2.0 * eta12 + 28.0 * t1 - 3.0 * eta12 * eta12 + 8.0 * WGS84.ep2 + 24.0 * t2)
                  * xOverNu4 * xOverNu / 120.0
              ) / cosPhi1

        return (
            lat: lat * 180.0 / .pi,
            lon: lon * 180.0 / .pi,
            h: utm.ellipsoidalHeight
        )
    }

    // MARK: - Convergencia meridiana

    public func meridianConvergence(latitude lat: Double, longitude lon: Double, zone: Int) -> Double {
        let latRad = lat * .pi / 180.0
        let lon0 = (Double(zone) * 6.0 - 183.0) * .pi / 180.0
        let dl = lon * .pi / 180.0 - lon0

        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let tanLat = tan(latRad)
        let eta2 = WGS84.ep2 * cosLat * cosLat

        let t = tanLat * tanLat

        let dl2 = dl * dl
        let dl4 = dl2 * dl2

        var gamma = dl * sinLat
        gamma += dl * dl2 / 3.0 * sinLat * cosLat * cosLat * (1.0 + 3.0 * eta2 + 2.0 * eta2 * eta2)
        gamma += dl * dl4 / 15.0 * sinLat * cosLat * cosLat * cosLat * cosLat
            * (2.0 - t)

        return gamma
    }

    /// Fórmula cerrada (sin series en dl) para convergencia meridiana.
    /// Útil como control cruzado en tests.
    public func meridianConvergenceExact(latitude lat: Double, longitude lon: Double, zone: Int) -> Double {
        let latRad = lat * .pi / 180.0
        let lon0 = (Double(zone) * 6.0 - 183.0) * .pi / 180.0
        let dl = lon * .pi / 180.0 - lon0

        let sinLat = sin(latRad)
        let cosLat = cos(latRad)
        let sinDl = sin(dl)
        let cosDl = cos(dl)

        let eta2 = WGS84.ep2 * cosLat * cosLat

        let denom = cosDl + eta2 * cosDl / cosLat
        let num = sinLat * sinDl
        return atan2(num, denom)
    }

    // MARK: - Selección automática de huso

    private static func zoneFrom(lon: Double) -> Int {
        var z = Int(floor((lon + 180.0) / 6.0)) + 1
        if z < 1 { z = 1 }
        if z > 60 { z = 60 }
        return z
    }

    // MARK: - Arco meridiano

    private func meridionalArc(_ lat: Double) -> Double {
        let e2 = WGS84.e2
        let e4 = WGS84.e4
        let e6 = WGS84.e6

        let a = WGS84.a

        let a0 = 1.0 - e2 / 4.0 - 3.0 * e4 / 64.0 - 5.0 * e6 / 256.0
        let a2 = 3.0 / 8.0 * (e2 + e4 / 4.0 + 15.0 * e6 / 128.0)
        let a4 = 15.0 / 256.0 * (e4 + 3.0 * e6 / 4.0)
        let a6 = 35.0 * e6 / 3072.0

        return a * (
            a0 * lat
            - a2 * sin(2.0 * lat)
            + a4 * sin(4.0 * lat)
            - a6 * sin(6.0 * lat)
        )
    }
}

extension UTMConverter: GeodeticConverting {}