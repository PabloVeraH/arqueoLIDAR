import SwiftUI
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Punto de control del topógrafo (plan §2.C.5): durante la captura se apunta la
// mira a la marca física y se ingresa su coordenada UTM (GNSS diferencial). Con
// dos o más, el escaneo queda con norte verdadero y ubicación de ±2 cm.
// ═══════════════════════════════════════════════════════════════════════════════

/// Punto bajo la mira, para abrir el formulario con `.sheet(item:)`.
struct IdentifiedPoint: Identifiable {
    let id = UUID()
    let position: SIMD3<Float>
}

struct ControlPointForm: View {
    let number: Int
    let onAdd: (String, GeoFix) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var easting = ""
    @State private var northing = ""
    @State private var height = ""
    @State private var zone = 19
    @State private var accuracyCm = "2"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre (ej. PC-\(number))", text: $label)
                } footer: {
                    Text("Quedó registrado el punto que estaba bajo la mira. Ingresa la coordenada que entregó el topógrafo para esa marca.")
                }
                Section("Coordenada UTM (WGS84)") {
                    TextField("Este (m), ej. 345678.123", text: $easting).keyboardType(.decimalPad)
                    TextField("Norte (m), ej. 7467123.456", text: $northing).keyboardType(.decimalPad)
                    TextField("Altura elipsoidal (m)", text: $height).keyboardType(.decimalPad)
                    Picker("Huso", selection: $zone) {
                        Text("19 S (Chile central y norte)").tag(19)
                        Text("18 S (sur y costa oeste)").tag(18)
                        Text("12 S (Isla de Pascua)").tag(12)
                    }
                    TextField("Precisión (cm)", text: $accuracyCm).keyboardType(.decimalPad)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Punto de control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Agregar", action: add) }
            }
        }
    }

    private func add() {
        // Acepta coma o punto decimal, como se escriba en terreno.
        func parse(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: ".")) }
        guard let e = parse(easting), let n = parse(northing), let h = parse(height),
              let cm = parse(accuracyCm), cm > 0 else {
            error = "Completa Este, Norte, altura y precisión con números."
            return
        }
        do {
            let fix = try FieldStore.controlPointFix(easting: e, northing: n, height: h, zone: zone, accuracy: cm / 100)
            let name = label.trimmingCharacters(in: .whitespaces)
            onAdd(name.isEmpty ? "PC-\(number)" : name, fix)
            dismiss()
        } catch {
            self.error = "La coordenada no es válida para el huso \(zone) S: revisa Este y Norte."
        }
    }
}
