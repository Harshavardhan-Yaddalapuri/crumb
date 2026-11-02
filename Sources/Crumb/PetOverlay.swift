import AppKit
import Combine
import CrumbCore
import RealityKit

// ponytail: full-screen ARView renders every frame, ~24% CPU measured while wandering (Plan 2, Task 7). Upgrade path: a pet-sized window that moves with the puppy, or a lower frame rate when idle.
/// The puppy's window: borderless, transparent, covering the main screen just above the desktop icons.
/// Clicks pass through everywhere except on the puppy and its speech bubble.
@MainActor
final class PetOverlay {
    /// Points per metre: the 1.2 m model ends up about 110 pt tall.
    static let pointsPerMeter = 92.0

    let window: NSWindow
    let view: PetView
    let pet: Pet
    private var updates: Cancellable?
    private var bubble: Bubble?

    init(screen: NSScreen, model: Entity) throws {
        let size = screen.frame.size
        let map = ScreenMap(width: size.width, height: size.height, pointsPerMeter: Self.pointsPerMeter)
        // visibleFrame.minY is the Dock's height when the Dock is at the bottom (AppKit's y points up).
        let groundY = size.height - (screen.visibleFrame.minY - screen.frame.minY) - 6

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        view = PetView(frame: NSRect(origin: .zero, size: size))
        view.environment.background = .color(.clear)
        window.contentView = view

        let anchor = AnchorEntity(world: .zero)
        view.scene.addAnchor(anchor)
        let camera = Entity()
        var lens = OrthographicCameraComponent()
        lens.scale = map.cameraScale
        camera.components.set(lens)
        camera.position = [0, 0, 10]
        anchor.addChild(camera)
        let light = DirectionalLight()
        light.light.intensity = 3000
        light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        anchor.addChild(light)

        let rig = try PuppetRig(model: model)
        anchor.addChild(rig.entity)
        pet = Pet(rig: rig, map: map, groundY: groundY)

        updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(dt: event.deltaTime) }
        }
        window.orderFrontRegardless()
    }

    private func tick(dt: Double) {
        pet.update(dt: dt)
        // The bubble rides above the puppy's head. Views use AppKit's y-up coordinates; the pet's frame is top-left.
        if let bubble {
            let size = bubble.frame.size
            let top = max(4, pet.frame.minY - size.height - 6)
            let x = min(max(4, pet.frame.midX - size.width / 2), view.bounds.width - size.width - 4)
            bubble.setFrameOrigin(NSPoint(x: x, y: view.bounds.height - top - size.height))
        }
        // Take clicks only while the mouse is over the puppy or its bubble.
        let mouse = NSEvent.mouseLocation
        let topLeft = CGPoint(x: mouse.x - window.frame.minX, y: window.frame.maxY - mouse.y)
        let overBubble = bubble.map { b in
            CGRect(x: b.frame.minX, y: view.bounds.height - b.frame.maxY, width: b.frame.width, height: b.frame.height)
                .contains(topLeft)
        } ?? false
        window.ignoresMouseEvents = !(pet.frame.contains(topLeft) || overBubble)
    }

    /// Shows a speech bubble above the puppy, replacing any current one; nil hides it.
    func say(_ text: String?, buttons: [(String, () -> Void)] = []) {
        bubble?.removeFromSuperview()
        bubble = text.map { Bubble($0, buttons: buttons) }
        if let bubble { view.addSubview(bubble) }
    }

    /// Writes one PNG per pose (plus "walk") into `dir`, cropped around the puppy, then quits.
    func snapshotPoses(to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pet.autopilot = false
        for name in PoseName.allCases.map(\.rawValue) + ["walk"] {
            pet.show(name)
            try await Task.sleep(for: .milliseconds(name == "walk" ? 900 : 600))
            let image: NSImage? = await withCheckedContinuation { done in
                view.snapshot(saveToHDR: false) { done.resume(returning: $0) }
            }
            guard let image, var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let px = Double(cg.width) / pet.map.width
            let r = pet.frame.insetBy(dx: -30, dy: -30)
            if let crop = cg.cropping(to: CGRect(x: r.minX * px, y: r.minY * px, width: r.width * px, height: r.height * px)) {
                cg = crop
            }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try png?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        NSApp.terminate(nil)
    }
}

/// Shows the pet menu on click.
final class PetView: ARView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // Crumb is never the active app; the first click should open the menu

    override func mouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
