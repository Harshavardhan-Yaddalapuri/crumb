import AppKit
import RealityKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlay: PetOverlay?

    func applicationDidFinishLaunching(_ note: Notification) {
        Task {
            do {
                // Inside Crumb.app the model is a bundle resource; `swift run Crumb` from the repo root finds it in art/.
                let url = Bundle.main.url(forResource: "crumb", withExtension: "usdz")
                    ?? URL(fileURLWithPath: "art/crumb.usdz")
                let overlay = try PetOverlay(screen: NSScreen.screens[0], model: try await Entity(contentsOf: url))  // the menu-bar display; NSScreen.main follows keyboard focus
                self.overlay = overlay
                if let dir = ProcessInfo.processInfo.environment["CRUMB_SNAPSHOT"] {
                    try await overlay.snapshotPoses(to: URL(fileURLWithPath: dir))
                }
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, also when run outside the .app (LSUIElement covers the .app)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
