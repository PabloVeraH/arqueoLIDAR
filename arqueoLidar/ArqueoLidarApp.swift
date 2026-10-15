import SwiftUI

@main
struct ArqueoLidarApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Terreno", systemImage: "camera.metering.matrix") { SitesListView() }
                Tab("Diagnóstico", systemImage: "checklist") { ContentView() }
            }
        }
    }
}
