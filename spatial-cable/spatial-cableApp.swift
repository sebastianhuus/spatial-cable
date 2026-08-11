import SwiftUI

@main
struct SpatialCableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "spatial-cable",
            systemImage: appDelegate.isRelaying ? "waveform.circle.fill" : "cable.connector"
        ) {
            MenuBarContentView(appDelegate: appDelegate, processController: appDelegate.processController)
        }
        .menuBarExtraStyle(.menu)
    }
}
