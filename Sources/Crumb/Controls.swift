import AppKit

/// A speech bubble above the puppy: a short message and optional buttons. Always light, like a comic bubble.
final class Bubble: NSView {
    init(_ text: String, buttons: [(String, () -> Void)]) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .black
        label.preferredMaxLayoutWidth = 220
        var rows: [NSView] = [label]
        if !buttons.isEmpty { rows.append(NSStackView(views: buttons.map { ActionButton($0.0, $0.1) })) }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}  // clicks on the bubble shouldn't open the pet menu
}

/// NSButton that runs a closure. Takes the first click even though Crumb is never the active app.
final class ActionButton: NSButton {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// The Belly submenu: what Crumb has eaten, newest first, each with Spit out. Rebuilt every time it opens so
/// the minutes stay current.
@MainActor
final class BellyMenu: NSMenu, NSMenuDelegate {
    static let shown = 20
    private let eater: Eater

    init(eater: Eater) {
        self.eater = eater
        super.init(title: "Belly")
        autoenablesItems = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        let entries = eater.belly.history.suffix(Self.shown).reversed()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            addItem(empty)
        }
        for e in entries {
            let minutes = max(1, Int((e.digestEndsAt.timeIntervalSinceNow / 60).rounded(.up)))
            let when = e.burped ? "in the Trash" : "burps in \(minutes) min"
            let item = ActionItem("Spit out “\(Eater.name(e))” (\(when))") { [eater] in eater.spitOut(e.id) }
            item.isEnabled = !eater.isBusy
            addItem(item)
        }
    }
}
