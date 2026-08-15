import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F8 — FixQualityGate: filtro de calidad de fijaciones GPS.
// El burst completo de fijaciones se persiste íntegro (incluidas las
// descartadas), con la razón del descarte. La fijación elegida es la mediana
// ponderada por 1/σ².
// ═══════════════════════════════════════════════════════════════════════════════

public struct FixQualityGate: Sendable {

    private let maxHorizontalAccuracy: Double

    public init(maxHorizontalAccuracy: Double = 10.0) {
        self.maxHorizontalAccuracy = maxHorizontalAccuracy
    }

    /// Cada fijación del burst, con su estado de calidad y razón de descarte.
    public struct QualifiedFix: Sendable, Equatable {
        public var fix: GeoFix
        public var accepted: Bool
        public var rejectionReason: String?

        public init(fix: GeoFix, accepted: Bool, rejectionReason: String? = nil) {
            self.fix = fix
            self.accepted = accepted
            self.rejectionReason = rejectionReason
        }
    }

    /// Resultado de evaluar el burst completo.
    public struct FixVerdict: Sendable, Equatable {
        /// Todas las fijaciones (aceptadas + rechazadas), en orden cronológico.
        public var allFixes: [QualifiedFix] = []
        /// Fijación elegida como representativa del sitio (mediana ponderada).
        public var chosenFix: GeoFix?
        /// Calidad global del burst.
        public var quality: GeoreferenceQuality = .unvalidated
        /// Número de fijaciones aceptadas.
        public var acceptedCount: Int = 0
        /// Número de fijaciones rechazadas.
        public var rejectedCount: Int = 0
        /// Desviación estándar horizontal de las fijaciones aceptadas (m).
        public var horizontalSigma: Double?

        public init() {}
    }

    /// Evalúa el burst completo. No descarta fijaciones del resultado: las
    /// marca como rechazadas con razón, pero las incluye en `allFixes`.
    public func evaluate(burst: [GeoFix]) -> FixVerdict {
        var verdict = FixVerdict()
        var qualified: [QualifiedFix] = []

        for fix in burst {
            if fix.horizontalAccuracy <= 0 {
                qualified.append(QualifiedFix(fix: fix, accepted: false, rejectionReason: "precisión horizontal inválida (≤0)"))
            } else if fix.horizontalAccuracy > maxHorizontalAccuracy {
                qualified.append(QualifiedFix(fix: fix, accepted: false,
                    rejectionReason: "precisión \(fix.horizontalAccuracy.description) m > umbral \(maxHorizontalAccuracy.description) m"))
            } else {
                qualified.append(QualifiedFix(fix: fix, accepted: true))
            }
        }

        let accepted = qualified.filter(\.accepted)

        if !accepted.isEmpty, let chosen = weightedMedian(fixes: accepted.map(\.fix)) {
            let sigma = horizontalDispersion(fixes: accepted.map(\.fix), median: chosen)

            verdict.quality = (sigma ?? 999) < 15.0 ? .good : .degraded
            verdict.chosenFix = chosen
            verdict.horizontalSigma = sigma
        } else {
            verdict.quality = .degraded
        }

        verdict.allFixes = qualified
        verdict.acceptedCount = accepted.count
        verdict.rejectedCount = qualified.count - accepted.count

        return verdict
    }

    /// Mediana ponderada por 1/σ² en lat y lon por separado.
    private func weightedMedian(fixes: [GeoFix]) -> GeoFix? {
        guard !fixes.isEmpty else { return nil }
        guard fixes.count > 1 else { return fixes[0] }

        let weighted = fixes.map { f in (f, 1.0 / (f.horizontalAccuracy * f.horizontalAccuracy)) }
        let totalWeight = weighted.reduce(0) { $0 + $1.1 }

        // Lat
        let sortedLat = weighted.sorted { $0.0.latitude < $1.0.latitude }
        let halfWeight = totalWeight / 2.0
        var cumulative = 0.0
        var medLat = sortedLat[0].0.latitude
        for (fix, w) in sortedLat {
            cumulative += w
            if cumulative >= halfWeight {
                medLat = fix.latitude
                break
            }
        }

        // Lon
        let sortedLon = weighted.sorted { $0.0.longitude < $1.0.longitude }
        cumulative = 0.0
        var medLon = sortedLon[0].0.longitude
        for (fix, w) in sortedLon {
            cumulative += w
            if cumulative >= halfWeight {
                medLon = fix.longitude
                break
            }
        }

        let medAlt = weighted.reduce(0.0) { $0 + $1.0.altitude * $1.1 } / totalWeight
        let medHAcc = weighted.reduce(0.0) { $0 + $1.0.horizontalAccuracy * $1.1 } / totalWeight
        let medVAcc = weighted.reduce(0.0) { $0 + $1.0.verticalAccuracy * $1.1 } / totalWeight

        return try? GeoFix(
            latitude: medLat, longitude: medLon, altitude: medAlt,
            horizontalAccuracy: medHAcc, verticalAccuracy: medVAcc,
            timestamp: fixes.last!.timestamp, source: fixes.first!.source
        )
    }

    /// Desviación estándar horizontal (m) entre las fijaciones y la mediana.
    /// Conversión aproximada deg→m: 1° lat ≈ 111 320 m, 1° lon ≈ 111 320 · cos(lat).
    private func horizontalDispersion(fixes: [GeoFix], median: GeoFix) -> Double? {
        guard fixes.count >= 2 else { return nil }
        let cosLat = cos(median.latitude * .pi / 180.0)
        let mPerDegLat = 111_320.0
        let mPerDegLon = mPerDegLat * cosLat

        let sumSq = fixes.reduce(0.0) { acc, f in
            let dlat = (f.latitude - median.latitude) * mPerDegLat
            let dlon = (f.longitude - median.longitude) * mPerDegLon
            return acc + dlat * dlat + dlon * dlon
        }
        return sqrt(sumSq / Double(fixes.count))
    }
}