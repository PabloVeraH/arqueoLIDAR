import SwiftUI
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Pantalla de captura LiDAR: cámara + wireframe en vivo + HUD de diagnóstico,
// registro GPS, prueba de ruido sobre una superficie y guardado sellado del
// escaneo dentro del expediente del hallazgo.
// ═══════════════════════════════════════════════════════════════════════════════

struct CaptureView: View {
    let finding: Finding
    @Environment(\.dismiss) private var dismiss
    @State private var controller = ScanController()
    @State private var location = LocationRecorder()
    @State private var purpose: ScanPurpose = .baseline

    @State private var showSaveForm = false
    @State private var isSaving = false
    @State private var saved: SavedScan?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            if controller.isSupported {
                ARViewContainer(view: controller.sceneView)
                    .ignoresSafeArea()
                crosshair
                VStack(spacing: 12) {
                    hud
                    Spacer()
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
            Button {
                controller.measureSurfaceNoise()
            } label: {
                Label("Medir ruido", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            Button {
                showSaveForm = true
            } label: {
                Label("Guardar", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.vertexCount == 0 || isSaving)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .font(.footnote.weight(.semibold))
    }

    private var saveForm: some View {
        NavigationStack {
            Form {
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
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        let parts = controller.collectParts()
        let fixes = location.fixes
        isSaving = true
        controller.pause()
        Task {
            do {
                let result = try await FieldStore.saveScan(parts: parts, fixes: fixes, purpose: purpose, finding: finding)
                location.stop()
                showSaveForm = false
                try? await Task.sleep(for: .milliseconds(400))
                saved = result
            } catch {
                showSaveForm = false
                errorText = error.localizedDescription
                controller.start()
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
