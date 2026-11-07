import Foundation

/// When Crumb may interrupt with "Eat …?". At most one Ask per 15 minutes; "Clean up now" asks back-to-back
/// until the belly is full or nothing is left; never while napping or with a full belly.
public struct AskPolicy: Equatable, Sendable {
    public static let gap: TimeInterval = 15 * 60

    public var lastAskAt: Date?
    /// Set by "Clean up now"; cleared when the belly fills or no candidates remain.
    public var cleaningUp = false

    public init(lastAskAt: Date? = nil) {
        self.lastAskAt = lastAskAt
    }

    public func mayAsk(now: Date, bellyFull: Bool, napping: Bool) -> Bool {
        if bellyFull || napping { return false }
        if cleaningUp { return true }
        guard let last = lastAskAt, last <= now else { return true }  // a clock set backwards doesn't block asks forever
        return now.timeIntervalSince(last) >= Self.gap
    }
}
