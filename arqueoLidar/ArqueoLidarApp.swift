import SwiftUI

@main
struct ArqueoLidarApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Terreno", systemImage: "camera.metering.matrix") { FindingsListView() }
                Tab("Diagnóstico", systemImage: "checklist") { ContentView() }
            }
        }
    }
}
