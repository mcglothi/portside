import Foundation

/// One version's entry from `CHANGELOG.md`.
struct ReleaseNote: Identifiable {
    var id: String { version }
    /// The heading text, e.g. "0.21.0".
    let version: String
    /// The prose beneath it, markdown as written.
    let body: String
}

/// Anchor for `Bundle(for:)` — the only way to ask "which bundle is this code
/// in" without depending on `Bundle.main`, which is the wrong answer in tests.
private final class BundleMarker {}

/// Reads the changelog Portside ships with, so "what changed" is answerable
/// from inside the app rather than only from a GitHub release page.
///
/// The file is a copy of the repo's `CHANGELOG.md` — the same text the release
/// script feeds to Sparkle's update dialog, so the notes you get *offered* on
/// update and the notes you can go back and *read* are one source. A test fails
/// if the two copies drift, because a stale in-app changelog is worse than none:
/// it answers the question wrongly.
enum ReleaseNotes {

    /// Every version section, newest first.
    static let all: [ReleaseNote] = parse(rawText ?? "")

    /// The section matching the running build, if there is one — nil for a dev
    /// build, which has no version to match.
    static func current(version: String? = appVersion) -> ReleaseNote? {
        guard let version else { return nil }
        return all.first { $0.version == version }
    }

    /// nil for a bare `swift run` build, which has no Info.plist to read.
    /// Reported as such rather than as "0.0.0", which looks like a real version
    /// and would quietly mismatch every changelog entry.
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// What the About window puts under the app name.
    static var versionDescription: String {
        guard let appVersion else { return "Development build" }
        guard let buildNumber else { return "Version \(appVersion)" }
        return "Version \(appVersion) (build \(buildNumber))"
    }

    /// Splits on `## ` headings. Deliberately tolerant: an unparseable or
    /// missing changelog yields an empty list and the UI says so, rather than
    /// throwing anywhere near a menu command.
    static func parse(_ text: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var version: String?
        var body: [String] = []

        func flush() {
            guard let version else { return }
            let trimmed = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            notes.append(ReleaseNote(version: version, body: trimmed))
        }

        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                flush()
                version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = []
            } else if version != nil {
                body.append(line)
            }
        }
        flush()
        return notes
    }

    /// Same bundle-location dance as `TerminalTheme.resourceBundle`, and for the
    /// same reason: SwiftPM's generated `Bundle.module` traps rather than
    /// returning nil when the bundle is missing, and looks in the wrong place
    /// for a packaged .app.
    private static var rawText: String? {
        let name = "Portside_Portside.bundle"
        let candidates = [
            Bundle.main.resourceURL,   // packaged .app: Contents/Resources
            Bundle.main.bundleURL,     // bare SPM binary: the executable's directory
            // Under xctest, Bundle.main is the *runner*, so neither of the above
            // sees the resource — which would leave the runtime path untested,
            // and it is the path that matters. The resource bundle sits beside
            // the .xctest bundle rather than inside it, so this is the enclosing
            // directory of whatever bundle this code was loaded from.
            // (TerminalTheme has the same blind spot; its fallback themes hide
            // it, which is why nothing has noticed.)
            Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent(),
        ]
        for base in candidates {
            guard let base, let bundle = Bundle(url: base.appendingPathComponent(name)),
                  let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return text
        }
        return nil
    }
}
