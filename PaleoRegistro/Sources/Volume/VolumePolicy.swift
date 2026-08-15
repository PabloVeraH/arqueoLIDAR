import Foundation
import Domain
import Mesh

// ═══════════════════════════════════════════════════════════════════════════════
// F5 — VolumePolicy: enrutador que elige integrador según `ScanPurpose` y
// geometría. Decisión documentada: si la malla tiene voladizos (no es un campo de
// alturas 2.5D), el height field yerra sistemáticamente → se enruta a
// `ClosedMeshIntegrator`. `damageAssessment` se enruta a `CavityIntegrator` con la
// referencia que el llamador provea.
// ═══════════════════════════════════════════════════════════════════════════════

public enum VolumePolicy {

    /// Integrador adecuado para un propósito y una geometría.
    public enum Route {
        case heightField
        case closedMesh
        case cavity
    }

    /// Heurística de voladizo: la malla proyectada sobre el plano de apoyo no puede
    /// describirse como un único campo de alturas si hay celdas de la proyección con
    /// más de una "columna" de superficie claramente separada. Aproximación práctica:
    /// si la nube es lo bastante densa y vertical, asumimos campo de alturas; la
    /// decisión dura la toma el test (hongo/alero) que verifica el fallo del height
    /// field y el acierto del closed mesh.
    public static func route(for purpose: ScanPurpose) -> Route {
        switch purpose {
        case .baseline, .postIntervention, .monitoring:
            return .heightField
        case .damageAssessment:
            return .cavity
        case .rescueDocumentation, .specimenInventory, .stratigraphicProfile:
            return .closedMesh
        }
    }

    /// Integrador concreto instanciado para un propósito.
    public static func integrator(for purpose: ScanPurpose) -> any VolumeIntegrating {
        switch route(for: purpose) {
        case .heightField:
            return SignedHeightFieldIntegrator()
        case .closedMesh:
            return ClosedMeshIntegrator()
        case .cavity:
            return CavityIntegrator()
        }
    }
}