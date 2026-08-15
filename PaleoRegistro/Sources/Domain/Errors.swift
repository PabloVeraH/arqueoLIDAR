import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// F1 — Errores tipados. Nunca `try?` silencioso ni valores centinela.
// ═══════════════════════════════════════════════════════════════════════════════

public enum GeometryError: Error, Equatable, Sendable {
    case insufficientPoints(Int)
    case degenerateConfiguration(String)
    case noConsensus
    case colinearPoints
    case invalidInput(String)
    case notImplemented(String)
}

public enum VolumeError: Error, Equatable, Sendable {
    case meshNotClosed
    case emptyMesh
    case invalidCellSize(Float)
    case invalidReferenceSurface(String)
    case notEnoughData(String)
    case inferenceImpossible(String)
}

public enum MeshError: Error, Equatable, Sendable {
    case indexOutOfRange
    case degenerateTriangle
    case nonManifold
    case invalidInput(String)
    case closingFailed(String)
}

public enum SegmentationError: Error, Equatable, Sendable {
    case invalidROI
    case emptyComponent
    case manualOperationFailed(String)
}

public enum GeoError: Error, Equatable, Sendable {
    case zoneOutOfRange(Int)
    case latitudeOutOfRange(Double)
    case longitudeOutOfRange(Double)
    case noFixAvailable
    case fixQualityInsufficient(Double, Double)
    case degenerateTrack(String)
    case unsupportedZone(Int)
    case invalidInput(String)
}

public enum RegistrationError: Error, Equatable, Sendable {
    case degenerate(conditionNumber: Float)
    case notConverged
    case insufficientCorrespondences(Int)
    case invalidInput(String)
}

public enum CustodyError: Error, Equatable, Sendable {
    case bundleNotFound
    case hashMismatch(String)
    case chainBroken(index: Int, reason: String)
    case manifestTampered
    case extraFileNotDeclared(String)
    case sealedDirectoryImmutable
    case signingFailed(String)
    case verificationFailed(String)
    case invalidSeal(String)
}

public enum StoreError: Error, Equatable, Sendable {
    case findingNotFound(UUID)
    case scanNotFound(UUID)
    case writeFailed(String)
    case bundleCorrupt(String)
    case sealedImmutable
    case invalidBundleLayout(String)
}

public enum ExportError: Error, Equatable, Sendable {
    case writeFailed(String)
    case missingMetadata(String)
    case missingSidecar
    case meshNotClosed
    case unsupportedFormat(String)
    case invalidCoordinate
    case scaleUndefined
}

public enum CaptureError: Error, Equatable, Sendable {
    case deviceUnsupported
    case sessionFailed(String)
    case userCanceled
    case trackingLost
    case storageInsufficient
    case thermalLimit
}

public enum StratigraphyError: Error, Equatable, Sendable {
    case wallPlaneNotFound
    case noOrthoImage
    case invalidBoundaryOrder
    case thicknessBelowConfidence
}
/// Error de validación de invariantes en inicializadores de tipos de dominio.
public enum DomainValidationError: Error, Equatable, Sendable {
    case zeroNormal
    case negativeHalfExtent
    case nonOrthonormalAxes
    case invalidZone(Int)
    case negativeCoordinate
    case negativeAccuracy
    case latitudeOutOfRange(Double)
    case longitudeOutOfRange(Double)
}
