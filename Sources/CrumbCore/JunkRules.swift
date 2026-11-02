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
}

/// Decide whether one file is junk. Tagged and "never ask" files are always kept.
public func classify(
    _ f: FileFacts, now: Date, enabled: Set<JunkReason> = Set(JunkReason.allCases)
) -> Verdict {
    if !f.tags.isEmpty || f.neverAsk { return .keep }
    guard let reason = reason(for: f), enabled.contains(reason) else { return .keep }
    let age = now.timeIntervalSince(f.lastUsed ?? f.modified)
    return age >= reason.minAge ? .junk(reason) : .keep
}

private func reason(for f: FileFacts) -> JunkReason? {
    let ext = (f.name as NSString).pathExtension.lowercased()
    // Before the folder check: Safari's .download is a folder bundle.
    if ["crdownload", "part", "download"].contains(ext) { return .partialDownload }
    if f.isDirectory { return f.isEmptyDirectory ? .temp : nil }
    if f.isScreenCapture || f.name.hasPrefix("Screenshot") || f.name.hasPrefix("Screen Recording") {
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
        let ad = a.lastUsed ?? a.modified, bd = b.lastUsed ?? b.modified
        return ad != bd ? ad < bd : a.size > b.size
    }
}
