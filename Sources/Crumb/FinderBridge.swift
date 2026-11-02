import CoreServices
import CrumbCore
import Foundation

/// The only code that talks to Finder. One compiled AppleScript runs on a private serial queue.
/// File names travel as Apple Event parameters, never pasted into script source, so a crafted
/// file name can't inject script.
final class FinderBridge: @unchecked Sendable {  // mutable state is only touched on `queue`
    struct Icon: Sendable {
        let name: String
        let position: CGPoint
    }

    enum Failure: Error, Equatable {
        /// Automation permission for Finder was denied (-1743).
        case notAuthorized
        case script(Int, String)
    }

    private let queue = DispatchQueue(label: "crumb.finder")
    private let script: NSAppleScript
    private var pendingDrag: (name: String, to: CGPoint)?

    /// Compiles on the main thread. Compiling on a background thread while the main run loop runs makes the
    /// first Finder call hang forever (found while writing Plan 3); running it on `queue` afterwards is fine.
    @MainActor
    init() {
        script = NSAppleScript(source: Self.source)!
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        precondition(compiled, "FinderBridge script doesn't compile: \(error ?? [:])")
    }

    private static let source = """
        on icons()
            tell application "Finder" to return {name, desktop position} of every item of desktop
        end icons
        on moveIcon(n, x, y)
            tell application "Finder"
                set desktop position of item n of desktop to {x, y}
                return desktop position of item n of desktop
            end tell
        end moveIcon
        """

    /// Every desktop icon's name and position. The first call triggers macOS's "wants to control Finder" prompt.
    func icons() async throws -> [Icon] {
        try await onQueue { [self] in
            let result = try call("icons")
            guard let names = result.atIndex(1), let points = result.atIndex(2), names.numberOfItems > 0 else { return [] }
            return (1...names.numberOfItems).compactMap { i in
                guard let name = names.atIndex(i)?.stringValue, let p = points.atIndex(i) else { return nil }
                return Icon(name: name, position: Self.point(p))
            }
        }
    }

    /// Moves an icon and reads its position back; retries once. Finder silently ignores some positions
    /// (anything off-screen), so only a read-back proves the move. Returns false if it didn't stick.
    func place(_ name: String, at p: CGPoint) async throws -> Bool {
        try await onQueue { [self] in
            for _ in 0..<2 {
                if Self.close(Self.point(try call("moveIcon", name, p)), p) { return true }
            }
            return false
        }
    }

    /// Streams an icon along while the puppy carries it. Latest wins: if Finder is still busy with the
    /// previous move, only the newest point is sent next. Errors are ignored; `place` verifies the drop.
    func drag(_ name: String, to p: CGPoint) {
        queue.async { [self] in
            let flushQueued = pendingDrag != nil
            pendingDrag = (name, p)
            guard !flushQueued else { return }
            queue.async { [self] in
                guard let next = pendingDrag else { return }
                pendingDrag = nil
                _ = try? call("moveIcon", next.name, next.to)
            }
        }
    }

    /// Finder's desktop view settings (readable without any permission).
    static func layout() -> FinderLayout {
        let desktop = UserDefaults(suiteName: "com.apple.finder")?.dictionary(forKey: "DesktopViewSettings") ?? [:]
        let icons = desktop["IconViewSettings"] as? [String: Any] ?? [:]
        func number(_ key: String, _ fallback: Double) -> Double { (icons[key] as? NSNumber)?.doubleValue ?? fallback }
        return FinderLayout(
            iconSize: number("iconSize", 64),
            gridSpacing: number("gridSpacing", 54),
            textSize: number("textSize", 12),
            labelOnBottom: number("labelOnBottom", 1) != 0,
            arrangeBy: icons["arrangeBy"] as? String ?? "none",
            groupBy: desktop["GroupBy"] as? String ?? "None")
    }

    // MARK: - Apple Events

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in queue.async { done.resume(with: Result { try work() }) } }
    }

    /// Calls a handler in `source` with string / point arguments. Must run on `queue`.
    private func call(_ handler: String, _ name: String? = nil, _ p: CGPoint? = nil) throws -> NSAppleEventDescriptor {
        let args = NSAppleEventDescriptor.list()
        if let name { args.insert(NSAppleEventDescriptor(string: name), at: 1) }
        if let p {
            args.insert(NSAppleEventDescriptor(int32: Int32(p.x.rounded())), at: 2)
            args.insert(NSAppleEventDescriptor(int32: Int32(p.y.rounded())), at: 3)
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: Self.code("ascr"), eventID: Self.code("psbr"),  // AppleScript "call subroutine"
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: Self.code("snam"))
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw Self.failure(error) }
        return result
    }

    private static func failure(_ info: NSDictionary?) -> Failure {
        let number = info?[NSAppleScript.errorNumber] as? Int ?? 0
        if number == -1743 { return .notAuthorized }
        return .script(number, info?[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func point(_ d: NSAppleEventDescriptor) -> CGPoint {
        CGPoint(x: Double(d.atIndex(1)?.int32Value ?? .min), y: Double(d.atIndex(2)?.int32Value ?? .min))
    }

    private static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
}
