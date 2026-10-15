import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// F1 — Resultados, protocolos de dominio y tipos de contrato de §2.E.
// Cero imports de framework.
// ═══════════════════════════════════════════════════════════════════════════════

public enum OrientationConstraint: Sendable, Codable, Equatable {
    case none
    case horizontal(maxTiltDegrees: Float)
    case vertical(maxTiltDegrees: Float)
    case nearNormal(SIMD3<Float>, toleranceDegrees: Float)
}

public enum Scoring: String, Sendable, Codable {
    case inlierCount
    case msac
}

public struct PlaneFitOptions: Sendable, Codable, Equatable {
    public var maxIterations: Int
    public var inlierDistance: Float
    public var minInliers: Int
    public var constraint: OrientationConstraint
    public var scoring: Scoring
    public var confidence: Float
    public var rngSeed: UInt64

    public init(
        maxIterations: Int = 500,
        inlierDistance: Float = 0.02,
        minInliers: Int = 50,
        constraint: OrientationConstraint = .none,
        scoring: Scoring = .msac,
        confidence: Float = 0.99,
        rngSeed: UInt64 = 0x9E3779B97F4A7C15
    ) {
        self.maxIterations = maxIterations
        self.inlierDistance = inlierDistance
        self.minInliers = minInliers
        self.constraint = constraint
        self.scoring = scoring
        self.confidence = confidence
        self.rngSeed = rngSeed
    }
}

/// PRNG determinista (SplitMix64) para que RANSAC sea reproducible bit a bit.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Plane fitting

public protocol PlaneFitting: Sendable {
    static var algorithmVersion: String { get }
    func fit(
        points: [SIMD3<Float>],
        normals: [SIMD3<Float>]?,
        options: PlaneFitOptions
    ) throws(GeometryError) -> Plane
}

public protocol BoxFitting: Sendable {
    func fit(points: [SIMD3<Float>], gravityAlignedUpAxis: Bool) throws(GeometryError) -> OrientedBox
}

// MARK: - Volume

public enum EmptyCellStrategy: Sendable, Codable, Equatable {
    case ignore
    case fillInteriorHoles
}

public enum ReferenceSurface: Sendable {
    case plane(Plane)
    case quadric(QuadricSurface)
    case priorScan(Mesh, alignment: Matrix4x4)
    case mirror(plane: Plane)
    case closedSolid
}

/// Superficie cuadrática bicuadrática ajustada al anillo intacto.
public struct QuadricSurface: Sendable, Equatable {
    /// z(u,v) = a·u² + b·v² + c·uv + d·u + e·v + f, con (u,v) en el plano de apoyo.
    public var coefficients: SIMD6<Double>
    public var frame: Matrix4x4
    public var inlierRMS: Double

    public init(coefficients: SIMD6<Double>, frame: Matrix4x4, inlierRMS: Double) {
        self.coefficients = coefficients
        self.frame = frame
        self.inlierRMS = inlierRMS
    }

    public func height(u: Double, v: Double) -> Double {
        let c = coefficients
        let quad = c[0] * u * u
        let quadV = c[1] * v * v
        let crossTerm = c[2] * u * v
        let linear = c[3] * u + c[4] * v
        return quad + quadV + crossTerm + linear + c[5]
    }
}

public protocol VolumeIntegrating: Sendable {
    static var algorithmVersion: String { get }
    func integrate(
        mesh: Mesh,
        reference: ReferenceSurface,
        cellSize: Float,
        emptyCells: EmptyCellStrategy
    ) throws(VolumeError) -> VolumeResult
}

public struct WatertightnessReport: Sendable, Equatable {
    public var isWatertight: Bool
    public var boundaryEdges: Int
    public var vertexCount: Int
    public var faceCount: Int
    public var eulerCharacteristic: Int

    public init(isWatertight: Bool, boundaryEdges: Int, vertexCount: Int, faceCount: Int, eulerCharacteristic: Int) {
        self.isWatertight = isWatertight
        self.boundaryEdges = boundaryEdges
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        self.eulerCharacteristic = eulerCharacteristic
    }
}

public protocol MeshClosing: Sendable {
    func close(mesh: Mesh, against plane: Plane?) throws(MeshError) -> (mesh: Mesh, report: WatertightnessReport)
}

// MARK: - Segmentation

public struct SegmentationOptions: Sendable, Equatable {
    public var maxDihedralAngleDegrees: Float
    public var maxDistance: Float
    public var minComponentSize: Int
    public var contactDistanceThreshold: Float

    public init(
        maxDihedralAngleDegrees: Float = 45,
        maxDistance: Float = 0.02,
        minComponentSize: Int = 50,
        contactDistanceThreshold: Float = 0.01
    ) {
        self.maxDihedralAngleDegrees = maxDihedralAngleDegrees
        self.maxDistance = maxDistance
        self.minComponentSize = minComponentSize
        self.contactDistanceThreshold = contactDistanceThreshold
    }
}

public struct SegmentedComponent: Sendable, Equatable {
    public var vertexIndices: [UInt32]
    public var box: OrientedBox
    public var triangleCount: Int
    public var classificationHint: String?

    public init(vertexIndices: [UInt32], box: OrientedBox, triangleCount: Int, classificationHint: String? = nil) {
        self.vertexIndices = vertexIndices
        self.box = box
        self.triangleCount = triangleCount
        self.classificationHint = classificationHint
    }
}

public protocol MeshSegmenting: Sendable {
    func segment(
        mesh: Mesh,
        roi: OrientedBox?,
        removingPlane: Plane?,
        options: SegmentationOptions
    ) throws(SegmentationError) -> [SegmentedComponent]
}

// MARK: - Geo

public protocol LocationProviding: AnyObject, Sendable {
    var fixes: AsyncStream<GeoFix> { get }
    func start() async throws(GeoError)
    func stop()
}

public protocol GeodeticConverting: Sendable {
    func toUTM(latitude: Double, longitude: Double, height: Double) throws(GeoError) -> UTMCoordinate
    func toGeodetic(_ utm: UTMCoordinate) throws(GeoError) -> (lat: Double, lon: Double, h: Double)
    func meridianConvergence(latitude: Double, longitude: Double, zone: Int) -> Double
}

public protocol SiteFrameResolving: Sendable {
    func resolve(
        cameraTrack: [(time: Date, transform: Matrix4x4)],
        fixes: [GeoFix],
        magneticHeading: Double?
    ) throws(GeoError) -> (frame: SiteFrame, arWorldToSite: Matrix4x4)
}

// MARK: - Registration

public enum InitMethod: String, Sendable, Codable {
    case controlTargets
    case landmarks
    case geodetic
}

/// Uno de los 6 grados de libertad del calce rígido, etiquetado por el eje
/// donde domina la componente de un autovector del Hessiano punto-a-plano
/// (ver `ICPAligner.computeConditionNumber`, fixes.md). El autovector real
/// casi nunca es un eje puro — esta es una clasificación por componente
/// dominante, pensada para que un informe pericial pueda decir "la
/// traslación en X y la rotación en Z no quedaron restringidas por este
/// calce" en vez de solo un número de condición sin explicación.
public enum DegenerateAxis: String, Sendable, Codable, Equatable {
    case translationX, translationY, translationZ
    case rotationX, rotationY, rotationZ
}

/// Una dirección del espacio de 6 grados de libertad débilmente restringida
/// por las correspondencias del calce — el eje dominante del autovector y
/// el valor singular asociado (raíz del autovalor del Hessiano; pequeño =
/// poco informativo, no necesariamente cero).
public struct WeakDirection: Sendable, Codable, Equatable {
    public var axis: DegenerateAxis
    public var sigma: Float

    public init(axis: DegenerateAxis, sigma: Float) {
        self.axis = axis
        self.sigma = sigma
    }
}

public struct AlignmentResult: Sendable, Codable, Equatable {
    public var transform: Matrix4x4
    public var rmse: Float
    public var inlierRatio: Float
    public var iterations: Int
    public var conditionNumber: Float
    public var isDegenerate: Bool
    public var initializationMethod: InitMethod
    /// Direcciones del espacio de 6-DOF que dominan el número de condición
    /// (ver `WeakDirection`). Vacío cuando `isDegenerate` es `false`.
    public var weakDirections: [WeakDirection]

    public init(
        transform: Matrix4x4,
        rmse: Float,
        inlierRatio: Float,
        iterations: Int,
        conditionNumber: Float,
        isDegenerate: Bool,
        initializationMethod: InitMethod,
        weakDirections: [WeakDirection] = []
    ) {
        self.transform = transform
        self.rmse = rmse
        self.inlierRatio = inlierRatio
        self.iterations = iterations
        self.conditionNumber = conditionNumber
        self.isDegenerate = isDegenerate
        self.initializationMethod = initializationMethod
        self.weakDirections = weakDirections
    }
}

public struct ChangeCluster: Sendable, Codable, Equatable {
    public var centroid: SIMD3<Float>
    public var volume: Double
    public var vertexCount: Int
    public var sign: ChangeSign

    public init(centroid: SIMD3<Float>, volume: Double, vertexCount: Int, sign: ChangeSign) {
        self.centroid = centroid
        self.volume = volume
        self.vertexCount = vertexCount
        self.sign = sign
    }
}

public enum ChangeSign: String, Sendable, Codable {
    case lost
    case gained
}

public struct DiffResult: Sendable, Codable, Equatable {
    public var alignment: AlignmentResult
    public var signedDistances: [Float]
    public var changeThreshold: Float
    public var lostVolume: Double
    public var gainedVolume: Double
    public var volumeUncertainty: Double
    public var clusters: [ChangeCluster]
    public var noiseFloor: Float

    public init(
        alignment: AlignmentResult,
        signedDistances: [Float],
        changeThreshold: Float,
        lostVolume: Double,
        gainedVolume: Double,
        volumeUncertainty: Double,
        clusters: [ChangeCluster],
        noiseFloor: Float
    ) {
        self.alignment = alignment
        self.signedDistances = signedDistances
        self.changeThreshold = changeThreshold
        self.lostVolume = lostVolume
        self.gainedVolume = gainedVolume
        self.volumeUncertainty = volumeUncertainty
        self.clusters = clusters
        self.noiseFloor = noiseFloor
    }
}

/// Máscara de región estable: complemento de la zona de cambio esperado.
public struct RegionMask: Sendable {
    public var stableRegion: OrientedBox?

    public init(stableRegion: OrientedBox?) {
        self.stableRegion = stableRegion
    }
}

public struct ICPOptions: Sendable {
    public var voxelSizes: [Float]
    public var maxIterations: Int
    public var maxCorrespondenceDistance: Float
    public var normalCompatibilityAngleDegrees: Float
    public var trimmedOutlierFraction: Float
    public var degeneracyConditionThreshold: Float

    public init(
        voxelSizes: [Float] = [0.20, 0.10, 0.05],
        maxIterations: Int = 50,
        maxCorrespondenceDistance: Float = 0.10,
        normalCompatibilityAngleDegrees: Float = 45,
        trimmedOutlierFraction: Float = 0.25,
        degeneracyConditionThreshold: Float = 1e6
    ) {
        self.voxelSizes = voxelSizes
        self.maxIterations = maxIterations
        self.maxCorrespondenceDistance = maxCorrespondenceDistance
        self.normalCompatibilityAngleDegrees = normalCompatibilityAngleDegrees
        self.trimmedOutlierFraction = trimmedOutlierFraction
        self.degeneracyConditionThreshold = degeneracyConditionThreshold
    }
}

public protocol MeshRegistering: Sendable {
    static var algorithmVersion: String { get }
    func align(
        source: Mesh,
        target: Mesh,
        initial: Matrix4x4,
        stableRegionMask: RegionMask?,
        options: ICPOptions
    ) throws(RegistrationError) -> AlignmentResult
}

public protocol MeshDifferencing: Sendable {
    func diff(
        baseline: Mesh,
        current: Mesh,
        alignment: AlignmentResult,
        cellSize: Float
    ) throws(RegistrationError) -> DiffResult
}

// MARK: - Custody

public struct FileDigest: Sendable, Codable, Equatable {
    public var relativePath: String
    public var bytes: Int64
    public var sha256: String

    public init(relativePath: String, bytes: Int64, sha256: String) {
        self.relativePath = relativePath
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct SealRecord: Sendable, Codable, Equatable {
    public var index: Int
    public var prevSealHash: String?
    public var rootHash: String
    public var manifest: [FileDigest]
    public var geo: GeoFix?
    public var author: AuthorIdentity
    public var deviceKeyID: String
    public var publicKeyDER: Data
    public var signatureDER: Data
    public var wallClock: Date
    public var monotonicDeltaSincePrevious: TimeInterval?
    public var gnssTime: Date?
    public var rfc3161Token: Data?

    public init(
        index: Int,
        prevSealHash: String?,
        rootHash: String,
        manifest: [FileDigest],
        geo: GeoFix?,
        author: AuthorIdentity,
        deviceKeyID: String,
        publicKeyDER: Data,
        signatureDER: Data,
        wallClock: Date,
        monotonicDeltaSincePrevious: TimeInterval?,
        gnssTime: Date?,
        rfc3161Token: Data?
    ) {
        self.index = index
        self.prevSealHash = prevSealHash
        self.rootHash = rootHash
        self.manifest = manifest
        self.geo = geo
        self.author = author
        self.deviceKeyID = deviceKeyID
        self.publicKeyDER = publicKeyDER
        self.signatureDER = signatureDER
        self.wallClock = wallClock
        self.monotonicDeltaSincePrevious = monotonicDeltaSincePrevious
        self.gnssTime = gnssTime
        self.rfc3161Token = rfc3161Token
    }
}

public enum CustodyVerdict: Sendable, Equatable {
    case valid
    case invalid([CustodyError])

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

public protocol Sealing: Sendable {
    func seal(bundleAt url: URL, author: AuthorIdentity, geo: GeoFix?) async throws(CustodyError) -> SealRecord
}

public protocol ChainVerifying: Sendable {
    func verify(bundleAt url: URL) async throws(CustodyError) -> CustodyVerdict
}

// MARK: - Persistence

public protocol FindingStoring: Sendable {
    func createFinding(_ finding: Finding) async throws(StoreError) -> URL
    func appendScan(_ scan: ScanSession, mesh: Mesh, to findingID: UUID) async throws(StoreError) -> URL
    func loadMesh(scanID: UUID, findingID: UUID) async throws(StoreError) -> Mesh
    func listFindings() async throws(StoreError) -> [FindingSummary]
    func rebuildIndex() async throws(StoreError)
}

// MARK: - Export

public enum ExportFormat: String, Sendable, Codable {
    case plyBinary
    case stlBinary
    case obj
    case usdz
    case las14
    case geoJSON
    case kml
    case csv
    case pdfReport
}

public struct ExportMetadata: Sendable {
    public var finding: Finding
    public var scan: ScanSession?
    public var utm: UTMCoordinate?
    public var scaleUnits: String?
    public var precisionProfile: ExportPrecisionProfile
    public var recordSidecar: RecordSidecar?

    public init(
        finding: Finding,
        scan: ScanSession?,
        utm: UTMCoordinate?,
        scaleUnits: String?,
        precisionProfile: ExportPrecisionProfile = .exact,
        recordSidecar: RecordSidecar? = nil
    ) {
        self.finding = finding
        self.scan = scan
        self.utm = utm
        self.scaleUnits = scaleUnits
        self.precisionProfile = precisionProfile
        self.recordSidecar = recordSidecar
    }
}

/// Perfil de precisión de la ubicación en exports (evita facilitar el saqueo).
public enum ExportPrecisionProfile: String, Sendable, Codable {
    case exact
    case degraded
    case omitted
}

public struct ExportSidecar: Sendable {
    public var fileURL: URL
    public var recordURL: URL

    public init(fileURL: URL, recordURL: URL) {
        self.fileURL = fileURL
        self.recordURL = recordURL
    }
}

public protocol MeshExporting: Sendable {
    var format: ExportFormat { get }
    /// Debe ser byte-determinista: misma entrada ⇒ mismos bytes.
    func write(mesh: Mesh, metadata: ExportMetadata, to url: URL) throws(ExportError) -> ExportSidecar
}

// MARK: - Record sidecar

public struct AlgorithmRun: Sendable, Codable, Equatable {
    public var name: String
    public var algorithmVersion: String
    public var parameters: [String: String]
    public var rngSeed: UInt64?
    public var effectiveIterations: Int?
    public var inlierCount: Int?
    public var residualRMS: Float?

    public init(
        name: String,
        algorithmVersion: String,
        parameters: [String: String],
        rngSeed: UInt64? = nil,
        effectiveIterations: Int? = nil,
        inlierCount: Int? = nil,
        residualRMS: Float? = nil
    ) {
        self.name = name
        self.algorithmVersion = algorithmVersion
        self.parameters = parameters
        self.rngSeed = rngSeed
        self.effectiveIterations = effectiveIterations
        self.inlierCount = inlierCount
        self.residualRMS = residualRMS
    }
}

public struct RecordSidecar: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var appVersion: String
    public var buildID: String
    public var device: DeviceInfo
    public var capture: CaptureStats
    public var geo: GeoStats
    public var algorithms: [AlgorithmRun]
    public var measurements: [Measurement]
    public var custody: CustodyStats?
    public var authorship: AuthorIdentity
    public var disclaimer: String

    public init(
        schemaVersion: Int = 1,
        appVersion: String,
        buildID: String,
        device: DeviceInfo,
        capture: CaptureStats,
        geo: GeoStats,
        algorithms: [AlgorithmRun],
        measurements: [Measurement],
        custody: CustodyStats?,
        authorship: AuthorIdentity,
        disclaimer: String = RecordSidecar.defaultDisclaimer
    ) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.buildID = buildID
        self.device = device
        self.capture = capture
        self.geo = geo
        self.algorithms = algorithms
        self.measurements = measurements
        self.custody = custody
        self.authorship = authorship
        self.disclaimer = disclaimer
    }

    public static let defaultDisclaimer =
        "Este registro se generó con GPS del dispositivo y no constituye un levantamiento " +
        "geodésico. Las mediciones métricas relativas provienen del sensor LiDAR; la " +
        "ubicación absoluta tiene la precisión declarada del receptor GPS del iPhone."

    public struct DeviceInfo: Sendable, Codable, Equatable {
        public var model: String
        public var osVersion: String
        public var hasLiDAR: Bool
        public var arKitVersion: String

        public init(model: String, osVersion: String, hasLiDAR: Bool, arKitVersion: String) {
            self.model = model
            self.osVersion = osVersion
            self.hasLiDAR = hasLiDAR
            self.arKitVersion = arKitVersion
        }
    }

    public struct DistanceRange: Sendable, Codable, Equatable {
        public var min: Double
        public var max: Double

        public init(min: Double, max: Double) {
            self.min = min
            self.max = max
        }
    }

    public struct CaptureStats: Sendable, Codable, Equatable {
        public var duration: TimeInterval
        public var anchorCount: Int
        public var coverageFraction: Double
        public var distanceRange: DistanceRange?
        public var trackingEvents: [String]
        public var thermalState: String
        public var depthConfidenceStats: DepthConfidenceStats

        public init(
            duration: TimeInterval,
            anchorCount: Int,
            coverageFraction: Double,
            distanceRange: DistanceRange? = nil,
            trackingEvents: [String] = [],
            thermalState: String = "nominal",
            depthConfidenceStats: DepthConfidenceStats = DepthConfidenceStats()
        ) {
            self.duration = duration
            self.anchorCount = anchorCount
            self.coverageFraction = coverageFraction
            self.distanceRange = distanceRange
            self.trackingEvents = trackingEvents
            self.thermalState = thermalState
            self.depthConfidenceStats = depthConfidenceStats
        }
    }

    public struct DepthConfidenceStats: Sendable, Codable, Equatable {
        public var lowFraction: Double
        public var mediumFraction: Double
        public var highFraction: Double

        public init(lowFraction: Double = 0, mediumFraction: Double = 0, highFraction: Double = 0) {
            self.lowFraction = lowFraction
            self.mediumFraction = mediumFraction
            self.highFraction = highFraction
        }
    }

    public struct GeoStats: Sendable, Codable, Equatable {
        public var fixCount: Int
        public var chosenFix: GeoFix?
        public var utm: UTMCoordinate?
        public var meridianConvergence: Double
        public var yawMethod: String
        public var yawSigma: Double?
        public var quality: GeoreferenceQuality

        public init(
            fixCount: Int,
            chosenFix: GeoFix?,
            utm: UTMCoordinate?,
            meridianConvergence: Double,
            yawMethod: String,
            yawSigma: Double?,
            quality: GeoreferenceQuality
        ) {
            self.fixCount = fixCount
            self.chosenFix = chosenFix
            self.utm = utm
            self.meridianConvergence = meridianConvergence
            self.yawMethod = yawMethod
            self.yawSigma = yawSigma
            self.quality = quality
        }
    }

    public struct CustodyStats: Sendable, Codable, Equatable {
        public var rootHash: String
        public var sealIndex: Int
        public var deviceKeyID: String
        public var publicKeyDER: Data
        public var signatureDER: Data
        public var wallClock: Date
        public var monotonicDelta: TimeInterval?
        public var gnssTime: Date?

        public init(
            rootHash: String,
            sealIndex: Int,
            deviceKeyID: String,
            publicKeyDER: Data,
            signatureDER: Data,
            wallClock: Date,
            monotonicDelta: TimeInterval?,
            gnssTime: Date?
        ) {
            self.rootHash = rootHash
            self.sealIndex = sealIndex
            self.deviceKeyID = deviceKeyID
            self.publicKeyDER = publicKeyDER
            self.signatureDER = signatureDER
            self.wallClock = wallClock
            self.monotonicDelta = monotonicDelta
            self.gnssTime = gnssTime
        }
    }
}

// MARK: - Coverage / Tracking / Capture

public struct CoverageSnapshot: Sendable, Equatable {
    public var coveredArea: Double
    public var fraction: Double
    public var anchorCount: Int
    public var vertexCount: Int

    public init(coveredArea: Double, fraction: Double, anchorCount: Int, vertexCount: Int) {
        self.coveredArea = coveredArea
        self.fraction = fraction
        self.anchorCount = anchorCount
        self.vertexCount = vertexCount
    }
}

public enum TrackingEvent: Sendable, Equatable {
    case normal
    case limited(reason: String)
    case relocalizing
}

public struct CaptureBundle: Sendable {
    public var mesh: Mesh
    public var cameraTrack: [(time: Date, transform: Matrix4x4)]
    public var fixes: [GeoFix]
    public var depthCloud: DepthCloud
    public var coverage: CoverageSnapshot

    public init(
        mesh: Mesh,
        cameraTrack: [(time: Date, transform: Matrix4x4)],
        fixes: [GeoFix],
        depthCloud: DepthCloud,
        coverage: CoverageSnapshot
    ) {
        self.mesh = mesh
        self.cameraTrack = cameraTrack
        self.fixes = fixes
        self.depthCloud = depthCloud
        self.coverage = coverage
    }
}

/// Nube densa derivada de sceneDepth + confidenceMap (mediciones finas).
public struct DepthCloud: Sendable, Equatable {
    public var positions: [SIMD3<Float>]
    public var confidence: [Float]
    public var timestamps: [TimeInterval]

    public init(positions: [SIMD3<Float>] = [], confidence: [Float] = [], timestamps: [TimeInterval] = []) {
        self.positions = positions
        self.confidence = confidence
        self.timestamps = timestamps
    }

    public var count: Int { positions.count }
    public var isEmpty: Bool { positions.isEmpty }
}

// MARK: - Capture / Rendering (protocolos)

public protocol MeshCapturing: AnyObject {
    var coverage: AsyncStream<CoverageSnapshot> { get }
    var trackingEvents: AsyncStream<TrackingEvent> { get }
    func start(purpose: ScanPurpose) throws(CaptureError)
    func finish() async throws(CaptureError) -> CaptureBundle
}

public enum ColorPalette: Sendable {
    case confidence
    case signedDistance
    case stratum
    case custom([SIMD4<UInt8>])
}

// MARK: - Quality / Diagnostics

public struct QualityReport: Sendable, Codable, Equatable {
    public var scanID: UUID
    public var exceededDurationLimit: Bool
    public var exceededAreaLimit: Bool
    public var thermalDegraded: Bool
    public var lowCoverage: Bool
    public var directSunSaturation: Bool
    public var notes: [String]

    public init(
        scanID: UUID,
        exceededDurationLimit: Bool,
        exceededAreaLimit: Bool,
        thermalDegraded: Bool,
        lowCoverage: Bool,
        directSunSaturation: Bool,
        notes: [String]
    ) {
        self.scanID = scanID
        self.exceededDurationLimit = exceededDurationLimit
        self.exceededAreaLimit = exceededAreaLimit
        self.thermalDegraded = thermalDegraded
        self.lowCoverage = lowCoverage
        self.directSunSaturation = directSunSaturation
        self.notes = notes
    }
}