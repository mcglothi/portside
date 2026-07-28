import Foundation
import XCTest
@testable import Portside

final class MoshArgsTests: XCTestCase {
    func testPlainHost() {
        var entry = SessionEntry(name: "web")
        entry.hostname = "web-01.example.internal"
        entry.user = "deploy"
        entry.preferMosh = true
        XCTAssertEqual(entry.moshArgs, ["deploy@web-01.example.internal"])
    }

    func testPortAndIdentityRideInsideSshOption() {
        var entry = SessionEntry(name: "web")
        entry.hostname = "web-01.example.internal"
        entry.user = "deploy"
        entry.port = 2222
        entry.identityFile = "~/.ssh/id_ed25519"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(entry.moshArgs, [
            "--ssh=ssh -i \(home)/.ssh/id_ed25519 -p 2222",
            "deploy@web-01.example.internal",
        ])
    }

    /// An apostrophe in an imported identity path used to break out of the
    /// hand-written single quotes and let mosh's `--ssh` word-splitting see
    /// extra tokens — reproduced upstream as injected `-oProxyCommand=...`.
    func testIdentityPathWithApostropheCannotInjectSshOptions() {
        var entry = SessionEntry(name: "web")
        entry.hostname = "web-01.example.internal"
        let hostilePath = "/tmp/evil' -oProxyCommand='touch /tmp/pwned"
        entry.identityFile = hostilePath
        let ssh = entry.moshArgs.first { $0.hasPrefix("--ssh=") } ?? ""
        // The quoted value must round-trip through a real shell-word split as
        // a *single* argument identical to the original path — not fan out
        // into extra words like a standalone `-oProxyCommand=...`.
        let value = String(ssh.dropFirst("--ssh=".count))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "for a in \(value); do printf '%s\\n' \"$a\"; done"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        let words = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(words, ["ssh", "-i", hostilePath],
                       "identity path did not survive as one shell word:\n\(output)")
    }

    func testAliasResolvesThroughSshConfig() {
        var entry = SessionEntry(name: "bastion")
        entry.sshAlias = "bastion"
        entry.port = 2222   // alias path defers the port to ~/.ssh/config, like sshArgs
        XCTAssertEqual(entry.moshArgs, ["bastion"])
    }

    func testMoshDisablesFileBrowser() {
        var entry = SessionEntry(name: "web")
        entry.hostname = "web-01.example.internal"
        XCTAssertTrue(entry.supportsFileBrowser)
        entry.preferMosh = true
        XCTAssertFalse(entry.supportsFileBrowser)
    }

    func testDecodingOldLibraryWithoutPreferMoshKey() throws {
        let old = #"{"name": "legacy", "hostname": "10.0.0.5"}"#
        let entry = try JSONDecoder().decode(SessionEntry.self, from: Data(old.utf8))
        XCTAssertFalse(entry.preferMosh)
    }

    func testPreferMoshRoundTrips() throws {
        var entry = SessionEntry(name: "web")
        entry.preferMosh = true
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(SessionEntry.self, from: data)
        XCTAssertTrue(decoded.preferMosh)
    }
}
