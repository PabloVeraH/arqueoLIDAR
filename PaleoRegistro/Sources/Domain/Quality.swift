import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// F15 — Calidad de la sesión de captura. Se guarda como quality.json dentro del
// escaneo (sellado) y marca lo que pudo degradar el modelo: duración y recorrido
// largos (deriva de ARKit), interrupciones, seguimiento limitado, sol directo,
// temperatura. Los límites son provisorios hasta medirlos en terreno (Fase 16).
// ═══════════════════════════════════════════════════════════════════════════════

/// Posición de la cámara en un instante (marco de mundo de la captura, +Y arriba).
/// La serie se guarda en trajectory.json; sirve para el norte verdadero.
public struct CameraSample: Sendable, Codable, Equatable {
    public var time: Date
    public var position: SIMD3<Float>

    public init(time: Date, position: SIMD3<Float>) {
        self.time = time
        self.position = position
    }
}

public struct QualityLimits: Sendable, Codable, Equatable {
    public var maxDuration: TimeInterval
    public var maxPathLength: Float
    public var maxLimitedTrackingFraction: Double
    public var maxSunSaturation: TimeInterval
    /// false mientras los límites no salgan de mediciones de terreno (Fase 16).
    public var validated: Bool

    public init(maxDuration: TimeInterval, maxPathLength: Float, maxLimitedTrackingFraction: Double,
                maxSunSaturation: TimeInterval, validated: Bool) {
        self.maxDuration = maxDuration
        self.maxPathLength = maxPathLength
        self.maxLimitedTrackingFraction = maxLimitedTrackingFraction
        self.maxSunSaturation = maxSunSaturation
        self.validated = validated
    }

    // ponytail: valores de partida sin medir. Ajustar con la deriva y la
    // saturación medidas en M14 (docs/VALIDATION.md) y marcar validated = true.
    public static let provisional = QualityLimits(
        maxDuration: 10 * 60, maxPathLength: 60, maxLimitedTrackingFraction: 0.2,
        maxSunSaturation: 10, validated: false)
}

public enum ThermalLevel: Int, Sendable, Codable, Comparable {
    case nominal, fair, serious, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct QualityReport: Sendable, Codable, Equatable {
    public var duration: TimeInterval
    public var pathLength: Float
    public var interruptions: Int
    public var limitedTrackingSeconds: TimeInterval
    public var sunSaturationSeconds: TimeInterval
    public var maxThermal: ThermalLevel
    public var limits: QualityLimits
    /// Advertencias en palabras de terreno; vacío si la sesión no superó nada.
    public var flags: [String]

    public init(duration: TimeInterval, pathLength: Float, interruptions: Int,
                limitedTrackingSeconds: TimeInterval, sunSaturationSeconds: TimeInterval,
                maxThermal: ThermalLevel, limits: QualityLimits = .provisional) {
        self.duration = duration
        self.pathLength = pathLength
        self.interruptions = interruptions
        self.limitedTrackingSeconds = limitedTrackingSeconds
        self.sunSaturationSeconds = sunSaturationSeconds
        self.maxThermal = maxThermal
        self.limits = limits
        self.flags = []
        self.flags = evaluate()
    }

    func evaluate() -> [String] {
        var out: [String] = []
        let minutes = { (s: TimeInterval) in Int((s / 60).rounded()) }
        if duration > limits.maxDuration {
            out.append("Escaneo largo (\(minutes(duration)) min, límite \(minutes(limits.maxDuration)) min): la deriva del seguimiento puede deformar el modelo.")
        }
        if pathLength > limits.maxPathLength {
            out.append("Recorrido largo (\(Int(pathLength)) m, límite \(Int(limits.maxPathLength)) m): la deriva puede deformar el modelo; conviene escanear por partes.")
        }
        if interruptions > 0 {
            out.append("Hubo \(interruptions) interrupción(es) (llamada, bloqueo, app en segundo plano): revisa en el visor que no haya partes corridas o duplicadas.")
        }
        if duration > 0, limitedTrackingSeconds / duration > limits.maxLimitedTrackingFraction {
            out.append("Seguimiento limitado el \(Int((limitedTrackingSeconds / duration * 100).rounded())) % del tiempo (movimiento brusco, poca textura o poca luz).")
        }
        if sunSaturationSeconds > limits.maxSunSaturation {
            out.append("Sol directo saturó el sensor durante \(Int(sunSaturationSeconds)) s: puede haber huecos o superficies ruidosas.")
        }
        if maxThermal >= .serious {
            out.append("El teléfono se calentó (temperatura \(maxThermal == .critical ? "crítica" : "alta")): la captura pudo degradarse.")
        }
        if !out.isEmpty, !limits.validated {
            out.append("Límites provisorios: todavía no se midieron en terreno.")
        }
        return out
    }
}
