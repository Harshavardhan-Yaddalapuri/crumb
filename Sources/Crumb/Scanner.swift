import CoreServices
import CrumbCore
import Foundation

/// Gathers `FileFacts` for the top level of a folder (file system and Spotlight reads); `classify` decides.
enum Scanner {
    struct Candidate {
        let url: URL
        let facts: FileFacts
        let reason: JunkReason
    }

    private static let keys: [URLResourceKey] = [
        .contentModificationDateKey, .addedToDirectoryDateKey, .fileSizeKey, .isDirectoryKey, .isPackageKey,
        .tagNamesKey, .isHiddenKey,
    ]

    /// Junk in `folder`, oldest first (ties: biggest first).
    static func candidates(
        in folder: URL, neverAsk: Set<String>, enabled: Set<JunkReason>, now: Date = .now
    ) -> [Candidate] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let apps = installedApps()
        var found: [String: Candidate] = [:]
        for url in urls {
            guard var facts = facts(for: url, apps: apps) else { continue }
            facts.neverAsk = neverAsk.contains(url.path)
            if case .junk(let reason) = classify(facts, now: now, enabled: enabled) {
                found[facts.name] = Candidate(url: url, facts: facts, reason: reason)
            }
        }
        return candidateOrder(found.values.map(\.facts)).compactMap { found[$0.name] }
    }

    /// Facts for one file, or nil for hidden files. Reads only metadata, so iCloud placeholders stay in the cloud.
    static func facts(for url: URL, apps: [String]? = nil) -> FileFacts? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isHidden != true,
            !url.lastPathComponent.hasPrefix(".")
        else { return nil }
        var f = FileFacts(name: url.lastPathComponent, modified: v.contentModificationDate ?? .distantPast)
        f.dateAdded = v.addedToDirectoryDate
        f.size = Int64(v.fileSize ?? 0)
        f.tags = v.tagNames ?? []
        // Apps and other packages are folders on disk but single items to the user: never "empty folders".
        // Folders that live only in iCloud aren't listed (that would fetch them), so they count as not empty.
        f.isDirectory = v.isDirectory == true
        if f.isDirectory, v.isPackage != true, !isDataless(url) {
            let inside = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]
            f.isEmptyDirectory = inside.allSatisfy { [".DS_Store", ".localized"].contains($0) }
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            f.lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            f.isScreenCapture = (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool) ?? false
        }
        let ext = url.pathExtension.lowercased()
        if ["dmg", "pkg", "zip"].contains(ext) {
            f.containedAppInstalled = installerMatchesInstalledApp(f.name, apps: apps ?? installedApps())
        }
        // Both local: compare every byte. Either only in iCloud: same size counts for now (comparing would
        // download both on every scan); after Yum, Eater downloads both and this runs again with the real check.
        if !f.isDirectory, let other = original(of: url) {
            let otherSize = (try? other.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let local = !isDataless(url) && !isDataless(other)
            f.identicalOriginalExists = otherSize.map(Int64.init) == f.size
                && (!local || FileManager.default.contentsEqual(atPath: url.path, andPath: other.path))
        }
        return f
    }

    /// The file "Report copy.pdf" would be a duplicate of ("Report.pdf" next to it), or nil.
    static func original(of url: URL) -> URL? {
        originalName(forDuplicate: url.lastPathComponent).map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }

    /// An iCloud placeholder: the name is here, the contents are in the cloud ("Optimize Mac Storage").
    static func isDataless(_ url: URL) -> Bool {
        var s = stat()
        return stat(url.path, &s) == 0 && s.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Names (without ".app") of the apps in /Applications and ~/Applications.
    static func installedApps() -> [String] {
        let dirs = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)) }
        }
    }
}
