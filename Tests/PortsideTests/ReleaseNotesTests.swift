import XCTest
@testable import Portside

/// The changelog Portside ships with.
final class ReleaseNotesTests: XCTestCase {

    /// The bundled copy has to match the repo's. A changelog that has drifted is
    /// worse than none at all: it answers "what changed" confidently and wrongly.
    ///
    /// The two files exist separately because SwiftPM will only bundle resources
    /// from inside the target directory, and `CHANGELOG.md` has to stay at the
    /// repo root — GitHub reads it there, and `release.sh` extracts the release
    /// notes from it.
    func testTheBundledChangelogMatchesTheRepoOne() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PortsideTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let canonical = root.appendingPathComponent("CHANGELOG.md")
        let bundled = root.appendingPathComponent("Sources/Portside/Resources/CHANGELOG.md")

        let a = try String(contentsOf: canonical, encoding: .utf8)
        let b = try String(contentsOf: bundled, encoding: .utf8)

        XCTAssertEqual(a, b, """
            Sources/Portside/Resources/CHANGELOG.md is out of date. \
            Copy CHANGELOG.md over it.
            """)
    }

    // MARK: - Parsing

    func testSplitsOnVersionHeadings() {
        let notes = ReleaseNotes.parse("""
        # Changelog

        Preamble that belongs to no version.

        ## 0.2.0

        Second thing.

        ## 0.1.0

        First thing.
        """)

        XCTAssertEqual(notes.map(\.version), ["0.2.0", "0.1.0"])
        XCTAssertEqual(notes.first?.body, "Second thing.")
    }

    /// The preamble sits above the first heading and belongs to no release.
    func testTextBeforeTheFirstHeadingIsDropped() {
        let notes = ReleaseNotes.parse("# Changelog\n\nNot a release.\n\n## 1.0.0\n\nIs one.")
        XCTAssertEqual(notes.count, 1)
        XCTAssertFalse(notes[0].body.contains("Not a release"))
    }

    /// `###` subheadings inside an entry must not start a new release.
    func testDeeperHeadingsStayInsideTheirEntry() {
        let notes = ReleaseNotes.parse("## 1.0.0\n\nLead.\n\n### Details\n\nMore.")
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].body.contains("### Details"))
    }

    func testAnEmptyChangelogParsesToNothingRatherThanFailing() {
        XCTAssertTrue(ReleaseNotes.parse("").isEmpty)
        XCTAssertTrue(ReleaseNotes.parse("# Changelog\n\nnothing yet\n").isEmpty)
    }

    // MARK: - What the app actually shows

    /// If this fails the About window says "not available", which is the honest
    /// fallback but not the intended state.
    func testTheChangelogIsReadableFromTheBundleAtRuntime() {
        XCTAssertFalse(ReleaseNotes.all.isEmpty,
                       "the bundled changelog should be readable in tests as in the app")
    }

    /// A dev build has no Info.plist, and showing "0.0.0" there would look like
    /// a real version that happens to match no entry.
    func testADevelopmentBuildSaysSoRatherThanInventingAVersion() {
        if ReleaseNotes.appVersion == nil {
            XCTAssertEqual(ReleaseNotes.versionDescription, "Development build")
        } else {
            XCTAssertTrue(ReleaseNotes.versionDescription.hasPrefix("Version "))
        }
    }

    func testEntriesAreNewestFirst() throws {
        let versions = ReleaseNotes.all.map(\.version)
        let first = try XCTUnwrap(versions.first)
        XCTAssertEqual(first, versions.max(by: compareVersions),
                       "About lists newest first, so the newest entry must be at the top")
    }

    private func compareVersions(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}
