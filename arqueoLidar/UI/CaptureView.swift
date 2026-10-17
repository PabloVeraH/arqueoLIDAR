import SwiftUI
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Pantalla de captura LiDAR: cámara + wireframe en vivo + HUD de diagnóstico,
// registro GPS, prueba de ruido sobre una superficie y guardado sellado del
// escaneo dentro del expediente del hallazgo.
// ═══════════════════════════════════════════════════════════════════════════════

struct CaptureView: View {
    let finding: Finding
    /// Escaneo sellado que este reemplaza (no se borra: el nuevo lo declara).
    var replacing: ScanEntry? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var controller = ScanController()
    @State private var location = LocationRecorder()
    @State private var purpose: ScanPurpose = .baseline

    @State private var showSaveForm = false
    @State private var isSaving = false
    @State private var saved: SavedScan?
    @State private var errorText: String?
    @State private var reason = ""
    @State private var controlTarget: IdentifiedPoint?

    var body: some View {
        ZStack {
            if controller.isSupported {
                ARViewContainer(view: controller.sceneView)
                    .ignoresSafeArea()
                crosshair
                VStack(spacing: 12) {
                    hud
                    Spacer()
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let noise = controller.noiseResult {
                        Text(noise)
                            .font(.footnote.monospacedDigit())
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    controls
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "Este dispositivo no tiene LiDAR",
                    systemImage: "sensor.tag.radiowaves.forward",
                    description: Text("La captura 3D necesita un iPhone Pro (12 Pro o posterior) o un iPad Pro con sensor LiDAR."))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
            }
            .padding()
            .accessibilityLabel("Cerrar")
        }
        .onAppear {
            if let replacing { purpose = replacing.scan.purpose }
        }
        .task {
            controller.start()
            location.start()
            while !Task.isCancelled {
                controller.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear {
            controller.pause()
            location.stop()
        }
        .sheet(isPresented: $showSaveForm) { saveForm }
        .sheet(item: $controlTarget) { target in
            ControlPointForm(number: controller.controlPoints.count + 1) { label, fix in
                controller.addControlPoint(label: label, at: target.position, fix: fix)
            }
        }
        .sheet(item: $saved) { scan in SavedScanView(scan: scan) { saved = nil; dismiss() } }
        .alert("No se pudo guardar", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - Piezas

    private var crosshair: some View {
        Image(systemName: "plus")
            .font(.system(size: 28, weight: .light))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .allowsHitTesting(false)
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.trackingIsNormal ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text("Seguimiento: \(controller.trackingText)")
            }
            Text("Anclas: \(controller.anchorCount) · Vértices: \(controller.vertexCount.formatted())")
            Text("Reconstrucción: \(controller.reconstructionText)")
            Text("Temperatura: \(controller.thermalText) · Disco libre: \(controller.freeDiskText)")
            Text(location.statusText)
            Text(markText)
            if !controller.controlPoints.isEmpty {
                Text("Puntos de control: \(controller.controlPoints.map(\.label).joined(separator: ", "))")
            }
            Text("Tiempo: \(Int(Date().timeIntervalSince(controller.sessionStart) / 60)) min · Recorrido: \(Int(controller.pathLength)) m")
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.trailing, 44)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                controller.restart()
            } label: {
                Label("Reiniciar", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            Menu {
                Menu("Marcar objeto bajo la mira") {
                    ForEach([0.25, 0.5, 1, 2] as [Float], id: \.self) { r in
                        Button("Radio \(radiusText(r))") { controller.markObject(radius: r) }
                    }
                }
                Button("Punto de control (topógrafo)…") {
                    if let target = controller.pointUnderCrosshair() { controlTarget = IdentifiedPoint(position: target) }
                }
                Button("Medir ruido del sensor") { controller.measureSurfaceNoise() }
            } label: {
                Label("Herramientas", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            Button {
                showSaveForm = true
            } label: {
                Label("Guardar", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.vertexCount == 0 || isSaving || controller.lowDisk)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .font(.footnote.weight(.semibold))
    }

    private var saveForm: some View {
        NavigationStack {
            Form {
                if let replacing {
                    Section {
                        LabeledContent("Reemplaza a", value: "\(replacing.scan.purpose.label), \(replacing.scan.capturedAt.formatted(date: .abbreviated, time: .shortened))")
                        TextField("Motivo (ej. el primero quedó incompleto)", text: $reason, axis: .vertical)
                    } footer: {
                        Text("El escaneo anterior no se borra: sigue sellado y queda marcado como reemplazado por este.")
                    }
                }
                Section {
                    LabeledContent("Hallazgo", value: finding.title)
                    Picker("Propósito", selection: $purpose) {
                        ForEach(ScanPurpose.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Se firma a nombre de \(finding.author.name). El propósito define cómo se medirá después (volumen, daño, monitoreo…).")
                }
                Section {
                    Text(location.statusText)
                } footer: {
                    Text("Se guarda la serie completa de lecturas GPS. Si la mejor precisión supera ±10 m, el escaneo queda marcado como «GPS degradado».")
                }
                Section {
                    Text(markText)
                } footer: {
                    Text("Para medir el volumen después, apunta la mira al objeto y toca «Marcar». Escanea solo el objeto y una franja de suelo alrededor: todo lo que la cámara vea entra en la malla.")
                }
                Section {
                    Text("Se guardarán \(controller.vertexCount.formatted()) vértices de \(controller.anchorCount) anclas, fusionados en una sola malla.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Guardar escaneo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { showSaveForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Guardar y sellar") { save() }
                            .disabled(replacing != nil && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    /// Avisos que no deben pasar inadvertidos durante la captura.
    private var warnings: [String] {
        var out: [String] = []
        if controller.isInterrupted {
            out.append("Captura interrumpida (llamada o bloqueo). Al volver, apunta a una zona ya escaneada para que la app se reubique.")
        } else if controller.interruptions > 0 {
            out.append("Hubo \(controller.interruptions) interrupción(es): revisa en el visor que el modelo no quedó corrido.")
        }
        if controller.sunWarning {
            out.append("Mucha luz: el LiDAR está perdiendo puntos. Haz sombra con el cuerpo o un paraguas, o escanea más cerca.")
        }
        if controller.lowDisk {
            out.append("Queda poco espacio (\(controller.freeDiskText)). Libera espacio en el iPhone antes de guardar.")
        }
        out += controller.qualityReport().flags.filter { $0.hasPrefix("Escaneo largo") || $0.hasPrefix("Recorrido largo") }
        return out
    }

    private var markText: String {
        controller.objectMark.map { "Objeto marcado · radio \(radiusText($0.radius))" }
            ?? "Objeto sin marcar (apunta la mira y toca «Marcar»)"
    }

    private func radiusText(_ r: Float) -> String {
        r < 1 ? "\(Int((r * 100).rounded())) cm" : "\(Int(r)) m"
    }

    private func save() {
        let capture = CaptureRecord(parts: controller.collectParts(), fixes: location.fixes, purpose: purpose,
                                    mark: controller.objectMark, trajectory: controller.trajectory,
                                    controlPoints: controller.controlPoints,
                                    quality: controller.qualityReport())
        isSaving = true
        controller.pause()
        Task {
            do {
                let result = try await FieldStore.saveScan(capture, finding: finding, replacing: replacing,
                                                         reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
                location.stop()
                showSaveForm = false
                try? await Task.sleep(for: .milliseconds(400))
                saved = result
            } catch {
                // Nada quedó escrito si falló la autenticación (se pide antes de
                // guardar): se reanuda sin borrar la malla para reintentar.
                showSaveForm = false
                errorText = error.localizedDescription
                controller.resume()
            }
            isSaving = false
        }
    }
}

/// Resumen tras guardar: tamaño de la malla, hash sellado y opciones para compartir.
struct SavedScanView: View {
    let scan: SavedScan
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Escaneo guardado y sellado", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    LabeledContent("Vértices", value: scan.vertexCount.formatted())
                    LabeledContent("Triángulos", value: scan.triangleCount.formatted())
                    LabeledContent("Expediente", value: scan.folder.lastPathComponent)
                    LabeledContent("Firma", value: scan.keyProtection == .secureEnclave
                                   ? "Chip seguro del iPhone" : "Clave de software (sin chip seguro)")
                }
                Section {
                    Text(scan.rootHash)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Root hash del sello")
                }
                Section {
                    ShareLink(item: scan.meshURL) {
                        Label("Compartir malla (mesh.ply)", systemImage: "cube")
                    }
                    ShareLink(item: scan.folder) {
                        Label("Compartir expediente completo", systemImage: "folder")
                    }
                } footer: {
                    Text("El PLY se abre en MeshLab, Blender o Vista Previa. El expediente completo también aparece en la app Archivos, en «En mi iPhone › arqueoLidar › Findings».")
                }
            }
            .navigationTitle(scan.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo", action: onDone)
                }
            }
        }
    }
}
