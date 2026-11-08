import AppKit
import CrumbCore
import RealityKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlay: PetOverlay?
    var hauler: Hauler?
    var watcher: FolderWatcher?
    var iconCheck: Timer?
    var eater: Eater?

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
                let finder = FinderBridge()
                let hauler = Hauler(finder: finder, overlay: overlay)
                self.hauler = hauler
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                watcher = FolderWatcher(desktop) { hauler.tidy() }
                // ponytail: polls Finder every 5 s (one ~0.1 s Apple Event; a tidy with no gaps does nothing). Finder
                // has no notification for icon moves; Accessibility could give one but needs another permission.
                // Moving icons around doesn't change the folder, so look for new gaps regularly. Not while a mouse
                // button is down: the user may be mid-drag.
                iconCheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if NSEvent.pressedMouseButtons == 0 { hauler.tidy() }
                    }
                }
                startEating(finder: finder, overlay: overlay, hauler: hauler)
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
    /// Eaten files wait in ~/Library/Application Support/Crumb/Belly. Without a belly Crumb only tidies.
    func startEating(finder: FinderBridge, overlay: PetOverlay, hauler: Hauler) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            let belly = try Belly(directory: support.appendingPathComponent("Crumb/Belly"))
            let eater = Eater(belly: belly, overlay: overlay, finder: finder, hauler: hauler)
            self.eater = eater
            eater.onChange = { [weak self] in self?.buildMenu() }
            eater.start()
        } catch {
            NSLog("Crumb: can't open the belly, so no eating: \(error)")
        }
    }

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
        if let eater {
            menu.addItem(ActionItem("Clean up now") { eater.cleanUpNow() })
            let bellyItem = NSMenuItem(title: "Belly", action: nil, keyEquivalent: "")
            bellyItem.submenu = BellyMenu(eater: eater)
            menu.addItem(bellyItem)
        }
        menu.addItem(sortItem)
        if let eater {
            menu.addItem(
                eater.restUntil == nil
                    ? ActionItem("Nap for 1h") { eater.napForAnHour() }
                    : ActionItem("Wake up") { eater.wakeUp() })
            let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
            settingsItem.submenu = SettingsMenu(eater: eater)
            menu.addItem(settingsItem)
        }
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
