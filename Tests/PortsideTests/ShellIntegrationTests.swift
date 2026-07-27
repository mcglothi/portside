import Foundation
import XCTest
@testable import Portside

/// The snippet is appended to someone else's `.bashrc` on a server we cannot
/// see, so its structural properties are worth pinning.
///
/// v2 shipped without an interactive guard. `bash` reads `~/.bashrc` for
/// non-interactive remote shells too, and the `DEBUG` trap fired there as well —
/// one OSC 133 burst straight into whatever binary protocol owned the channel.
/// `sftp` reported it as:
///
///     Received message too long 459092275
///
/// 459092275 is 0x1B5D3133, which is the escape's own first four bytes:
/// `ESC ] 1 3`. Reported from a real server by Tim, 2026-07-27.
final class ShellIntegrationTests: XCTestCase {

    /// The number in the error, decoded — the thing that identified the bug.
    func testTheReportedLengthDecodesToTheEscapeItself() {
        let reported: UInt32 = 459_092_275
        let bytes = withUnsafeBytes(of: reported.bigEndian) { Array($0) }
        XCTAssertEqual(bytes, [0x1B, 0x5D, 0x31, 0x33])
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "\u{1b}]13")
    }

    func testBothSnippetsGuardOnInteractiveShells() {
        for snippet in ShellIntegrationSnippet.allCases {
            XCTAssertTrue(
                snippet.text.contains(#"case "$-" in"#),
                "\(snippet.label) must not run in non-interactive shells"
            )
        }
    }

    /// The trap is the specific thing that leaked. It has to sit inside the
    /// guard, which for the shipped text means indented — a trap at column zero
    /// is the v2 shape that broke sftp.
    func testBashTrapIsNotAtColumnZero() {
        let lines = ShellIntegrationSnippet.bash.text.split(separator: "\n", omittingEmptySubsequences: false)
        let trapLines = lines.filter { $0.contains("trap '__portside_preexec' DEBUG") }

        XCTAssertEqual(trapLines.count, 1)
        XCTAssertTrue(
            trapLines[0].hasPrefix(" "),
            "an unindented trap is outside the interactive guard: \(trapLines[0])"
        )
    }

    func testVersionMarkerMatchesWhatTheInstallerGrepsFor() {
        for snippet in ShellIntegrationSnippet.allCases {
            XCTAssertTrue(
                snippet.text.contains("__portside_integration_v3"),
                "\(snippet.label) marker must be the version the installer looks for"
            )
            XCTAssertFalse(
                snippet.text.contains("__portside_integration_v2"),
                "a stale marker would make an affected host look already-installed"
            )
        }
    }

    /// Appending v3 cannot fix an affected host on its own: v2's trap is armed
    /// before the appended block runs its first command. The install has to
    /// disarm the old line, so the repair must actually be part of it.
    func testBashInstallRepairsAnOlderBlock() {
        let repair = ShellIntegrationSnippet.bash.repairCommand

        XCTAssertTrue(repair.contains(#"^trap '__portside_preexec' DEBUG$"#),
                      "the match must be anchored, so it hits v2's line and not v3's indented one")
        XCTAssertTrue(repair.contains("portside-backup"), "someone's rc file gets a backup first")
        XCTAssertTrue(repair.contains(#"cat "$f.portside-tmp" > "$f""#),
                      "rewrite through cat, not mv, so inode and permissions survive")
    }

    /// zsh never had the defect — it reads `.zshenv` rather than `.zshrc` for
    /// non-interactive shells, and never set a DEBUG trap — so it must not
    /// perform surgery on anyone's file.
    func testZshDoesNotEditTheFile() {
        let repair = ShellIntegrationSnippet.zsh.repairCommand
        XCTAssertFalse(repair.contains("sed"))
        XCTAssertTrue(repair.hasPrefix("#"), "should be an inert comment, got: \(repair)")
    }
}
