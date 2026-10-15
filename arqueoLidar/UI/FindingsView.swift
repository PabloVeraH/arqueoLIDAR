import SwiftUI
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Expedientes guardados: lista, verificación de custodia y compartir archivos.
// ═══════════════════════════════════════════════════════════════════════════════

struct FindingsView: View {
    @State private var items: [FindingItem] = []
    @State private var loaded = false
    @State private var errorText: String?
    @State private var pendingDelete: FindingItem?

    var body: some View {
        List {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
            ForEach(items) { item in
                NavigationLink {
                    FindingDetailView(item: item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.summary.title)
                        Text("\(item.summary.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(item.summary.scanCount) escaneo(s) · \(item.folder.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDelete = item
                    } label: {
                        Label("Eliminar", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "¿Eliminar el expediente \(pendingDelete?.folder.lastPathComponent ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Eliminar expediente", role: .destructive) {
                if let item = pendingDelete {
                    Task {
                        do {
                            try await FindingService.shared.delete(findingID: item.summary.findingID)
                        } catch {
                            errorText = "No se pudo eliminar: \(error.localizedDescription)"
                        }
                        await load()
                    }
                }
                pendingDelete = nil
            }
        } message: {
            Text("Se borran la malla, los sellos y todos sus archivos del iPhone. No se puede deshacer.")
        }
        .overlay {
            if loaded && items.isEmpty && errorText == nil {
                ContentUnavailableView("Sin expedientes", systemImage: "tray",
                                       description: Text("Los escaneos que guardes aparecerán aquí."))
            }
        }
        .navigationTitle("Expedientes")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            items = try await FindingService.shared.list()
            errorText = nil
        } catch {
            errorText = "No se pudieron leer los expedientes: \(error)"
        }
        loaded = true
    }
}

struct FindingDetailView: View {
    let item: FindingItem
    @State private var verifying = false
    @State private var verdict: (ok: Bool, detail: String)?

    var body: some View {
        List {
            Section {
                LabeledContent("Código", value: item.summary.expeditionCode)
                LabeledContent("Creado", value: item.summary.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Escaneos", value: "\(item.summary.scanCount) (\(item.summary.sealedCount) sellados)")
                LabeledContent("Carpeta", value: item.folder.lastPathComponent)
            }
            Section("Cadena de custodia") {
                Button {
                    Task {
                        verifying = true
                        let result = await FindingService.shared.verify(findingID: item.summary.findingID)
                        verdict = (result.ok, result.detail)
                        verifying = false
                    }
                } label: {
                    HStack {
                        Label("Verificar integridad", systemImage: "checkmark.shield")
                        if verifying { Spacer(); ProgressView() }
                    }
                }
                .disabled(verifying)
                if let verdict {
                    Label(verdict.detail, systemImage: verdict.ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(verdict.ok ? Color.green : Color.red)
                        .font(.footnote)
                }
            }
            Section {
                ForEach(item.meshFiles, id: \.self) { url in
                    ShareLink(item: url) {
                        Label("Compartir \(url.deletingLastPathComponent().lastPathComponent.prefix(8))…/mesh.ply", systemImage: "cube")
                    }
                }
                ShareLink(item: item.folder) {
                    Label("Compartir expediente completo", systemImage: "folder")
                }
            } header: {
                Text("Archivos")
            } footer: {
                Text("Para verificarlo en la Mac sin la app: python3 tools/verify_chain.py <carpeta \(item.folder.lastPathComponent)>")
            }
        }
        .navigationTitle(item.summary.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
