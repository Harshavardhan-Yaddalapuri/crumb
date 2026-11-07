import AppKit
import CrumbCore
import QuickLookThumbnailing

/// A same-size picture of a file's icon, laid exactly over the real one while Crumb eats it. Bites cut holes.
/// Only one icon is ever visible: the file moves into the belly right after the picture appears, before the
/// first bite, so the real icon is gone from under the picture before any hole shows.
final class MealView: NSView {
    private let image: NSImage
    /// Eaten from the right (puppy facing left): holes are mirrored.
    private let mirrored: Bool
    var holes: [BiteHole] = [] {
        didSet { needsDisplay = true }
    }

    init(image: NSImage, frame: NSRect, mirrored: Bool) {
        self.image = image
        self.mirrored = mirrored
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // y down, like BiteHole
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the puppy

    override func draw(_ dirtyRect: NSRect) {
        // Fit the picture in the icon square, centred, like Finder does with wide previews.
        let s = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * s, height: image.size.height * s)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let ctx = NSGraphicsContext.current?.cgContext, !holes.isEmpty else { return }
        ctx.setBlendMode(.clear)
        for h in holes {
            let x = mirrored ? 1 - h.x : h.x
            ctx.fillEllipse(in: CGRect(
                x: (x - h.r) * bounds.width, y: (h.y - h.r) * bounds.height,
                width: 2 * h.r * bounds.width, height: 2 * h.r * bounds.height))
        }
    }
}

enum IconPicture {
    /// Finder's look for a file: its content preview drawn as an icon (screenshots, PDFs…), else its icon.
    /// Gives up on the preview after 2 s so a stuck Quick Look can't stall Crumb. Call it while the file is
    /// still in place.
    static func load(_ url: URL, size: Double) async -> NSImage {
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .all)
        request.iconMode = true
        let once = Once()
        let cg: CGImage? = await withCheckedContinuation { done in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                if once.claim() { done.resume(returning: rep?.cgImage) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if once.claim() { done.resume(returning: nil) }
            }
        }
        guard let cg else { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) / scale, height: Double(cg.height) / scale))
    }
}

/// Lets exactly one of several racing callbacks through.
final class Once: @unchecked Sendable {  // `done` is only touched under `lock`
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
