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
    /// Stuffed and asleep until a slot frees.
    private(set) var napping = false
    /// Called when the belly changes, so the menu can follow.
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

    /// Undo: put a file back on the desktop, from the belly or from the Trash.
    func spitOut(_ id: UUID) {
        guard !isBusy else { return }
        do {
            let entry = try belly.spitOut(id)
            neverAsk.insert(entry.originalPath)  // taking it back means "keep it": don't ask about it again
            afterBellyChange()
            overlay.say("Here's “\(Self.name(entry))” back.", hideAfter: .seconds(3))
            if !pet.onJob, !napping {
                Task {
                    await pet.perform(.burp, for: 0.8)
                    if !pet.onJob { pet.goal = .stand }
                }
            }
            hauler.tidy()
        } catch BellyError.destinationExists(let path) {
            overlay.say(
                "There's already a file called “\((path as NSString).lastPathComponent)” there.", hideAfter: .seconds(4))
        } catch {
            overlay.say("I can't find that one any more. Was the Trash emptied?", hideAfter: .seconds(4))
        }
    }

    static func name(_ entry: BellyEntry) -> String { (entry.originalPath as NSString).lastPathComponent }

    // MARK: - Asking

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
            policy.mayAsk(now: .now, bellyFull: belly.isFull, napping: napping)
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
            neverAsk.insert(c.url.path)
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
        let size = FinderBridge.layout().iconSize
        let picture = await IconPicture.load(c.url, size: size)  // while the file is still in place
        // The answer, download and picture may have taken a while: only eat the file that was asked about,
        // unchanged and still junk. Checked last so nothing else happens between this and the move.
        let url = c.url
        let fresh = await Task.detached { Scanner.facts(for: url) }.value
        guard let fresh, fresh.modified == c.facts.modified, fresh.size == c.facts.size,
            classify(fresh, now: .now, enabled: enabledRules) != .keep
        else { return await giveUp("It changed, so I'll leave it.") }
        overlay.showMeal(picture, at: p, size: size, mirrored: pet.gait.facing < 0)  // eat from the snout's side
        do {
            try belly.eat(c.url, cell: hauler.grid.cell(nearest: p))
        } catch {
            overlay.hideMeal()
            return await giveUp("Couldn't eat that one.")
        }
        afterBellyChange()
        let bites = biteCount(bytes: c.facts.size)
        let beat = bites > 5 ? 0.35 : 0.5
        for k in 1...bites {
            await pet.perform(.bite, for: beat / 2)
            overlay.biteMeal(k, of: bites)
            await pet.perform(.stand, for: beat / 2)
        }
        overlay.hideMeal()
        hauler.tidy()  // runs once this job ends
        if belly.isFull {
            policy.cleaningUp = false
            Task {
                await whenIdle()  // close the last gap, then sleep
                startNap()
            }
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

    private func startNap() {
        guard belly.isFull, !napping else { return }
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
        if napping, !belly.isFull { wake() }
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
        case .duplicate: "It's an exact copy of another file."
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
