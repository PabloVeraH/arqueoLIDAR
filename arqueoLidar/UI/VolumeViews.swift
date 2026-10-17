import SwiftUI
import Domain
import Volume

// ═══════════════════════════════════════════════════════════════════════════════
// Volumen en la ficha del escaneo: caja ajustable sobre el visor 3D, cálculo
// (VolumeMeasurer) y guardado sellado. Lo medido y lo inferido se distinguen con
// palabra, ícono y color, nunca solo con color (plan, Fase 14 punto 5).
// ═══════════════════════════════════════════════════════════════════════════════

/// Etiqueta de procedencia de un número.
struct ProvenanceBadge: View {
    let isInferred: Bool

    var body: some View {
        let color: Color = isInferred ? .orange : .green
        Label(isInferred ? "INFERIDO · estimación" : "MEDIDO",
              systemImage: isInferred ? "exclamationmark.triangle.fill" : "ruler.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Un volumen con su etiqueta, supuestos y la advertencia de precisión.
struct VolumeMeasurementRow: View {
    let measurement: Measurement

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(measurement.label ?? "Volumen")
                Spacer()
                ProvenanceBadge(isInferred: measurement.isInferred)
            }
            Text(Self.volumeText(measurement.value))
                .font(.title3.monospacedDigit().weight(.semibold))
            ForEach(measurement.assumptions ?? [], id: \.self) {
                Text($0).font(.caption).foregroundStyle(.secondary)
            }
            // Regla del plan (Fase 16): ninguna cifra de precisión hasta medirla en terreno.
            Text("Precisión en terreno: no validada todavía.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static func volumeText(_ m3: Double) -> String {
        let liters = (m3 * 1000).formatted(.number.precision(.fractionLength(1)))
        let cubic = m3.formatted(.number.precision(.fractionLength(m3 < 1 ? 4 : 2)))
        return m3 < 1 ? "\(liters) L (\(cubic) m³)" : "\(cubic) m³"
    }
}

/// Caja sobre el visor + deslizadores, calcular y guardar.
struct VolumeMeasureView: View {
    let entry: ScanEntry
    let finding: Finding
    let mesh: Mesh
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var center: SIMD3<Float>
    @State private var size: SIMD3<Float>
    @State private var result: VolumeMeasurement?
    @State private var errorText: String?
    @State private var working = false
    private let bounds: (min: SIMD3<Float>, max: SIMD3<Float>)

    init(entry: ScanEntry, finding: Finding, mesh: Mesh, onSaved: @escaping () -> Void) {
        self.entry = entry
        self.finding = finding
        self.mesh = mesh
        self.onSaved = onSaved
        let lo = mesh.vertices.reduce(SIMD3<Float>(repeating: .infinity)) { pointwiseMin($0, $1) }
        let hi = mesh.vertices.reduce(SIMD3<Float>(repeating: -.infinity)) { pointwiseMax($0, $1) }
        bounds = (lo, hi)
        // Caja inicial: la marca de la captura; sin marca, todo el escaneo.
        if let mark = entry.scan.objectMark {
            _center = State(initialValue: mark.center)
            _size = State(initialValue: SIMD3(repeating: 2 * mark.radius))
        } else {
            _center = State(initialValue: (lo + hi) / 2)
            _size = State(initialValue: pointwiseMax(hi - lo, SIMD3(repeating: 0.1)))
        }
    }

    private var region: OrientedBox? {
        try? OrientedBox(center: center, axes: .identity, halfExtents: size / 2)
    }

    var body: some View {
        List {
            Section {
                MeshViewer(mesh: mesh, region: region)
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text(entry.scan.objectMark == nil
                     ? "Este escaneo no tiene objeto marcado: la caja parte cubriendo todo. Achícala hasta el objeto, con una franja de suelo (o de superficie sana) alrededor."
                     : "La caja parte en el objeto marcado al capturar. Debe incluir una franja de suelo (o de superficie sana) alrededor: ahí se ajusta la referencia.")
            }

            Section("Posición") {
                slider("Lado (X)", \.x, of: $center, in: bounds.min.x...bounds.max.x)
                slider("Altura (Y)", \.y, of: $center, in: bounds.min.y...bounds.max.y)
                slider("Fondo (Z)", \.z, of: $center, in: bounds.min.z...bounds.max.z)
            }
            Section("Tamaño") {
                slider("Largo", \.x, of: $size, in: 0.05...maxSize(\.x))
                slider("Alto", \.y, of: $size, in: 0.05...maxSize(\.y))
                slider("Ancho", \.z, of: $size, in: 0.05...maxSize(\.z))
            }

            Section {
                Button {
                    calculate()
                } label: {
                    Label(working ? "Calculando…" : "Calcular volumen", systemImage: "cube.transparent")
                }
                .disabled(working || region == nil)
                if let errorText { Text(errorText).foregroundStyle(.red) }
            } footer: {
                Text("Método según el propósito del escaneo (\(entry.scan.purpose.label)).")
            }

            if let result {
                Section {
                    ForEach(result.measurements, id: \.measurementID) { VolumeMeasurementRow(measurement: $0) }
                    Button {
                        save(result)
                    } label: {
                        Label("Guardar y sellar medición", systemImage: "checkmark.seal")
                    }
                    .disabled(working)
                } header: {
                    Text("Resultado")
                } footer: {
                    Text("Al guardar se pide Face ID o el código, y la medición queda sellada en el expediente.")
                }
            }
        }
        .navigationTitle("Medir volumen")
        .navigationBarTitleDisplayMode(.inline)
        // Mover la caja invalida el resultado anterior.
        .onChange(of: region) { result = nil }
    }

    private func maxSize(_ axis: WritableKeyPath<SIMD3<Float>, Float>) -> Float {
        max((bounds.max - bounds.min)[keyPath: axis] * 1.2, 0.2)
    }

    private func slider(_ title: String, _ axis: WritableKeyPath<SIMD3<Float>, Float>,
                        of value: Binding<SIMD3<Float>>, in range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue[keyPath: axis] * 100).rounded())) cm")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value.wrappedValue[keyPath: axis] },
                                  set: { value.wrappedValue[keyPath: axis] = $0 }),
                   in: range)
        }
    }

    private func calculate() {
        guard let region else { return }
        working = true
        errorText = nil
        let mesh = mesh, purpose = entry.scan.purpose, scanID = entry.scan.scanID
        Task {
            do {
                result = try await Task.detached {
                    try VolumeMeasurer.measure(mesh: mesh, region: region, purpose: purpose, scanID: scanID)
                }.value
            } catch {
                errorText = Self.message(error)
            }
            working = false
        }
    }

    private func save(_ measurement: VolumeMeasurement) {
        working = true
        Task {
            do {
                try await FieldStore.saveMeasurement(measurement, finding: finding)
                onSaved()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }

    private static func message(_ error: Error) -> String {
        switch error as? VolumeError {
        case .notEnoughData(let why): why
        case .meshNotClosed: "No se pudo cerrar la malla para medirla como sólido. Revisa que la caja rodee el objeto completo."
        default: "No se pudo calcular el volumen: \(error)"
        }
    }
}
