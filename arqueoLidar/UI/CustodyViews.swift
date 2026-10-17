import SwiftUI
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Sello a propósito (plan §2.C.6: "se sella antes de intervenir y después"):
// deja constancia del expediente tal como está, con una nota y el GPS del momento.
// ═══════════════════════════════════════════════════════════════════════════════

struct CustodySealView: View {
    let finding: Finding
    let onSealed: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: CustodyNoteKind = .beforeIntervention
    @State private var text = ""
    @State private var gps = LocationRecorder()
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Momento", selection: $kind) {
                        ForEach(CustodyNoteKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    TextField("Qué se va a hacer o qué se hizo (ej. extracción del cráneo con yeso)",
                              text: $text, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("Se sella el expediente completo tal como está ahora, con esta nota. Sirve para probar el estado antes y después de una intervención.")
                }
                Section {
                    Text(gps.statusText).font(.caption)
                } header: {
                    Text("Ubicación")
                } footer: {
                    Text("Si hay señal, el sello lleva la ubicación y la hora del GPS. Sin GPS igual se puede sellar.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Sellar estado actual")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Sellar", action: seal)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(working)
            .onAppear { gps.start() }
            .onDisappear { gps.stop() }
        }
    }

    private func seal() {
        working = true
        error = nil
        let note = CustodyNote(kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        let geo = FieldStore.representativeFix(gps.fixes)
        Task {
            do {
                try await FieldStore.sealNote(note, geo: geo, finding: finding)
                onSealed()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
