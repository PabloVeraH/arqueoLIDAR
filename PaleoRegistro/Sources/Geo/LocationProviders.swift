import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F8 — LocationProviding: implementaciones de referencia del protocolo.
// - ManualCoordinateProvider: coordenada ingresada manualmente (topógrafo).
// ═══════════════════════════════════════════════════════════════════════════════

/// Implementación manual: el topógrafo ingresa una coordenada levantada con GNSS diferencial.
public final class ManualCoordinateProvider: LocationProviding, @unchecked Sendable {
    private let fix: GeoFix
    private var continuation: AsyncStream<GeoFix>.Continuation?

    public init(fix: GeoFix) {
        self.fix = fix
    }

    public var fixes: AsyncStream<GeoFix> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func start() async {
        continuation?.yield(fix)
    }

    public func stop() {
        continuation?.finish()
    }
}