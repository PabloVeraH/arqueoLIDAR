import SwiftUI
import SceneKit
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// Flujo de terreno: lista de hallazgos → ficha del hallazgo → escanear (LiDAR +
// GPS, se sella al guardar) → ver en 3D → exportar.
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
    @AppStorage("author.name") private var name = ""
    @AppStorage("author.role") private var role = ""
    @AppStorage("author.institution") private var institution = ""

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

            Section("Cadena de custodia") {
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
            }
        }
        .navigationTitle(finding.title)
        .fullScreenCover(isPresented: $showCapture, onDismiss: reload) {
            ScanCaptureView(finding: finding)
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        scans = FieldStore.scans(of: finding)
        verdict = nil
    }
}

struct ScanCaptureView: View {
    let finding: Finding
    @Environment(\.dismiss) private var dismiss
    @State private var capture = LiDARCapture()
    @State private var location = LocationRecorder()
    @State private var purpose: ScanPurpose = .baseline
    @State private var scanning = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if LiDARCapture.isSupported {
                    ZStack(alignment: .bottom) {
                        ARPreview(view: capture.arView).ignoresSafeArea()
                        controls
                    }
                } else {
                    ContentUnavailableView("Este dispositivo no tiene LiDAR", systemImage: "sensor",
                                           description: Text("Se necesita un iPhone Pro (12 o posterior) o un iPad Pro."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { cancel() }.disabled(saving)
                }
            }
        }
        .onDisappear { location.stop() }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if !scanning && !saving {
                Picker("Propósito", selection: $purpose) {
                    ForEach(ScanPurpose.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
            Text(gpsStatus).font(.footnote)
            if scanning {
                Text("Recorre el hallazgo lentamente, a 0,5-3 m, hasta cubrirlo con la malla.")
                    .font(.caption).multilineTextAlignment(.center)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if saving {
                ProgressView("Guardando y sellando…")
            } else {
                Button(scanning ? "Terminar y guardar" : "Iniciar escaneo") {
                    scanning ? finish() : start()
                }
                .buttonStyle(.borderedProminent)
                .tint(scanning ? .red : .accentColor)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var gpsStatus: String {
        if location.denied { return "GPS: permiso denegado (actívalo en Ajustes → Privacidad → Ubicación)" }
        guard scanning || !location.fixes.isEmpty else { return "GPS: se registrará durante el escaneo" }
        guard let best = location.bestAccuracy else { return "GPS: buscando señal…" }
        return "GPS: \(location.fixes.count) lecturas · mejor ±\(best.formatted(.number.precision(.fractionLength(1)))) m"
    }

    private func start() {
        error = nil
        capture.start()
        location.start()
        scanning = true
    }

    private func finish() {
        let parts = capture.stop()
        location.stop()
        scanning = false
        saving = true
        let fixes = location.fixes
        Task {
            do {
                _ = try await FieldStore.saveScan(parts: parts, fixes: fixes, purpose: purpose, finding: finding)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }

    private func cancel() {
        if scanning { _ = capture.stop() }
        location.stop()
        dismiss()
    }
}

struct ScanDetailView: View {
    let entry: ScanEntry
    let finding: Finding
    @State private var scene: SCNScene?
    @State private var stats = ""
    @State private var loadError: String?
    @State private var exported: [URL] = []
    @State private var problems: [String] = []
    @State private var exporting = false

    var body: some View {
        List {
            Section {
                ZStack {
                    if let scene {
                        SceneView(scene: scene, pointOfView: scene.rootNode.childNode(withName: "camera", recursively: false),
                                  options: [.allowsCameraControl, .autoenablesDefaultLighting])
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
            scene = MeshScene.make(mesh)
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

/// Convierte una malla de dominio en una escena SceneKit con cámara encuadrada.
enum MeshScene {
    static func make(_ mesh: Mesh) -> SCNScene {
        var sources = [SCNGeometrySource(vertices: mesh.vertices.map { SCNVector3($0.x, $0.y, $0.z) })]
        if let normals = mesh.normals {
            sources.append(SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }))
        }
        let geometry = SCNGeometry(sources: sources,
                                   elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.80, green: 0.66, blue: 0.48, alpha: 1)
        material.isDoubleSided = true
        geometry.materials = [material]

        let scene = SCNScene()
        scene.background.contents = UIColor.systemGray6
        let node = SCNNode(geometry: geometry)
        scene.rootNode.addChildNode(node)

        let (minB, maxB) = node.boundingBox
        let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        let size = max(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z, 0.1)
        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(center.x, center.y + size * 0.6, center.z + size * 1.4)
        camera.look(at: center)
        scene.rootNode.addChildNode(camera)
        return scene
    }
}
