import AppKit
import CrumbCore
import RealityKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlay: PetOverlay?
    var hauler: Hauler?
    var watcher: FolderWatcher?

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
                    return
                }
                let hauler = Hauler(finder: FinderBridge(), overlay: overlay)
                self.hauler = hauler
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                watcher = FolderWatcher(desktop) { hauler.tidy() }
                buildMenu()
                hauler.tidy()
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
                NSApp.terminate(nil)
            }
        }
    }
}

extension AppDelegate {
    /// The pet menu (click the puppy). Rebuilt when a choice changes so the checkmark follows.
    func buildMenu() {
        guard let overlay, let hauler else { return }
        let sortMenu = NSMenu()
        for mode in SortMode.allCases {
            sortMenu.addItem(ActionItem(mode.rawValue.capitalized, checked: hauler.sort == mode) { [weak self] in
                hauler.sort = mode
                self?.buildMenu()
            })
        }
        let sortItem = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        sortItem.submenu = sortMenu
        let menu = NSMenu()
        menu.addItem(sortItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Crumb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        overlay.view.menu = menu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, also when run outside the .app (LSUIElement covers the .app)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
