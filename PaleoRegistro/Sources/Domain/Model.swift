import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// F1 — Modelo de datos (jerarquía de §2.B): Site → Finding → ScanSession → …
// Bundle en disco como fuente de verdad; SwiftData solo como índice derivado.
// ═══════════════════════════════════════════════════════════════════════════════

/// Notificación al CMN (Ley 17.288). Parte del expediente legal.
public struct CMNNotification: Sendable, Codable, Equatable {
    public var date: Date
    public var channel: String
    public var folio: String?

    public init(date: Date, channel: String, folio: String?) {
        self.date = date
        self.channel = channel
        self.folio = folio
    }
}

/// Permiso CMN cuando aplica (registrado, no gestionado por la app).
public struct CMNPermit: Sendable, Codable, Equatable {
    public var number: String
    public var institution: String

    public init(number: String, institution: String) {
        self.number = number
        self.institution = institution
    }
}

public struct Site: Sendable, Codable, Equatable {
    public var siteID: UUID
    public var name: String
    public var code: String
    public var siteFrame: SiteFrame?
    public var createdAt: Date

    public init(siteID: UUID = UUID(), name: String, code: String, siteFrame: SiteFrame? = nil, createdAt: Date = Date()) {
        self.siteID = siteID
        self.name = name
        self.code = code
        self.siteFrame = siteFrame
        self.createdAt = createdAt
    }
}

public struct Finding: Sendable, Codable, Equatable {
    public var findingID: UUID
    public var siteID: UUID
    public var title: String
    public var expeditionCode: String
    public var schemaVersion: Int
    public var author: AuthorIdentity
    public var permit: CMNPermit?
    public var cmnNotification: CMNNotification?
    public var createdAt: Date
    public var georeferenceQuality: GeoreferenceQuality

    public init(
        findingID: UUID = UUID(),
        siteID: UUID,
        title: String,
        expeditionCode: String,
        schemaVersion: Int = 1,
        author: AuthorIdentity,
        permit: CMNPermit? = nil,
        cmnNotification: CMNNotification? = nil,
        createdAt: Date = Date(),
        georeferenceQuality: GeoreferenceQuality = .unvalidated
    ) {
        self.findingID = findingID
        self.siteID = siteID
        self.title = title
        self.expeditionCode = expeditionCode
        self.schemaVersion = schemaVersion
        self.author = author
        self.permit = permit
        self.cmnNotification = cmnNotification
        self.createdAt = createdAt
        self.georeferenceQuality = georeferenceQuality
    }
}

public struct AuthorIdentity: Sendable, Codable, Equatable {
    public var name: String
    public var role: String
    public var institution: String
    public var cmnPermitNumber: String?

    public init(name: String, role: String, institution: String, cmnPermitNumber: String? = nil) {
        self.name = name
        self.role = role
        self.institution = institution
        self.cmnPermitNumber = cmnPermitNumber
    }
}

/// Especificación de captura persistida en scan.json (reproducibilidad).
public struct CaptureParameters: Sendable, Codable, Equatable {
    public var sceneReconstruction: String
    public var frameSemantics: [String]
    public var worldAlignment: String
    public var minDepthConfidence: Float
    public var durationLimit: TimeInterval?

    public init(
        sceneReconstruction: String = "meshWithClassification",
        frameSemantics: [String] = ["sceneDepth", "smoothedSceneDepth"],
        worldAlignment: String = "gravity",
        minDepthConfidence: Float = 0.5,
        durationLimit: TimeInterval? = nil
    ) {
        self.sceneReconstruction = sceneReconstruction
        self.frameSemantics = frameSemantics
        self.worldAlignment = worldAlignment
        self.minDepthConfidence = minDepthConfidence
        self.durationLimit = durationLimit
    }
}

public struct ScanSession: Sendable, Codable, Equatable {
    public var scanID: UUID
    public var findingID: UUID
    public var purpose: ScanPurpose
    public var parentScanID: UUID?
    public var supersedes: UUID?
    public var capturedAt: Date
    public var captureParameters: CaptureParameters
    public var georeferenceQuality: GeoreferenceQuality
    public var siteAlignment: Matrix4x4
    public var sealed: Bool
    public var sealedAt: Date?

    public init(
        scanID: UUID = UUID(),
        findingID: UUID,
        purpose: ScanPurpose,
        parentScanID: UUID? = nil,
        supersedes: UUID? = nil,
        capturedAt: Date = Date(),
        captureParameters: CaptureParameters = CaptureParameters(),
        georeferenceQuality: GeoreferenceQuality = .unvalidated,
        siteAlignment: Matrix4x4 = Matrix4x4.identity,
        sealed: Bool = false,
        sealedAt: Date? = nil
    ) {
        self.scanID = scanID
        self.findingID = findingID
        self.purpose = purpose
        self.parentScanID = parentScanID
        self.supersedes = supersedes
        self.capturedAt = capturedAt
        self.captureParameters = captureParameters
        self.georeferenceQuality = georeferenceQuality
        self.siteAlignment = siteAlignment
        self.sealed = sealed
        self.sealedAt = sealedAt
    }
}

/// Mediciones de un espécimen: dimensiones, volumen, potencia, distancia.
public struct Measurement: Sendable, Codable, Equatable {
    public var measurementID: UUID
    public var scanID: UUID
    public var kind: MeasurementKind
    public var value: Double
    public var unit: String
    public var method: String
    public var isInferred: Bool
    public var uncertainty: Double?
    public var assumptions: [String]?

    public init(
        measurementID: UUID = UUID(),
        scanID: UUID,
        kind: MeasurementKind,
        value: Double,
        unit: String,
        method: String,
        isInferred: Bool,
        uncertainty: Double? = nil,
        assumptions: [String]? = nil
    ) {
        self.measurementID = measurementID
        self.scanID = scanID
        self.kind = kind
        self.value = value
        self.unit = unit
        self.method = method
        self.isInferred = isInferred
        self.uncertainty = uncertainty
        self.assumptions = assumptions
    }
}

public enum MeasurementKind: String, Sendable, Codable {
    case volume
    case thickness
    case distance
    case dimension
    case orientation
    case power
}

public struct Specimen: Sendable, Codable, Equatable {
    public var specimenID: UUID
    public var scanID: UUID
    public var label: String
    public var vertexIndices: [UInt32]?
    public var dedicatedPLYPath: String?
    public var pose: OrientedBox
    public var classificationHint: String?
    public var exposedVolume: Double?
    public var estimatedTotalVolume: Double?
    public var volumeEstimationMethod: String?
    public var volumeEstimationAssumptions: [String]?

    public init(
        specimenID: UUID = UUID(),
        scanID: UUID,
        label: String,
        vertexIndices: [UInt32]? = nil,
        dedicatedPLYPath: String? = nil,
        pose: OrientedBox,
        classificationHint: String? = nil,
        exposedVolume: Double? = nil,
        estimatedTotalVolume: Double? = nil,
        volumeEstimationMethod: String? = nil,
        volumeEstimationAssumptions: [String]? = nil
    ) {
        self.specimenID = specimenID
        self.scanID = scanID
        self.label = label
        self.vertexIndices = vertexIndices
        self.dedicatedPLYPath = dedicatedPLYPath
        self.pose = pose
        self.classificationHint = classificationHint
        self.exposedVolume = exposedVolume
        self.estimatedTotalVolume = estimatedTotalVolume
        self.volumeEstimationMethod = volumeEstimationMethod
        self.volumeEstimationAssumptions = volumeEstimationAssumptions
    }
}

public enum SpecimenRelationKind: String, Sendable, Codable {
    case distance
    case azimuth
    case contact
    case heightDelta
}

/// Relación entre dos especímenes en el marco de sitio.
public struct SpecimenRelation: Sendable, Codable, Equatable {
    public var fromID: UUID
    public var toID: UUID
    public var kind: SpecimenRelationKind
    public var value: Double
    public var unit: String

    public init(fromID: UUID, toID: UUID, kind: SpecimenRelationKind, value: Double, unit: String) {
        self.fromID = fromID
        self.toID = toID
        self.kind = kind
        self.value = value
        self.unit = unit
    }
}

public struct StratigraphicProfile: Sendable, Codable, Equatable {
    public var profileID: UUID
    public var scanID: UUID
    public var wallPlane: Plane
    public var orthoImagePath: String?
    public var boundaries: [StratumBoundary]
    public var thicknesses: [StratumThickness]

    public init(
        profileID: UUID = UUID(),
        scanID: UUID,
        wallPlane: Plane,
        orthoImagePath: String? = nil,
        boundaries: [StratumBoundary] = [],
        thicknesses: [StratumThickness] = []
    ) {
        self.profileID = profileID
        self.scanID = scanID
        self.wallPlane = wallPlane
        self.orthoImagePath = orthoImagePath
        self.boundaries = boundaries
        self.thicknesses = thicknesses
    }
}

public struct StratumBoundary: Sendable, Codable, Equatable {
    public var boundaryID: UUID
    public var position: SIMD3<Float>
    public var imagePoint: SIMD2<Float>?

    public init(boundaryID: UUID = UUID(), position: SIMD3<Float>, imagePoint: SIMD2<Float>? = nil) {
        self.boundaryID = boundaryID
        self.position = position
        self.imagePoint = imagePoint
    }
}

public enum ThicknessMethod: String, Sendable, Codable {
    case apparentOnly
    case correctedTrue
}

public struct StratumThickness: Sendable, Codable, Equatable {
    public var boundaryA: UUID
    public var boundaryB: UUID
    /// Potencia real (distancia perpendicular entre planos de estrato), metros.
    public var trueThickness: Double
    /// Potencia aparente (a lo largo de la máxima pendiente de la pared), metros.
    public var apparentThickness: Double
    public var uncertainty: Double
    public var dip: Float
    public var dipDirection: Float
    public var method: ThicknessMethod
    public var algorithmVersion: String

    public init(
        boundaryA: UUID,
        boundaryB: UUID,
        trueThickness: Double,
        apparentThickness: Double,
        uncertainty: Double,
        dip: Float,
        dipDirection: Float,
        method: ThicknessMethod,
        algorithmVersion: String
    ) {
        self.boundaryA = boundaryA
        self.boundaryB = boundaryB
        self.trueThickness = trueThickness
        self.apparentThickness = apparentThickness
        self.uncertainty = uncertainty
        self.dip = dip
        self.dipDirection = dipDirection
        self.method = method
        self.algorithmVersion = algorithmVersion
    }
}

public struct MediaAsset: Sendable, Codable, Equatable {
    public var assetID: UUID
    public var scanID: UUID
    public var path: String
    public var cameraPose: Matrix4x4?
    public var intrinsics: Matrix3x3?
    public var timestamp: Date

    public init(
        assetID: UUID = UUID(),
        scanID: UUID,
        path: String,
        cameraPose: Matrix4x4? = nil,
        intrinsics: Matrix3x3? = nil,
        timestamp: Date = Date()
    ) {
        self.assetID = assetID
        self.scanID = scanID
        self.path = path
        self.cameraPose = cameraPose
        self.intrinsics = intrinsics
        self.timestamp = timestamp
    }
}

/// Comparación (diff) entre dos ScanSession en un mismo Site.
public struct Comparison: Sendable, Codable, Equatable {
    public var comparisonID: UUID
    public var findingID: UUID
    public var baselineScanID: UUID
    public var currentScanID: UUID
    public var result: DiffResult?

    public init(
        comparisonID: UUID = UUID(),
        findingID: UUID,
        baselineScanID: UUID,
        currentScanID: UUID,
        result: DiffResult? = nil
    ) {
        self.comparisonID = comparisonID
        self.findingID = findingID
        self.baselineScanID = baselineScanID
        self.currentScanID = currentScanID
        self.result = result
    }
}

/// Resumen para listados sin abrir mallas (SwiftData/índice derivado).
public struct FindingSummary: Sendable, Codable, Equatable {
    public var findingID: UUID
    public var title: String
    public var expeditionCode: String
    public var createdAt: Date
    public var scanCount: Int
    public var sealedCount: Int
    public var georeferenceQuality: GeoreferenceQuality

    public init(
        findingID: UUID,
        title: String,
        expeditionCode: String,
        createdAt: Date,
        scanCount: Int,
        sealedCount: Int,
        georeferenceQuality: GeoreferenceQuality
    ) {
        self.findingID = findingID
        self.title = title
        self.expeditionCode = expeditionCode
        self.createdAt = createdAt
        self.scanCount = scanCount
        self.sealedCount = sealedCount
        self.georeferenceQuality = georeferenceQuality
    }
}