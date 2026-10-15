import SwiftUI

@main
struct ArqueoLidarApp: App {
    var body: some Scene {
        WindowGroup {
            // El autodiagnóstico de las librerías es para quien desarrolla: solo
            // aparece al instalar desde Xcode (Debug). TestFlight / App Store
            // compilan en Release y el usuario ve directamente Terreno.
            #if DEBUG
            TabView {
                Tab("Terreno", systemImage: "camera.metering.matrix") { SitesListView() }
                Tab("Diagnóstico", systemImage: "checklist") { ContentView() }
            }
            #else
            SitesListView()
            #endif
        }
    }
}
