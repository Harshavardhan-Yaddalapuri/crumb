import Foundation

private let day: TimeInterval = 86_400

public enum JunkReason: String, CaseIterable, Codable, Sendable {
    case screenshot, installer, duplicate, partialDownload, temp

    /// How long since last use before a file of this kind counts as junk.
    public var minAge: TimeInterval {
        switch self {
        case .screenshot: 7 * day
        case .installer: 3 * day
        case .duplicate: 0
        case .partialDownload, .temp: 1 * day
        }
    }
}

public enum Verdict: Equatable, Sendable {
    case junk(JunkReason)
    case keep
}

/// Everything the rules need to know about one file. A scanner gathers these (IO); the rules stay pure.
public struct FileFacts: Sendable {
    public var name: String
    public var modified: Date
    public var lastUsed: Date? = nil
    /// When the file arrived in this folder (`kMDItemDateAdded`).
    public var dateAdded: Date? = nil
    public var size: Int64 = 0
    public var isDirectory = false
    public var isEmptyDirectory = false
    public var tags: [String] = []
    public var isScreenCapture = false
    public var neverAsk = false
    /// .dmg / .pkg / .zip only: the app inside already exists in /Applications.
    public var containedAppInstalled = false
    /// "x (1).ext" / "x copy.ext" only: a byte-identical original sits in the same folder.
    public var identicalOriginalExists = false

    public init(name: String, modified: Date) {
        self.name = name
        self.modified = modified
    }

    /// Most recent sign of life. Copies (AirDrop, unzip) can keep an old modified date, so take the latest.
    public var lastActivity: Date { [lastUsed, dateAdded].compactMap { $0 }.reduce(modified, max) }
}

/// Decide whether one file is junk. Tagged and "never ask" files are always kept.
public func classify(
    _ f: FileFacts, now: Date, enabled: Set<JunkReason> = Set(JunkReason.allCases)
) -> Verdict {
    if !f.tags.isEmpty || f.neverAsk { return .keep }
    guard let reason = reason(for: f), enabled.contains(reason) else { return .keep }
    let age = now.timeIntervalSince(f.lastActivity)
    return age >= reason.minAge ? .junk(reason) : .keep
}

private func reason(for f: FileFacts) -> JunkReason? {
    let ext = (f.name as NSString).pathExtension.lowercased()
    // Folders: only empty ones. Non-empty folders are never touched, even Safari's .download bundles.
    if f.isDirectory { return f.isEmptyDirectory ? .temp : nil }
    if ["crdownload", "part", "download"].contains(ext) { return .partialDownload }
    if f.isScreenCapture
        || f.name.range(of: #"^(Screenshot|Screen Recording) \d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    {
        return .screenshot
    }
    if ext == "tmp" || f.name.hasPrefix("~$") { return .temp }
    if ["dmg", "pkg", "zip"].contains(ext) && f.containedAppInstalled { return .installer }
    if f.identicalOriginalExists && originalName(forDuplicate: f.name) != nil { return .duplicate }
    return nil
}

/// "Report (1).pdf" / "Report copy.pdf" / "Report copy 2.pdf" → "Report.pdf". Nil if not a duplicate name.
public func originalName(forDuplicate name: String) -> String? {
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    guard let r = stem.range(of: #" (\(\d+\)|copy( \d+)?)$"#, options: .regularExpression) else { return nil }
    let base = String(stem[..<r.lowerBound])
    guard !base.isEmpty else { return nil }
    return ext.isEmpty ? base : "\(base).\(ext)"
}

/// Ask about the oldest junk first; ties go to the biggest file.
public func candidateOrder(_ files: [FileFacts]) -> [FileFacts] {
    files.sorted { a, b in
        a.lastActivity != b.lastActivity ? a.lastActivity < b.lastActivity : a.size > b.size
    }
}

// ponytail: matches by name only ("Figma-124.5-arm64.dmg" ↔ "Figma.app"); looking inside the .dmg/.zip would
// need mounting or unpacking it. Every match still goes through an Ask, so a false match only costs a question.
/// Whether an installer's name starts with the name of an app in `apps` (names of installed `.app` bundles,
/// without the extension). Compares letters and digits only, ignoring case; app names under 4 characters must
/// match the installer's whole name so "Arc" doesn't match "archive.zip".
/// For .zip, the rest of the name must start with a digit (a version), so "Figma export.zip" isn't an installer.
public func installerMatchesInstalledApp(_ installer: String, apps: [String]) -> Bool {
    func key(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
    let stem = key((installer as NSString).deletingPathExtension)
    let isZip = (installer as NSString).pathExtension.lowercased() == "zip"
    guard !stem.isEmpty else { return false }
    return apps.map(key).contains { app in
        guard !app.isEmpty else { return false }
        if app == stem { return true }
        guard app.count >= 4, stem.hasPrefix(app) else { return false }
        // A .zip is often the user's own archive ("Slack export.zip"): only a version number may follow the name.
        return !isZip || stem.dropFirst(app.count).first?.isNumber == true
    }
}
