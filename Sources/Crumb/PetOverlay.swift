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
    private var bubbleID = 0
    /// Holds the crumb bursts, above meals and below bubbles.
    private let effects = ClickThroughView()
    private var meal: (view: MealView, center: CGPoint, size: Double, mirrored: Bool)?
    /// Z's drifting up from the head while the puppy sleeps.
    private let snores = CAEmitterLayer()

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
        effects.frame = view.bounds
        effects.wantsLayer = true
        view.addSubview(effects)
        snores.frame = effects.bounds
        snores.emitterShape = .point
        snores.birthRate = 0
        snores.emitterCells = [Self.snoreCell]
        effects.layer?.addSublayer(snores)

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
        if let bubble { place(bubble) }
        // Just above the right side of the sleeping head (it faces the viewer when still).
        let f = pet.frame
        snores.emitterPosition = CGPoint(x: f.midX + f.width * 0.2, y: view.bounds.height - (f.minY + f.height * 0.2))
        snores.birthRate = pet.isAsleep ? 1 : 0
        // Take clicks only while the mouse is over the puppy or its bubble.
        let mouse = NSEvent.mouseLocation
        let topLeft = CGPoint(x: mouse.x - window.frame.minX, y: window.frame.maxY - mouse.y)
        let overBubble = bubble.map { b in
            CGRect(x: b.frame.minX, y: view.bounds.height - b.frame.maxY, width: b.frame.width, height: b.frame.height)
                .contains(topLeft)
        } ?? false
        window.ignoresMouseEvents = !(pet.frame.contains(topLeft) || overBubble)
    }

    /// Above the puppy's head, kept on screen.
    private func place(_ bubble: Bubble) {
        let size = bubble.frame.size
        let top = max(4, pet.frame.minY - size.height - 6)
        let x = min(max(4, pet.frame.midX - size.width / 2), view.bounds.width - size.width - 4)
        bubble.setFrameOrigin(NSPoint(x: x, y: view.bounds.height - top - size.height))
    }

    /// Shows a speech bubble above the puppy, replacing any current one; nil hides it.
    /// With `hideAfter`, it goes away by itself unless something else was said meanwhile.
    func say(_ text: String?, buttons: [(String, () -> Void)] = [], hideAfter: Duration? = nil) {
        bubble?.removeFromSuperview()
        bubble = text.map { Bubble($0, buttons: buttons) }
        if let bubble {
            place(bubble)  // before it's shown, or it flashes at the window's corner for a frame
            view.addSubview(bubble)
        }
        bubbleID += 1
        guard let hideAfter else { return }
        let id = bubbleID
        Task {
            try? await Task.sleep(for: hideAfter)
            if bubbleID == id { say(nil) }
        }
    }

    // MARK: - Eating

    /// Lays a same-size picture of an icon exactly over the real one. `center` is in Finder points (top-left).
    /// With `emerging`, it fades in while sliding from that point to `center` (out of the puppy's mouth).
    func showMeal(_ image: NSImage, at center: CGPoint, size: Double, mirrored: Bool, emerging from: CGPoint? = nil) {
        hideMeal()
        func frame(_ c: CGPoint) -> NSRect {
            NSRect(x: c.x - size / 2, y: view.bounds.height - c.y - size / 2, width: size, height: size)
        }
        let v = MealView(image: image, frame: frame(from ?? center), mirrored: mirrored)
        view.addSubview(v, positioned: .below, relativeTo: effects)
        if from != nil {
            v.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                v.animator().alphaValue = 1
                v.animator().frame = frame(center)
            }
        }
        meal = (v, center, size, mirrored)
    }

    /// Takes bite `k` of `n` out of the meal, with a burst of crumbs at the new edge.
    func biteMeal(_ k: Int, of n: Int) {
        guard let meal else { return }
        meal.view.holes = biteHoles(after: k, of: n)
        let edge = (Double(k) / Double(n) - 0.5) * meal.size * (meal.mirrored ? -1 : 1)
        crumbs(at: CGPoint(x: meal.center.x + edge, y: meal.center.y))
    }

    func hideMeal() {
        meal?.view.removeFromSuperview()
        meal = nil
    }

    /// One "z" every ~1.4 s: rises and sways right, grows, fades out over 3.5 s.
    private static let snoreCell: CAEmitterCell = {
        let font = NSFont.systemFont(ofSize: 44, weight: .heavy)  // drawn at 2x, shown at half: sharp on Retina
        let text = NSAttributedString(string: "z", attributes: [
            .font: font, .foregroundColor: NSColor.white,
            .strokeColor: NSColor(calibratedWhite: 0.15, alpha: 0.9), .strokeWidth: -4,  // outlined: readable on any wallpaper
        ])
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width) + 8, height: ceil(size.height) + 8), flipped: false) { _ in
            text.draw(at: NSPoint(x: 4, y: 4))
            return true
        }
        let cell = CAEmitterCell()
        cell.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cell.birthRate = 0.7
        cell.lifetime = 3.5
        cell.velocity = 16
        cell.emissionLongitude = .pi / 2  // up: layer coordinates point up
        cell.emissionRange = 0.25
        cell.xAcceleration = 5  // drift right as it rises
        cell.scale = 0.3
        cell.scaleSpeed = 0.12
        cell.spin = -0.15
        cell.spinRange = 0.2
        cell.alphaSpeed = -0.28
        return cell
    }()

    private static let crumb: CGImage = {
        let dot = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
        return dot.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }()

    /// A short burst of falling crumbs at a screen point (top-left origin).
    private func crumbs(at p: CGPoint) {
        let cell = CAEmitterCell()
        cell.contents = Self.crumb
        cell.color = NSColor(calibratedRed: 0.8, green: 0.6, blue: 0.38, alpha: 1).cgColor
        cell.redRange = 0.15
        cell.greenRange = 0.15
        cell.birthRate = 160
        cell.lifetime = 0.7
        cell.velocity = 110
        cell.velocityRange = 50
        cell.emissionLongitude = .pi / 2  // up: layer coordinates point up
        cell.emissionRange = .pi * 0.8
        cell.yAcceleration = -500  // gravity
        cell.scale = 0.7
        cell.scaleRange = 0.4
        cell.alphaSpeed = -1.2
        let emitter = CAEmitterLayer()
        emitter.frame = effects.bounds
        emitter.emitterPosition = CGPoint(x: p.x, y: effects.bounds.height - p.y)
        emitter.emitterShape = .point
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = [cell]
        effects.layer?.addSublayer(emitter)
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            emitter.birthRate = 0
            try? await Task.sleep(for: .seconds(1))
            emitter.removeFromSuperlayer()
        }
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

/// A view that never takes clicks.
final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows the pet menu on click.
final class PetView: ARView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // Crumb is never the active app; the first click should open the menu

    override func mouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
