import SwiftUI
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Flujo de terreno: lista de hallazgos → ficha del hallazgo → escanear
// (CaptureView: LiDAR + GPS, se sella al guardar) → ver en 3D → exportar.
// ═══════════════════════════════════════════════════════════════════════════════

struct FindingsListView: View {
    @State private var findings: [Finding] = []
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List(findings, id: \.findingID) { finding in
                NavigationLink {
                    FindingDetailView(finding: finding)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title)
                        Text("\(finding.expeditionCode) · \(finding.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if findings.isEmpty {
                    ContentUnavailableView("Sin hallazgos", systemImage: "fossil.shell",
                                           description: Text("Toca + para crear el expediente de un hallazgo."))
                }
            }
            .navigationTitle("Hallazgos")
            .toolbar {
                Button { showNew = true } label: { Label("Nuevo hallazgo", systemImage: "plus") }
            }
            .sheet(isPresented: $showNew, onDismiss: reload) { NewFindingView() }
            .refreshable { reload() }
            .onAppear(perform: reload)
        }
    }

    private func reload() { findings = FieldStore.findings() }
}

struct NewFindingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var expeditionCode = ""
    @State private var permit = ""
    @State private var error: String?
    // El autor se recuerda entre hallazgos: suele ser la misma persona.
    @AppStorage("authorName") private var name = ""
    @AppStorage("authorRole") private var role = "Arqueólogo/a"
    @AppStorage("authorInstitution") private var institution = ""

    private var isValid: Bool {
        ![title, expeditionCode, name, role, institution].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Hallazgo") {
                    TextField("Nombre (ej. Fémur en zanja norte)", text: $title)
                    TextField("Código de expedición", text: $expeditionCode)
                }
                Section("Responsable") {
                    TextField("Nombre", text: $name)
                    TextField("Rol (ej. Paleontólogo)", text: $role)
                    TextField("Institución", text: $institution)
                    TextField("N° de permiso CMN (opcional)", text: $permit)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Nuevo hallazgo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Crear", action: create).disabled(!isValid) }
            }
        }
    }

    private func create() {
        let permitNumber = permit.trimmingCharacters(in: .whitespaces)
        let author = AuthorIdentity(name: name, role: role, institution: institution,
                                    cmnPermitNumber: permitNumber.isEmpty ? nil : permitNumber)
        let finding = Finding(siteID: UUID(), title: title, expeditionCode: expeditionCode, author: author,
                              permit: permitNumber.isEmpty ? nil : CMNPermit(number: permitNumber, institution: institution))
        do {
            try FieldStore.createFinding(finding)
            dismiss()
        } catch {
            self.error = "No se pudo crear el expediente: \(error)"
        }
    }
}

struct FindingDetailView: View {
    let finding: Finding
    @State private var scans: [ScanEntry] = []
    @State private var showCapture = false
    @State private var verdict: CustodyVerdict?
    @State private var verifying = false

    var body: some View {
        List {
            Section("Expediente") {
                LabeledContent("Código", value: finding.expeditionCode)
                LabeledContent("Responsable", value: "\(finding.author.name) (\(finding.author.role))")
                LabeledContent("Institución", value: finding.author.institution)
                LabeledContent("Carpeta", value: FieldStore.findingDir(finding).lastPathComponent)
            }

            Section {
                ForEach(scans) { entry in
                    NavigationLink {
                        ScanDetailView(entry: entry, finding: finding)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.scan.purpose.label)
                            Text("\(entry.scan.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.scan.georeferenceQuality.label)\(entry.isSealed ? " · sellado" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    showCapture = true
                } label: {
                    Label("Nuevo escaneo LiDAR", systemImage: "camera.metering.matrix")
                }
            } header: {
                Text("Escaneos")
            } footer: {
                Text("Cada escaneo se sella al guardarlo: queda en la cadena de custodia y no se puede modificar.")
            }

            Section {
                Button {
                    Task {
                        verifying = true
                        verdict = await FieldStore.verify(finding)
                        verifying = false
                    }
                } label: {
                    Label(verifying ? "Verificando…" : "Verificar expediente", systemImage: "checkmark.shield")
                }
                .disabled(verifying || scans.isEmpty)
                ShareLink(item: FieldStore.findingDir(finding)) {
                    Label("Compartir expediente completo", systemImage: "folder")
                }
                if let verdict {
                    switch verdict {
                    case .valid:
                        Label("Íntegro: ningún archivo fue alterado desde el último sello.", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case .invalid(let errors):
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Problemas encontrados", systemImage: "xmark.seal.fill").foregroundStyle(.red)
                            ForEach(Array(errors.enumerated()), id: \.offset) { Text("• " + String(describing: $0.element)).font(.caption) }
                        }
                    }
                }
            } header: {
                Text("Cadena de custodia")
            } footer: {
                Text("Para verificarlo en una Mac sin la app: python3 tools/verify_chain.py <carpeta \(FieldStore.findingDir(finding).lastPathComponent)>")
            }
        }
        .navigationTitle(finding.title)
        .fullScreenCover(isPresented: $showCapture, onDismiss: reload) {
            CaptureView(finding: finding)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        scans = FieldStore.scans(of: finding)
        verdict = nil
    }
}

struct ScanDetailView: View {
    let entry: ScanEntry
    let finding: Finding
    @State private var mesh: Mesh?
    @State private var stats = ""
    @State private var loadError: String?
    @State private var exported: [URL] = []
    @State private var problems: [String] = []
    @State private var exporting = false

    var body: some View {
        List {
            Section {
                ZStack {
                    if let mesh {
                        MeshViewer(mesh: mesh)
                    } else if let loadError {
                        Text(loadError).foregroundStyle(.red)
                    } else {
                        ProgressView("Cargando malla…")
                    }
                }
                .frame(height: 360)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(stats.isEmpty ? "Arrastra para girar, pellizca para acercar." : "\(stats). Arrastra para girar, pellizca para acercar.")
            }

            Section("Ubicación") {
                if let fix = FieldStore.representativeFix(FieldStore.fixes(entry)) {
                    LabeledContent("Latitud", value: fix.latitude.formatted(.number.precision(.fractionLength(6))))
                    LabeledContent("Longitud", value: fix.longitude.formatted(.number.precision(.fractionLength(6))))
                    LabeledContent("Precisión", value: "±\(fix.horizontalAccuracy.formatted(.number.precision(.fractionLength(1)))) m")
                }
                LabeledContent("Calidad", value: entry.scan.georeferenceQuality.label)
            }

            Section {
                Button {
                    export()
                } label: {
                    Label(exporting ? "Exportando…" : "Exportar PLY, STL, OBJ, LAS y GeoJSON", systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(exporting)
                ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if !exported.isEmpty {
                    ForEach(exported, id: \.self) { Text($0.lastPathComponent).font(.caption.monospaced()) }
                    ShareLink(items: exported) { Label("Compartir archivos", systemImage: "square.and.arrow.up") }
                }
            } header: {
                Text("Exportar")
            } footer: {
                Text("Los archivos quedan también en la app Archivos → En mi iPhone → ArqueoLiDAR → Exports.")
            }
        }
        .navigationTitle(entry.scan.purpose.label)
        .task { await load() }
    }

    private func load() async {
        let entry = entry
        do {
            let mesh = try await Task.detached { try FieldStore.loadMesh(entry) }.value
            stats = "\(mesh.vertices.count.formatted()) vértices · \(mesh.triangleCount.formatted()) triángulos"
            self.mesh = mesh
        } catch {
            loadError = "No se pudo leer la malla: \(error)"
        }
    }

    private func export() {
        exporting = true
        let entry = entry, finding = finding
        Task {
            do {
                let result = try await Task.detached { try FieldStore.export(entry, finding: finding) }.value
                exported = result.files
                problems = result.problems
            } catch {
                problems = ["No se pudo exportar: \(error)"]
            }
            exporting = false
        }
    }
}
