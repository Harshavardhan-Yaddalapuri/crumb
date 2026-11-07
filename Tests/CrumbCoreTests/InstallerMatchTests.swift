import Testing
@testable import CrumbCore

@Test func installerMatch() {
    let apps = ["Figma", "Google Chrome", "zoom.us", "Arc", "Visual Studio Code"]
    let table: [(String, Bool, String)] = [
        ("Figma.dmg", true, "exact name"),
        ("Figma-124.5-arm64.dmg", true, "version and arch suffix"),
        ("googlechrome.dmg", true, "spaces and case ignored"),
        ("GoogleChrome_universal.pkg", true, "underscore suffix"),
        ("zoomusInstallerFull.pkg", true, "dots ignored"),
        ("Figma-124.5.zip", true, "zip with a version number"),
        ("Figma export.zip", false, "zip that's the user's own archive"),
        ("Arc.dmg", true, "short app name, whole-name match"),
        ("archive.zip", false, "short app name doesn't prefix-match"),
        ("VSCode-darwin-universal.zip", false, "abbreviation isn't recognised"),
        ("Slack.dmg", false, "app not installed"),
        (".dmg", false, "no name"),
    ]
    for (name, expected, what) in table {
        #expect(installerMatchesInstalledApp(name, apps: apps) == expected, "\(what)")
    }
}
