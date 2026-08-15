import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F7 — SpatialRelationBuilder. Relaciones entre especímenes: distancia
// centro-centro, azimut, contacto/solapamiento entre cajas, diferencia de cota.
// ═══════════════════════════════════════════════════════════════════════════════

public struct SpatialRelationBuilder: Sendable {

    public init() {}

    /// Calcula todas las relaciones entre pares de especímenes.
    /// - Parameters:
    ///   - specimens: especímenes con su `OrientedBox` en marco de sitio.
    ///   - contactThreshold: distancia mínima entre cajas (m) bajo la cual se marca contacto.
    public func buildRelations(
        specimens: [(id: UUID, box: OrientedBox)],
        contactThreshold: Float = 0.01
    ) -> [SpecimenRelation] {

        var relations: [SpecimenRelation] = []

        for i in 0..<specimens.count {
            for j in (i+1)..<specimens.count {
                let a = specimens[i]
                let b = specimens[j]

                // Distancia centro-centro
                let centerDist = vecLength(b.box.center - a.box.center)
                relations.append(SpecimenRelation(
                    fromID: a.id, toID: b.id,
                    kind: .distance, value: Double(centerDist), unit: "m"
                ))

                // Azimut (en plano horizontal EN)
                let dx = b.box.center.x - a.box.center.x
                let dz = -(b.box.center.z - a.box.center.z) // -Z es Norte
                let azimuth: Float
                if abs(dx) < 1e-6 && abs(dz) < 1e-6 {
                    azimuth = 0
                } else {
                    let raw = atan2(dx, dz) * 180 / .pi
                    azimuth = raw < 0 ? raw + 360 : raw
                }
                relations.append(SpecimenRelation(
                    fromID: a.id, toID: b.id,
                    kind: .azimuth, value: Double(azimuth), unit: "deg"
                ))

                // Diferencia de cota (altura de centro)
                let dzCota = b.box.center.y - a.box.center.y
                relations.append(SpecimenRelation(
                    fromID: a.id, toID: b.id,
                    kind: .heightDelta, value: Double(dzCota), unit: "m"
                ))

                // Contacto: distancia mínima entre cajas < umbral
                let minDist = minimumDistanceBetweenBoxes(a.box, b.box)
                if minDist < contactThreshold {
                    relations.append(SpecimenRelation(
                        fromID: a.id, toID: b.id,
                        kind: .contact, value: Double(minDist), unit: "m"
                    ))
                }
            }
        }

        return relations
    }

    /// Distancia mínima entre dos cajas orientadas.
    /// Aproximación por muestreo: distancia entre los 8 vértices de cada una.
    private func minimumDistanceBetweenBoxes(_ a: OrientedBox, _ b: OrientedBox) -> Float {
        var minDist: Float = .greatestFiniteMagnitude
        let cornersA = a.corners
        let cornersB = b.corners

        for ca in cornersA {
            for cb in cornersB {
                let d = vecLength(ca - cb)
                if d < minDist { minDist = d }
            }
        }

        return minDist
    }
}