import Foundation
import SwiftUI
import Domain
import Geo
import Custody

/// Pantalla inicial: confirma que el paquete PaleoRegistro está enlazado
/// y permite probar dos módulos (Geo y Custody) directamente en el iPhone.
struct ContentView: View {
    @State private var results: [PaleoModule: [SelfCheck]] = [:]
    @State private var running: Set<PaleoModule> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(PaleoModule.allCases) { module in
                        NavigationLink {
                            ModuleTestView(module: module, results: $results, running: $running)
                        } label: {
                            ModuleRow(module: module, checks: results[module], isRunning: running.contains(module))
                        }
                    }
                } header: {
                    Text("Módulos PaleoRegistro")
                } footer: {
                    Text("Toca un módulo para ejecutar sus pruebas con datos sintéticos de resultado conocido.")
                }
                Section {
                    Button {
                        Task { await runAll() }
                    } label: {
                        Label(running.isEmpty ? "Probar todos los módulos" : "Probando…", systemImage: "play.circle")
                    }
                    .disabled(!running.isEmpty)
                    if !results.isEmpty {
                        let all = results.values.flatMap { $0 }
                        let ok = all.filter(\.passed).count
                        Text("\(ok) de \(all.count) verificaciones correctas en \(results.count) módulos")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Herramientas") {
                    NavigationLink("Conversor UTM (Geo)") { UTMDemoView() }
                    NavigationLink("Firma de custodia (Custody)") { CustodyDemoView() }
                }
            }
            .navigationTitle("ArqueoLiDAR")
        }
    }

    private func runAll() async {
        for module in PaleoModule.allCases {
            running.insert(module)
            results[module] = await SelfTestRunner.run(module)
            running.remove(module)
        }
    }
}

/// Ejecuta las pruebas fuera del hilo principal para no congelar la interfaz.
enum SelfTestRunner {
    static func run(_ module: PaleoModule) async -> [SelfCheck] {
        await Task.detached(priority: .userInitiated) {
            await module.run()
        }.value
    }
}

struct ModuleRow: View {
    let module: PaleoModule
    let checks: [SelfCheck]?
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.rawValue)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        guard let checks else { return module.summary }
        let ok = checks.filter(\.passed).count
        return "\(ok)/\(checks.count) correctas · \(module.summary)"
    }

    @ViewBuilder private var statusIcon: some View {
        if isRunning {
            ProgressView()
        } else if let checks {
            if checks.allSatisfy(\.passed) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

struct ModuleTestView: View {
    let module: PaleoModule
    @Binding var results: [PaleoModule: [SelfCheck]]
    @Binding var running: Set<PaleoModule>

    var body: some View {
        List {
            Section {
                Text(module.summary)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await run() }
                } label: {
                    Label(running.contains(module) ? "Ejecutando…" : "Ejecutar de nuevo", systemImage: "arrow.clockwise")
                }
                .disabled(running.contains(module))
            }
            if let checks = results[module] {
                Section("Resultados") {
                    ForEach(checks) { check in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(check.passed ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.name)
                                if !check.detail.isEmpty {
                                    Text(check.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            } else if running.contains(module) {
                HStack { ProgressView(); Text("Ejecutando pruebas…") }
            }
        }
        .navigationTitle(module.rawValue)
        .task {
            if results[module] == nil { await run() }
        }
    }

    private func run() async {
        guard !running.contains(module) else { return }
        running.insert(module)
        results[module] = await SelfTestRunner.run(module)
        running.remove(module)
    }
}

// MARK: - Geo

struct UTMDemoView: View {
    @State private var latitudeText = "-22.9087"
    @State private var longitudeText = "-68.1997"
    @State private var result = ""

    var body: some View {
        Form {
            Section("Coordenadas geodésicas (WGS 84)") {
                TextField("Latitud", text: $latitudeText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Longitud", text: $longitudeText)
                    .keyboardType(.numbersAndPunctuation)
                Button("Convertir a UTM", action: convert)
            }
            if !result.isEmpty {
                Section("Resultado") {
                    Text(result)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Conversor UTM")
    }

    private func convert() {
        guard let lat = Double(latitudeText.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitudeText.replacingOccurrences(of: ",", with: ".")) else {
            result = "Ingresa latitud y longitud numéricas."
            return
        }
        do {
            let utm: UTMCoordinate = try UTMConverter().toUTM(latitude: lat, longitude: lon)
            result = """
            Huso: \(utm.zone)\(utm.isNorthernHemisphere ? "N" : "S")
            Este:  \(String(format: "%.3f", utm.easting)) m
            Norte: \(String(format: "%.3f", utm.northing)) m
            EPSG:  \(utm.epsg)
            Datum: \(utm.datum)
            """
        } catch {
            result = "Error: \(error)"
        }
    }
}

// MARK: - Custody

struct CustodyDemoView: View {
    @State private var output = ""

    var body: some View {
        List {
            Section {
                Button("Generar clave y firmar texto de prueba", action: run)
            } footer: {
                Text("Usa una clave P-256 de software (no Secure Enclave). Solo para verificar que el módulo funciona.")
            }
            if !output.isEmpty {
                Section("Resultado") {
                    Text(output)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Custodia")
    }

    private func run() {
        let key = SoftwareSigningKey()
        let payload = Data("ArqueoLiDAR \(Date())".utf8)
        do {
            let signature = try key.sign(data: payload)
            output = """
            keyID: \(key.keyID)
            Clave pública (DER): \(key.publicKeyDER.count) bytes
            Firma ECDSA (DER): \(signature.count) bytes
            """
        } catch {
            output = "Error al firmar: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
