import SwiftUI
import Domain
import Custody
import Volume

// ═══════════════════════════════════════════════════════════════════════════════
// Flujo de terreno: sitios → hallazgos del sitio → ficha del hallazgo → escanear
// (CaptureView: LiDAR + GPS, se sella al guardar) → ver en 3D → exportar.
// ═══════════════════════════════════════════════════════════════════════════════

struct SitesListView: View {
    @State private var sites: [Site] = []
    @State private var counts: [UUID: Int] = [:]
    @State private var orphans = 0
    @State private var showNew = false
    @State private var editing: Site?
    @State private var pendingDelete: Site?
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(sites, id: \.siteID) { site in
                    NavigationLink {
                        FindingsListView(site: site)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name)
                            Text("\(site.code) · \(counts[site.siteID] ?? 0) hallazgos\(site.location == nil ? " · sin ubicación" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            pendingDelete = site
                        } label: {
                            Label("Eliminar", systemImage: "trash")
                        }
                        Button {
                            editing = site
                        } label: {
                            Label("Editar", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                if orphans > 0 {
                    NavigationLink {
                        FindingsListView(site: nil)
                    } label: {
                        Label("Hallazgos sin sitio (\(orphans))", systemImage: "questionmark.folder")
                    }
                }
            }
            .confirmationDialog(
                "¿Eliminar el sitio «\(pendingDelete?.name ?? "")»?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { site in
                Button("Eliminar sitio", role: .destructive) { delete(site) }
            } message: { _ in
                Text("Solo se pueden eliminar sitios sin hallazgos. No se puede deshacer.")
            }
            .alert("No se eliminó", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
            .overlay {
                if sites.isEmpty && orphans == 0 {
                    ContentUnavailableView("Sin sitios", systemImage: "map",
                                           description: Text("Toca + para registrar el sitio o yacimiento donde trabajas."))
                }
            }
            .navigationTitle("Sitios")
            .toolbar {
                Button { showNew = true } label: { Label("Nuevo sitio", systemImage: "plus") }
            }
            .sheet(isPresented: $showNew, onDismiss: reload) { SiteFormView(site: nil) }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }), onDismiss: reload) {
                if let editing { SiteFormView(site: editing) }
            }
            .refreshable { reload() }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        sites = FieldStore.sites()
        let known = Set(sites.map(\.siteID))
        let all = FieldStore.findings()
        counts = Dictionary(grouping: all, by: \.siteID).mapValues(\.count)
        orphans = all.filter { !known.contains($0.siteID) }.count
    }

    private func delete(_ site: Site) {
        do {
            try FieldStore.deleteSite(site)
        } catch {
            deleteError = error.localizedDescription
        }
        reload()
    }
}

/// Alta (`site == nil`) o edición de la ficha del sitio, con su punto GPS.
struct SiteFormView: View {
    let site: Site?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var code: String
    @State private var location: GeoFix?
    @State private var gps = LocationRecorder()
    @State private var measuring = false
    @State private var error: String?

    init(site: Site?) {
        self.site = site
        _name = State(initialValue: site?.name ?? "")
        _code = State(initialValue: site?.code ?? "")
        _location = State(initialValue: site?.location)
    }

    private var isValid: Bool {
        ![name, code].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nombre (ej. Quebrada de Los Ratones)", text: $name)
                    TextField("Código del sitio (ej. QLR-01)", text: $code)
                } footer: {
                    Text(site == nil
                         ? "El sitio agrupa los hallazgos. Cada expediente guarda una copia de esta ficha."
                         : "Los expedientes ya creados conservan la ficha tal como era al crearlos.")
                }

                Section {
                    if let location {
                        LabeledContent("Latitud", value: location.latitude.formatted(.number.precision(.fractionLength(6))))
                        LabeledContent("Longitud", value: location.longitude.formatted(.number.precision(.fractionLength(6))))
                        LabeledContent("Altura elipsoidal", value: "\(location.altitude.formatted(.number.precision(.fractionLength(1)))) m")
                        LabeledContent("Precisión", value: "±\(location.horizontalAccuracy.formatted(.number.precision(.fractionLength(1)))) m")
                    }
                    if measuring {
                        Text(gps.statusText).font(.caption)
                        Button("Usar esta ubicación") {
                            location = FieldStore.representativeFix(gps.fixes)
                            stopGPS()
                        }
                        .disabled(gps.fixes.isEmpty)
                        Button("Cancelar", role: .cancel, action: stopGPS)
                    } else {
                        Button {
                            gps.start()
                            measuring = true
                        } label: {
                            Label(location == nil ? "Tomar ubicación con GPS" : "Volver a tomar ubicación",
                                  systemImage: "location")
                        }
                    }
                } header: {
                    Text("Ubicación")
                } footer: {
                    Text("Párate en el punto de referencia del sitio y espera unos segundos: la app combina todas las lecturas. Bajo techo la precisión empeora.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(site == nil ? "Nuevo sitio" : "Editar sitio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(site == nil ? "Crear" : "Guardar", action: save).disabled(!isValid || measuring)
                }
            }
            .onDisappear(perform: stopGPS)
        }
    }

    private func stopGPS() {
        gps.stop()
        measuring = false
    }

    private func save() {
        var updated = site ?? Site(name: "", code: "")
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.code = code.trimmingCharacters(in: .whitespaces)
        updated.location = location
        do {
            try FieldStore.saveSite(updated)
            dismiss()
        } catch {
            self.error = "No se pudo guardar el sitio: \(error)"
        }
    }
}

struct FindingsListView: View {
    /// `nil` = hallazgos creados antes de que existieran los sitios.
    let site: Site?
    @State private var findings: [Finding] = []
    @State private var showNew = false
    @State private var pendingDelete: Finding?
    @State private var deleteError: String?

    var body: some View {
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
            .swipeActions {
                Button(role: .destructive) {
                    pendingDelete = finding
                } label: {
                    Label("Eliminar", systemImage: "trash")
                }
            }
        }
        .confirmationDialog(
            "¿Eliminar «\(pendingDelete?.title ?? "")»?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { finding in
            Button("Eliminar expediente", role: .destructive) { delete(finding) }
        } message: { _ in
            Text("Solo se pueden eliminar expedientes sin escaneos o que no pasan la verificación de custodia. Los expedientes íntegros son evidencia y quedan protegidos. No se puede deshacer.")
        }
        .alert("No se eliminó", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
        .overlay {
            if findings.isEmpty {
                ContentUnavailableView("Sin hallazgos", systemImage: "fossil.shell",
                                       description: Text("Toca + para crear el expediente de un hallazgo."))
            }
        }
        .navigationTitle(site?.name ?? "Sin sitio")
        .toolbar {
            if site != nil {
                Button { showNew = true } label: { Label("Nuevo hallazgo", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showNew, onDismiss: reload) {
            if let site { NewFindingView(site: site) }
        }
        .refreshable { reload() }
        .onAppear(perform: reload)
    }

    private func reload() { findings = FieldStore.findings(in: site) }

    private func delete(_ finding: Finding) {
        Task {
            do {
                try await FieldStore.deleteIfNotIntact(finding)
            } catch {
                deleteError = error.localizedDescription
            }
            reload()
        }
    }
}

struct NewFindingView: View {
    let site: Site
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
                    LabeledContent("Sitio", value: "\(site.name) (\(site.code))")
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
        let finding = Finding(siteID: site.siteID, title: title, expeditionCode: expeditionCode, author: author,
                              permit: permitNumber.isEmpty ? nil : CMNPermit(number: permitNumber, institution: institution))
        do {
            try FieldStore.createFinding(finding, site: site)
            dismiss()
        } catch {
            self.error = "No se pudo crear el expediente: \(error)"
        }
    }
}

struct FindingDetailView: View {
    let finding: Finding
    @State private var scans: [ScanEntry] = []
    @State private var history: [SealChange] = []
    @State private var notes: [String: CustodyNote] = [:]
    @State private var recovered: [String] = []
    @State private var showSealNote = false
    @State private var showCapture = false
    @State private var verdict: CustodyVerdict?
    @State private var verifying = false

    var body: some View {
        List {
            if !recovered.isEmpty {
                Section {
                    Label("Se apartaron \(recovered.count) elemento(s) que no alcanzaron a sellarse (por ejemplo, la app se cerró mientras guardaba). El expediente sigue íntegro.",
                          systemImage: "tray.and.arrow.down")
                    ForEach(recovered, id: \.self) { Text(CustodyText.describe(path: $0, scans: scans)).font(.caption) }
                } footer: {
                    Text("Quedaron en Archivos → En mi iPhone → ArqueoLiDAR → Recuperados, fuera del expediente. Si era un escaneo, vuelve a hacerlo.")
                }
            }

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
                            if let line = FieldStore.replacementText(entry, among: scans) {
                                Text(line).font(.caption).foregroundStyle(.orange)
                            }
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
                Button {
                    showSealNote = true
                } label: {
                    Label("Sellar estado actual (antes / después de intervenir)", systemImage: "checkmark.seal")
                }
                .disabled(scans.isEmpty)
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
                            ForEach(Array(errors.enumerated()), id: \.offset) {
                                Text("• " + CustodyText.describe($0.element, scans: scans)).font(.caption)
                            }
                            DisclosureGroup("Detalle técnico (para peritaje)") {
                                ForEach(Array(errors.enumerated()), id: \.offset) {
                                    Text(String(describing: $0.element)).font(.caption2.monospaced()).textSelection(.enabled)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
            } header: {
                Text("Cadena de custodia")
            } footer: {
                Text("Para verificarlo en una Mac sin la app: python3 tools/verify_chain.py <carpeta \(FieldStore.findingDir(finding).lastPathComponent)>")
            }

            if !history.isEmpty {
                Section {
                    ForEach(history.reversed(), id: \.seal.index) { change in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sello N.º \(change.seal.index + 1) · \(change.seal.wallClock.formatted(date: .abbreviated, time: .shortened))")
                                .font(.subheadline.weight(.semibold))
                            ForEach(CustodyText.sealedItems(change, scans: scans, notes: notes), id: \.self) {
                                Text($0).font(.caption)
                            }
                            Text(CustodyText.signature(change.seal)).font(.caption2).foregroundStyle(.secondary)
                            if change.seal.previousKeyID != nil {
                                Label("Cambio de clave declarado (otro iPhone o clave nueva)", systemImage: "key")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                } header: {
                    Text("Historial de sellos (\(history.count))")
                } footer: {
                    Text("Cada sello firma todo el expediente en ese momento y encadena con el anterior. La hora es la del teléfono al sellar. Este historial muestra lo que dice la cadena; para saber si alguien la alteró, use «Verificar expediente».")
                }
            }
        }
        .navigationTitle(finding.title)
        .fullScreenCover(isPresented: $showCapture, onDismiss: reload) {
            CaptureView(finding: finding)
        }
        .sheet(isPresented: $showSealNote) {
            CustodySealView(finding: finding, onSealed: reload)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        recovered += FieldStore.recoverUnsealed(finding)
        scans = FieldStore.scans(of: finding)
        history = FieldStore.sealHistory(finding)
        notes = FieldStore.notes(finding)
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
    @State private var volumes: [VolumeMeasurement] = []
    @State private var siblings: [ScanEntry] = []
    @State private var colorByHeight = false

    /// +Y es la vertical en el marco de la captura: la altura no depende del norte.
    static let heightColoring = ScalarColoring(id: "altura", title: "Altura sobre el punto más bajo",
                                               scale: 100, unit: "cm", relative: true, value: { $0.y })
    @State private var showReplace = false

    private var isReplaced: Bool { siblings.contains { $0.scan.supersedes == entry.scan.scanID } }

    var body: some View {
        List {
            Section {
                ZStack {
                    if let mesh {
                        MeshViewer(mesh: mesh, coloring: colorByHeight ? Self.heightColoring : nil)
                    } else if let loadError {
                        Text(loadError).foregroundStyle(.red)
                    } else {
                        ProgressView("Cargando malla…")
                    }
                }
                .frame(height: 360)
                .listRowInsets(EdgeInsets())
                Toggle("Colorear por altura", isOn: $colorByHeight)
            } footer: {
                Text(stats.isEmpty ? "Arrastra para girar, pellizca para acercar." : "\(stats). Arrastra para girar, pellizca para acercar.")
            }

            Section {
                ForEach(volumes, id: \.measurementID) { saved in
                    ForEach(saved.measurements, id: \.measurementID) { VolumeMeasurementRow(measurement: $0) }
                }
                if let mesh {
                    NavigationLink {
                        VolumeMeasureView(entry: entry, finding: finding, mesh: mesh) { reloadVolumes() }
                    } label: {
                        Label("Medir volumen", systemImage: "cube.transparent")
                    }
                }
            } header: {
                Text("Volumen")
            } footer: {
                Text("MEDIDO: sale directo de la malla escaneada. INFERIDO: la app tuvo que suponer una parte que no se ve (la base apoyada en el suelo o la superficie original de un daño). No presente un valor inferido como medido.")
            }

            Section {
                if let line = FieldStore.replacementText(entry, among: siblings) {
                    Text(line).foregroundStyle(.orange)
                }
                Button {
                    showReplace = true
                } label: {
                    Label("Reemplazar este escaneo", systemImage: "arrow.triangle.2.circlepath.camera")
                }
                .disabled(isReplaced)
            } header: {
                Text("Reemplazo")
            } footer: {
                Text("Si este escaneo salió mal, haz uno nuevo que lo reemplace. Este no se borra: la evidencia sellada se conserva y el nuevo declara a cuál reemplaza y por qué.")
            }

            if let quality = FieldStore.quality(entry) {
                Section {
                    LabeledContent("Duración", value: "\(Int((quality.duration / 60).rounded())) min")
                    LabeledContent("Recorrido de la cámara", value: "\(Int(quality.pathLength)) m")
                    if quality.flags.isEmpty {
                        Label("Sin advertencias", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                    ForEach(quality.flags, id: \.self) {
                        Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Calidad de la captura")
                }
            }

            Section {
                if let fix = FieldStore.location(entry) {
                    LabeledContent("Latitud", value: fix.latitude.formatted(.number.precision(.fractionLength(6))))
                    LabeledContent("Longitud", value: fix.longitude.formatted(.number.precision(.fractionLength(6))))
                    LabeledContent("Precisión", value: fix.horizontalAccuracy < 1
                                   ? "±\(Int((fix.horizontalAccuracy * 100).rounded())) cm"
                                   : "±\(fix.horizontalAccuracy.formatted(.number.precision(.fractionLength(1)))) m")
                    LabeledContent("Fuente", value: fix.source == .manual ? "Punto de control (topógrafo)" : "GPS del iPhone")
                }
                LabeledContent("Calidad", value: entry.scan.georeferenceQuality.label)
                if let frame = entry.scan.siteFrame {
                    LabeledContent("Norte verdadero",
                                   value: "±\((frame.yawSigma * 180 / .pi).formatted(.number.precision(.fractionLength(1))))°, \(entry.scan.northMethod == .controlPoints ? "por puntos de control" : "por recorrido y GPS")")
                } else if let note = entry.scan.northNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Ubicación y orientación")
            } footer: {
                Text("El norte verdadero orienta el modelo 3D respecto del terreno: hace falta para la dirección de los estratos y para comparar campañas.")
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
        .onAppear(perform: reloadVolumes)
        .fullScreenCover(isPresented: $showReplace, onDismiss: reloadVolumes) {
            CaptureView(finding: finding, replacing: entry)
        }
    }

    private func reloadVolumes() {
        volumes = FieldStore.measurements(of: entry, finding: finding)
        siblings = FieldStore.scans(of: finding)
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
