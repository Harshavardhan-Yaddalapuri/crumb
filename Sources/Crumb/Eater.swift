import AppKit
import CrumbCore

/// Finds junk on the desktop, asks before eating it, and eats it: bites come out of a same-size picture laid over
/// the real icon while the file moves into the belly. Each file burps into the Trash 15 minutes later; until the
/// Trash is emptied, `spitOut` puts it back. Only one job (sniff, ask, eat) runs at a time, and never during a tidy.
@MainActor
final class Eater {
    static let checkEvery: Duration = .seconds(30)
    static let answerTimeout: Duration = .seconds(60)
    /// A file that can't be trashed (or a ledger that can't be saved) stays overdue; retry this often, not in a loop.
    static let burpRetry: TimeInterval = 30

    let belly: Belly
    /// A sniff/ask/eat job is running.
    private(set) var isBusy = false
    /// Asleep: stuffed (until a slot frees) or resting after "Nap for 1h".
    private(set) var napping = false
    /// When a "Nap for 1h" rest ends; nil when not resting.
    private(set) var restUntil: Date?
    /// Called when the belly or the rest changes, so the menu can follow.
    var onChange: () -> Void = {}

    private let overlay: PetOverlay
    private let finder: FinderBridge
    private let hauler: Hauler
    private let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    private let defaults = UserDefaults.standard
    private var policy: AskPolicy
    private var burpTimer: Task<Void, Never>?
    private var lastBurpAttempt = Date.distantPast
    private var loop: Task<Void, Never>?
    private var restTimer: Task<Void, Never>?
    private var pet: Pet { overlay.pet }

    init(belly: Belly, overlay: PetOverlay, finder: FinderBridge, hauler: Hauler) {
        self.belly = belly
        self.overlay = overlay
        self.finder = finder
        self.hauler = hauler
        let last = UserDefaults.standard.double(forKey: "lastAskAt")
        policy = AskPolicy(lastAskAt: last > 0 ? Date(timeIntervalSince1970: last) : nil)
    }

    /// Burps anything overdue (Crumb was quit meanwhile), then looks for junk every 30 s.
    func start() {
        Task { await burp() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.lookForJunk()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    /// "Clean up now": ask about one file after another, ignoring the 15-minute gap, until the belly is full or
    /// nothing is left.
    func cleanUpNow() {
        if restUntil != nil { wakeUp() }
        guard !belly.isFull else {
            overlay.say("I'm stuffed! Give me a few minutes to digest.", hideAfter: .seconds(4))
            return
        }
        policy.cleaningUp = true
        Task {
            await whenIdle()
            await lookForJunk()
        }
    }

    /// Undo: put a file back on the desktop, from the belly or from the Trash. Crumb turns, coughs the file
    /// up (a picture slides out of its mouth and the real icon is moved in under it), then carries it to a slot.
    func spitOut(_ id: UUID) {
        Task { await spit(id) }
    }

    private func spit(_ id: UUID) async {
        await whenIdle()  // returns with nothing running, so the next line can't race another job
        guard let entry = belly.history.first(where: { $0.id == id }) else { return }  // already spat out
        isBusy = true
        hauler.paused = true
        defer {
            isBusy = false
            hauler.paused = napping
        }
        if napping {
            endRest()
            wake()
        }
        let name = Self.name(entry)
        let size = FinderBridge.layout().iconSize
        let picture = await IconPicture.load(URL(fileURLWithPath: entry.location), size: size)
        // Where a carried icon sits, on the side it's facing; walk(toHold:) makes this a job without walking.
        let feet = pet.gait.position
        let side: Double = pet.gait.facing < 0 ? -1 : 1
        let mouth = CGPoint(x: feet.x + Pet.hold.ahead * side, y: feet.y - Pet.hold.up)
        await pet.walk(toHold: mouth, pace: Hauler.trot)
        pet.goal = .burp
        overlay.showMeal(
            picture, at: mouth, size: size, mirrored: false,
            emerging: CGPoint(x: mouth.x - size / 2 * side, y: mouth.y))
        try? await Task.sleep(for: .seconds(0.35))
        do {
            try belly.spitOut(id)
        } catch BellyError.destinationExists(let path) {
            return failSpit("There's already a file called “\((path as NSString).lastPathComponent)” there.")
        } catch {
            return failSpit("I can't find that one any more. Was the Trash emptied?")
        }
        // Taking it back means "keep it": don't ask about this file again.
        let back = URL(fileURLWithPath: entry.originalPath)
        if let facts = await Task.detached(operation: { Scanner.facts(for: back) }).value { neverAsk.insert(Scanner.keepKey(back, facts)) }
        afterBellyChange()
        // Finder notices the file within a few tenths of a second; move the real icon in under the picture.
        let finderName = name.replacingOccurrences(of: ":", with: "/")
        for _ in 0..<20 {
            if (try? await finder.place(finderName, at: mouth)) == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        overlay.hideMeal()
        overlay.say("Here's “\(name)” back. I won't ask about it again.", hideAfter: .seconds(4))
        pet.goal = .stand
        hauler.tidy(carrying: finderName)  // starts as this job ends: picks it up where it lies
        if belly.isFull { settleDown() }
    }

    private func failSpit(_ text: String) {
        overlay.hideMeal()
        overlay.say(text, hideAfter: .seconds(4))
        pet.goHome()
        if belly.isFull { settleDown() }
    }

    static func name(_ entry: BellyEntry) -> String { (entry.originalPath as NSString).lastPathComponent }

    // MARK: - Asking

    /// Kept files, as `Scanner.keepKey`s.
    // MARK: - Settings

    func asks(about reason: JunkReason) -> Bool { !disabledRules.contains(reason.rawValue) }

    func setAsks(_ on: Bool, about reason: JunkReason) {
        if on { disabledRules.remove(reason.rawValue) } else { disabledRules.insert(reason.rawValue) }
    }

    /// Files answered Keep, and spat-out files: never asked about again until forgotten.
    var keptCount: Int { neverAsk.count }
    func forgetKept() { neverAsk = [] }

    private var neverAsk: Set<String> {
        get { Set(defaults.stringArray(forKey: "neverAsk") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "neverAsk") }
    }

    private var disabledRules: Set<String> {
        get { Set(defaults.stringArray(forKey: "disabledRules") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "disabledRules") }
    }

    private var enabledRules: Set<JunkReason> { Set(JunkReason.allCases.filter { !disabledRules.contains($0.rawValue) }) }

    private func lookForJunk() async {
        guard !isBusy, !hauler.isBusy, !hauler.isComplaining, !pet.onJob, NSEvent.pressedMouseButtons == 0,
            policy.mayAsk(now: .now, bellyFull: belly.isFull, napping: napping || restUntil != nil),
            !Self.fullScreenAppInFront()
        else { return }
        isBusy = true
        hauler.paused = true
        defer {
            isBusy = false
            hauler.paused = napping
        }
        // Off the main thread: comparing a big local copy with its original reads both files.
        let (folder, skip, rules) = (desktop, neverAsk, enabledRules)
        let found = await Task.detached { Scanner.candidates(in: folder, neverAsk: skip, enabled: rules) }.value
        guard !found.isEmpty else { return finishCleanUp() }
        guard let icons = try? await finder.icons() else {
            if policy.cleaningUp {
                overlay.say("Finder isn't answering, so I can't find the files.", hideAfter: .seconds(4))
            }
            policy.cleaningUp = false
            return
        }
        // Finder shows ":" in file names as "/". Only icons on this screen with a unique name.
        let screen = CGRect(x: 0, y: 0, width: pet.map.width, height: pet.map.height)
        let positions = Dictionary(grouping: icons, by: \.name)
            .compactMapValues { $0.count == 1 && screen.contains($0[0].position) ? $0[0].position : nil }
        let next = found.lazy.compactMap { c in
            positions[c.facts.name.replacingOccurrences(of: ":", with: "/")].map { (c, $0) }
        }.first
        guard let (candidate, position) = next else { return finishCleanUp() }
        await meal(candidate, at: position)
    }

    private func finishCleanUp() {
        guard policy.cleaningUp else { return }
        policy.cleaningUp = false
        overlay.say("All clean! Nothing left to eat.", hideAfter: .seconds(3))
    }

    private enum Answer { case yum, keep, neverAskRule, noAnswer }

    /// Walk over, sniff, ask, and act on the answer.
    private func meal(_ c: Scanner.Candidate, at p: CGPoint) async {
        policy.lastAskAt = .now
        defaults.set(Date.now.timeIntervalSince1970, forKey: "lastAskAt")
        await pet.walk(toHold: p, pace: Hauler.trot)
        await pet.perform(.sniff, for: 1.2)
        overlay.say("?")
        try? await Task.sleep(for: .seconds(0.8))
        pet.goal = .sitTilt
        switch await ask(c) {
        case .yum:
            await eat(c, at: p)
        case .keep:
            neverAsk.insert(Scanner.keepKey(c.url, c.facts))
        case .neverAskRule:
            disabledRules.insert(c.reason.rawValue)
        case .noAnswer:
            policy.cleaningUp = false  // nobody's there: don't keep asking
        }
        if !napping { pet.goHome() }
        if policy.cleaningUp {
            Task {
                await whenIdle()  // let the tidy close the gap first
                await lookForJunk()
            }
        }
    }

    private func ask(_ c: Scanner.Candidate) async -> Answer {
        let once = Once()
        let answer: Answer = await withCheckedContinuation { done in
            func reply(_ a: Answer) -> () -> Void { { if once.claim() { done.resume(returning: a) } } }
            overlay.say(
                "Eat “\(c.facts.name)”? \(c.reason.why)",
                buttons: [("Yum", reply(.yum)), ("Keep", reply(.keep)), ("Never ask about \(c.reason.plural)", reply(.neverAskRule))])
            Task {
                try? await Task.sleep(for: Self.answerTimeout)
                reply(.noAnswer)()
            }
        }
        overlay.say(nil)
        return answer
    }

    // MARK: - Eating

    private func eat(_ c: Scanner.Candidate, at p: CGPoint) async {
        guard await download(c.url) else { return await giveUp() }
        // An iCloud-only pair was matched by size alone: fetch the original too, so the re-check compares bytes.
        let original = c.reason == .duplicate ? Scanner.original(of: c.url) : nil
        if let original { guard await download(original) else { return await giveUp() } }
        let size = FinderBridge.layout().iconSize
        let picture = await IconPicture.load(c.url, size: size)  // while the file is still in place
        // The answer, download and picture may have taken a while: only eat the file that was asked about,
        // unchanged and still junk. Checked last so nothing else happens between this and the move.
        let url = c.url
        let fresh = await Task.detached { Scanner.facts(for: url) }.value
        // iCloud nudges the stored date by a fraction of a microsecond when it downloads a file; an edit moves it more.
        guard let fresh, abs(fresh.modified.timeIntervalSince(c.facts.modified)) < 0.01, fresh.size == c.facts.size else {
            return await giveUp("It changed, so I'll leave it.")
        }
        // Never eat a copy that wasn't compared byte for byte (e.g. iCloud evicted one again meanwhile).
        if let original, Scanner.isDataless(c.url) || Scanner.isDataless(original) { return await giveUp() }
        guard classify(fresh, now: .now, enabled: enabledRules) != .keep else {
            if let original { return await giveUp("It's not quite the same as “\(original.lastPathComponent)”, so I'll keep it.") }
            return await giveUp("It changed, so I'll leave it.")
        }
        overlay.showMeal(picture, at: p, size: size, mirrored: pet.gait.facing < 0)  // eat from the snout's side
        do {
            try belly.eat(c.url, cell: hauler.grid.cell(nearest: p))
        } catch {
            overlay.hideMeal()
            return await giveUp("Couldn't eat that one.")
        }
        afterBellyChange()
        // The real icon must be gone before the first hole, or the hole shows it underneath. Finder's screen can
        // lag its records (seen with files just fetched from iCloud): ask it to redraw, and give it a moment.
        await finder.refresh()
        await pet.perform(.sniff, for: 0.6)
        let bites = biteCount(bytes: c.facts.size)
        let chew = bites > 5 ? 0.4 : 0.6
        for k in 1...bites {
            await pet.perform(.bite, for: 0.3)
            overlay.biteMeal(k, of: bites)
            await pet.perform(.stand, for: chew)
        }
        overlay.hideMeal()
        hauler.tidy()  // runs once this job ends
        if belly.isFull {
            policy.cleaningUp = false
            settleDown()  // close the last gap, walk home, then sleep
        }
    }

    /// Eating didn't happen: say why (if there's anything to say), shrug, and end a Clean up so the same file
    /// isn't asked about again right away.
    private func giveUp(_ text: String? = nil) async {
        policy.cleaningUp = false
        if let text { overlay.say(text, hideAfter: .seconds(3)) }
        await pet.perform(.shrug, for: 1.2)
    }

    /// iCloud may keep only a placeholder on the Mac. Moving it into the belly downloads it and blocks until done,
    /// so fetch it first without blocking. Gives up after a minute (offline, or a huge file).
    private func download(_ url: URL) async -> Bool {
        guard Scanner.isDataless(url) else { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        overlay.say("Fetching it from iCloud…")
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(500))
            if !Scanner.isDataless(url) {
                overlay.say(nil)
                return true
            }
        }
        overlay.say("It's still downloading from iCloud. Maybe later.", hideAfter: .seconds(4))
        return false
    }

    /// Waits until no job or tidy is running.
    private func whenIdle() async {
        while isBusy || hauler.isBusy || pet.onJob {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// "Nap for 1h": once the current job is done, sleep for an hour. No asks; tidies wait; burps still happen.
    func napForAnHour() {
        restUntil = .now + 3600
        restTimer?.cancel()
        restTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3600))
            if !Task.isCancelled { self?.wakeUp() }
        }
        onChange()
        settleDown()
    }

    /// Ends a "Nap for 1h" rest. A stuffed Crumb sleeps on until a slot frees.
    func wakeUp() {
        endRest()
        if napping, !belly.isFull { wake() }
    }

    private func endRest() {
        restTimer?.cancel()
        restUntil = nil
        onChange()
    }

    /// Sleeps once nothing is running and it's back home (not mid-walk), if it still should by then:
    /// resting ("Nap for 1h") or stuffed.
    private func settleDown() {
        Task {
            while isBusy || hauler.isBusy || pet.onJob || pet.gait.isWalking {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !napping, restUntil != nil || belly.isFull else { return }
            fallAsleep()
        }
    }

    private func fallAsleep() {
        napping = true
        hauler.paused = true  // tidies wait until it wakes
        pet.digestNap(true)
        overlay.say("zzz")
    }

    private func wake() {
        napping = false
        pet.digestNap(false)
        overlay.say(nil)
        hauler.paused = isBusy
    }

    // MARK: - Digesting

    private func afterBellyChange() {
        pet.fullness = belly.digesting.count
        onChange()
        scheduleBurp()
        if napping, !belly.isFull, restUntil == nil { wake() }
    }

    private func scheduleBurp() {
        burpTimer?.cancel()
        guard let next = belly.nextBurpAt else { return }
        let at = max(next, lastBurpAttempt + Self.burpRetry)
        burpTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            burpTimer = nil  // so rescheduling inside burp() doesn't cancel this task mid-burp
            await burp()
        }
    }

    /// A full-screen app is in front: one of its normal windows covers the whole main display (Crumb's screen).
    /// Window bounds need no permission; titles would need Screen Recording and aren't read.
    static func fullScreenAppInFront() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let screen = NSScreen.screens.first?.frame.size
        else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return windows.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                let b = w[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: b as! CFDictionary)
            else { return false }
            return bounds == CGRect(origin: .zero, size: screen)
        }
    }

    private func burp() async {
        lastBurpAttempt = .now
        let result: BurpResult
        do {
            result = try belly.burp()
        } catch {
            NSLog("Crumb: burp failed: \(error)")  // the ledger couldn't be saved; files stay safe and it retries
            afterBellyChange()
            return
        }
        afterBellyChange()
        if !result.returned.isEmpty {
            let names = result.returned.map { "“\(Self.name($0))”" }.joined(separator: ", ")
            overlay.say("Couldn't digest \(names), so I put it back.", hideAfter: .seconds(5))
            hauler.tidy()
        }
        guard !result.burped.isEmpty, !isBusy, !pet.onJob, !napping else { return }
        overlay.say("*burp*", hideAfter: .seconds(1.5))
        await pet.perform(.burp, for: 1)
        if !pet.onJob { pet.goal = .stand }
    }
}

extension JunkReason {
    /// Why it looks like junk, for the Ask bubble.
    var why: String {
        switch self {
        case .screenshot: "It's an old screenshot."
        case .installer: "The app is already installed."
        case .duplicate: "It looks like an exact copy of another file."
        case .partialDownload: "It's an unfinished download."
        case .temp: "It looks like a leftover temp file."
        }
    }

    var plural: String {
        switch self {
        case .screenshot: "screenshots"
        case .installer: "installers"
        case .duplicate: "copies"
        case .partialDownload: "unfinished downloads"
        case .temp: "temp files"
        }
    }
}
