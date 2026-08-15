import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// F1 — Domain. Tipos puros: cero imports de framework (sin ARKit/SceneKit/UIKit/
// CoreLocation/SwiftData). Invariantes validadas en los inicializadores.
// Convención: geometría en metros, Float en posiciones, Double en acumuladores
// de volumen y coordenadas geodésicas. Marco de sitio ENU: +X Este, +Y Arriba,
// −Z Norte.
// ═══════════════════════════════════════════════════════════════════════════════

public struct Mesh: Sendable, Equatable {
    public var vertices: [SIMD3<Float>]
    public var indices: [UInt32]
    public var normals: [SIMD3<Float>]?
    public var colors: [SIMD4<UInt8>]?

    public init(
        vertices: [SIMD3<Float>] = [],
        indices: [UInt32] = [],
        normals: [SIMD3<Float>]? = nil,
        colors: [SIMD4<UInt8>]? = nil
    ) {
        self.vertices = vertices
        self.indices = indices
        self.normals = normals
        self.colors = colors
    }

    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { vertices.isEmpty || indices.isEmpty }
}

public struct Plane: Sendable, Equatable, Codable {
    public var point: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var inlierRMS: Float?
    public var inlierCount: Int?

    public init(point: SIMD3<Float>, normal: SIMD3<Float>, inlierRMS: Float? = nil, inlierCount: Int? = nil) throws(DomainValidationError) {
        let length = vecLength(normal)
        guard length > 0 else { throw .zeroNormal }
        self.point = point
        self.normal = normal / length
        self.inlierRMS = inlierRMS
        self.inlierCount = inlierCount
    }
}

public struct OrientedBox: Sendable, Codable, Equatable {
    /// Columnas ortonormales de la base, ordenadas por extensión descendente.
    public var center: SIMD3<Float>
    public var axes: Matrix3x3
    public var halfExtents: SIMD3<Float>

    public init(center: SIMD3<Float>, axes: Matrix3x3, halfExtents: SIMD3<Float>) throws(DomainValidationError) {
        guard halfExtents.x >= 0 && halfExtents.y >= 0 && halfExtents.z >= 0 else {
            throw .negativeHalfExtent
        }
        guard vecLength(vecCross(axes[0], axes[1])) > 0.5 else {
            throw .nonOrthonormalAxes
        }
        self.center = center
        self.axes = axes
        self.halfExtents = halfExtents
    }

    public var dimensions: SIMD3<Float> { halfExtents * 2 }

    /// Los 8 vértices de la caja en orden consistente (cuboide).
    public var corners: [SIMD3<Float>] {
        let c = axes.columns
        let s = halfExtents
        let signs: [[Float]] = [
            [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
            [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1],
        ]
        return signs.map { center + c.0 * (s.x * $0[0]) + c.1 * (s.y * $0[1]) + c.2 * (s.z * $0[2]) }
    }

    public func contains(_ p: SIMD3<Float>, tolerance: Float = 0.001) -> Bool {
        let c = axes
        for i in 0..<3 {
            let d = vecDot(p - center, c[i])
            let h = halfExtents[i]
            if abs(d) > h + tolerance { return false }
        }
        return true
    }
}

/// Marco del sitio: ENU con Y arriba (+X Este, +Y Arriba, −Z Norte). Convención ARKit.
public struct SiteFrame: Sendable, Codable, Equatable {
    public var siteID: UUID
    public var origin: UTMCoordinate
    public var yawFromTrueNorth: Float
    public var yawSigma: Float
    public var meridianConvergence: Float

    public init(
        siteID: UUID,
        origin: UTMCoordinate,
        yawFromTrueNorth: Float,
        yawSigma: Float,
        meridianConvergence: Float
    ) {
        self.siteID = siteID
        self.origin = origin
        self.yawFromTrueNorth = yawFromTrueNorth
        self.yawSigma = yawSigma
        self.meridianConvergence = meridianConvergence
    }
}

public struct UTMCoordinate: Sendable, Codable, Equatable {
    public var easting: Double
    public var northing: Double
    public var ellipsoidalHeight: Double
    public var zone: Int
    public var isNorthernHemisphere: Bool
    public var epsg: Int
    public var datum: String

    public init(
        easting: Double,
        northing: Double,
        ellipsoidalHeight: Double,
        zone: Int,
        isNorthernHemisphere: Bool,
        epsg: Int,
        datum: String
    ) throws(DomainValidationError) {
        guard (1...60).contains(zone) else { throw .invalidZone(zone) }
        guard easting >= 0 && northing >= 0 else { throw .negativeCoordinate }
        self.easting = easting
        self.northing = northing
        self.ellipsoidalHeight = ellipsoidalHeight
        self.zone = zone
        self.isNorthernHemisphere = isNorthernHemisphere
        self.epsg = epsg
        self.datum = datum
    }
}

public enum GeoSource: String, Sendable, Codable {
    case coreLocation
    case manual
    case externalReceiver
}

public struct GeoFix: Sendable, Codable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var horizontalAccuracy: Double
    public var verticalAccuracy: Double
    public var timestamp: Date
    public var source: GeoSource

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        timestamp: Date,
        source: GeoSource
    ) throws(DomainValidationError) {
        guard horizontalAccuracy >= 0 else { throw .negativeAccuracy }
        guard verticalAccuracy >= 0 else { throw .negativeAccuracy }
        guard (-90...90).contains(latitude) else { throw .latitudeOutOfRange(latitude) }
        guard (-180...180).contains(longitude) else { throw .longitudeOutOfRange(longitude) }
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.timestamp = timestamp
        self.source = source
    }
}

/// Estado de la georreferenciación; viaja hasta el PDF exportado.
public enum GeoreferenceQuality: String, Sendable, Codable {
    case good
    case degraded
    case unvalidated
}

public enum ScanPurpose: String, Sendable, Codable, CaseIterable {
    case baseline
    case postIntervention
    case monitoring
    case damageAssessment
    case rescueDocumentation
    case specimenInventory
    case stratigraphicProfile
}

public enum VolumeMethod: String, Sendable, Codable {
    case heightField
    case closedMesh
    case cavityRimFit
    case cavityDiff
    case mirrorSymmetry
}

public struct VolumeResult: Sendable, Codable, Equatable {
    public var positive: Double
    public var negative: Double
    public var coveredArea: Double
    public var filledCellRatio: Double
    public var uncertainty: Double
    public var method: VolumeMethod
    public var isInferred: Bool
    public var algorithmVersion: String

    public init(
        positive: Double,
        negative: Double,
        coveredArea: Double,
        filledCellRatio: Double,
        uncertainty: Double,
        method: VolumeMethod,
        isInferred: Bool,
        algorithmVersion: String
    ) {
        self.positive = positive
        self.negative = negative
        self.coveredArea = coveredArea
        self.filledCellRatio = filledCellRatio
        self.uncertainty = uncertainty
        self.method = method
        self.isInferred = isInferred
        self.algorithmVersion = algorithmVersion
    }

    public var net: Double { positive - negative }
}
