import Foundation
import XCTest
@testable import Portside

/// Drives `ShellIntegrationInjection.command` into a **real remote shell** over
/// a real pty, and reads back what the host actually emits.
///
/// Everything else covering the injection asserts on the *string* — that the
/// payload still matches the snippet, that the quoting holds, that the line is
/// one line. None of that can tell you whether a remote shell, reached over
/// ssh, on a tty it did not create, evaluates it and starts reporting. The
/// feature shipped at 0.23.0 verified only against a local pty running bash and
/// zsh, which is a different thing in three ways that matter: the line crosses
/// a network and an ssh channel, the pty belongs to the *host's* line discipline
/// rather than Darwin's, and the shell is the one that host actually has.
///
/// **Opt-in.** Skipped unless `PORTSIDE_ITEST_HOSTS` names hosts. It changes
/// nothing on them — every shell is started with its rc files disabled and dies
/// with the test.
///
/// ```sh
/// PORTSIDE_ITEST_HOSTS=turing,hopper swift test --filter ShellIntegrationRemote
/// ```
///
/// Starting the remote shell with `--noprofile --norc` / `-f` is not tidiness.
/// A host that already has the snippet in its `.bashrc` would report correctly
/// no matter what we typed, and the test would pass while proving nothing. The
/// control assertion below — a `cd` before injection emitting no OSC 7 — is what
/// makes the rest of it evidence.
final class ShellIntegrationRemoteTests: XCTestCase {

    private var hosts: [String] = []

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["PORTSIDE_ITEST_HOSTS"], !list.isEmpty else {
            throw XCTSkip("set PORTSIDE_ITEST_HOSTS to run integration tests")
        }
        hosts = list.split(separator: ",").map(String.init)
    }

    // MARK: - Shells to try

    /// bash and zsh, minus whichever the host doesn't have. A missing shell is
    /// skipped rather than failed — the fleet is not obliged to run both.
    private func shells(on host: String) throws -> [RemoteShellUnderTest] {
        let found = try run("/usr/bin/ssh",
                            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                             "command -v bash; command -v zsh"])
        return RemoteShellUnderTest.all.filter { found.contains("/\($0.name)") }
    }

    // MARK: - The directory report

    /// **The claim the feature makes:** type one line into a live session and
    /// the SFTP pane can follow `cd` from then on, without anything being
    /// written to the host.
    func testInjectionMakesARealRemoteShellReportItsDirectory() throws {
        for host in hosts {
            let available = try shells(on: host)
            XCTAssertFalse(available.isEmpty, "\(host): neither bash nor zsh found")

            for shell in available {
                let session = try RemoteShell(host: host, launch: shell.launchCommand)
                defer { session.close() }
                let label = "\(host)/\(shell.name)"

                XCTAssertTrue(session.waitForPrompt(), "\(label): shell never came up")

                // Control. Without the injection a `cd` must be silent — if it
                // isn't, the host is reporting for some other reason and every
                // assertion below is measuring that instead.
                session.clear()
                try session.send("cd /usr")
                _ = session.wait(seconds: 3) { _ in false }
                XCTAssertFalse(session.text.contains(Self.osc7),
                               "\(label): OSC 7 before injection — the shell's rc files are "
                               + "not disabled, so this test proves nothing")

                session.clear()
                try session.send(ShellIntegrationInjection.command)
                XCTAssertTrue(session.wait { $0.contains(Self.osc7) },
                              "\(label): no directory report after injecting "
                              + "\(ShellIntegrationInjection.commandByteCount) bytes")

                // A truncated or mangled line is the failure worth naming, so
                // check the shell didn't complain rather than only that it did
                // something.
                for complaint in ["command not found", "syntax error", "unexpected end of file"] {
                    XCTAssertFalse(session.text.lowercased().contains(complaint),
                                   "\(label): shell rejected the injected line — \(complaint)")
                }

                // The report has to follow `cd`, not merely happen once.
                session.clear()
                try session.send("cd /usr/share")
                XCTAssertTrue(session.wait { $0.contains("/usr/share\u{1B}\\") },
                              "\(label): directory report did not follow cd — "
                              + "saw \(Self.reports(in: session.text))")
            }
        }
    }

    /// The path is only half of OSC 7. The authority is what tells a client the
    /// directory belongs to *that host* rather than to this Mac, and Portside
    /// opens the SFTP pane on the strength of it.
    func testTheDirectoryReportNamesTheRemoteHostNotThisMac() throws {
        let localHostName = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")

        for host in hosts {
            for shell in try shells(on: host) {
                let session = try RemoteShell(host: host, launch: shell.launchCommand)
                defer { session.close() }
                let label = "\(host)/\(shell.name)"

                XCTAssertTrue(session.waitForPrompt(), "\(label): shell never came up")
                session.clear()
                try session.send(ShellIntegrationInjection.command)
                XCTAssertTrue(session.wait { $0.contains(Self.osc7) }, "\(label): no report")

                let authorities = Self.reports(in: session.text).map {
                    $0.replacingOccurrences(of: Self.osc7, with: "")
                      .split(separator: "/").first.map(String.init) ?? ""
                }
                XCTAssertFalse(authorities.isEmpty, "\(label): no authority in the report")
                for authority in authorities {
                    XCTAssertFalse(authority.isEmpty,
                                   "\(label): empty authority — `hostname` produced nothing")
                    XCTAssertNotEqual(authority.lowercased(), localHostName.lowercased(),
                                      "\(label): the report names this Mac, not the host")
                }
            }
        }
    }

    // MARK: - Command boundaries

    /// OSC 133 is the other half of the snippet, and the half Portside times
    /// commands with. The exit status is the part worth proving over a real
    /// link: it is read from `$?` in a precmd, which is the easiest thing in the
    /// whole snippet to clobber by accident.
    func testInjectionReportsCommandBoundariesAndExitStatus() throws {
        for host in hosts {
            for shell in try shells(on: host) {
                let session = try RemoteShell(host: host, launch: shell.launchCommand)
                defer { session.close() }
                let label = "\(host)/\(shell.name)"

                XCTAssertTrue(session.waitForPrompt(), "\(label): shell never came up")
                session.clear()
                try session.send(ShellIntegrationInjection.command)
                XCTAssertTrue(session.wait { $0.contains("\u{1B}]133;A") },
                              "\(label): no prompt mark after injection")

                session.clear()
                try session.send("true")
                XCTAssertTrue(session.wait { $0.contains("\u{1B}]133;C") },
                              "\(label): no command-start mark")
                XCTAssertTrue(session.wait { $0.contains("\u{1B}]133;D;0") },
                              "\(label): success not reported as exit 0")

                session.clear()
                try session.send("false")
                XCTAssertTrue(session.wait { $0.contains("\u{1B}]133;D;1") },
                              "\(label): failure not reported as exit 1")
            }
        }
    }

    // MARK: - Helpers

    private static let osc7 = "\u{1B}]7;file://"

    /// Every OSC 7 report in the stream, terminator stripped. Used in failure
    /// messages so a mismatch says what the host *did* report.
    private static func reports(in text: String) -> [String] {
        text.components(separatedBy: osc7).dropFirst().compactMap {
            guard let end = $0.range(of: "\u{1B}\\") else { return nil }
            return osc7 + $0[$0.startIndex..<end.lowerBound]
        }
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Which shell to ask the host for, and how to start it with nothing of its own
/// loaded.
private struct RemoteShellUnderTest {
    let name: String
    let launchCommand: String

    static let all = [
        RemoteShellUnderTest(name: "bash", launchCommand: "exec bash --noprofile --norc -i"),
        RemoteShellUnderTest(name: "zsh", launchCommand: "exec zsh -f -i"),
    ]
}

/// An interactive remote shell on a pty, with its output drained continuously.
///
/// **The draining is the design.** A pty deadlocks if you push a long line into
/// it without reading the echo back: the output buffer fills, the shell blocks
/// writing its echo, and having blocked it stops reading input — so a 2.3 KB
/// line appears to prove a size limit that does not exist. Portside is never
/// exposed to this because SwiftTerm reads continuously; a harness that wants to
/// measure the same thing has to do the same, which is why the read handler is
/// installed before the process starts rather than after the write.
private final class RemoteShell {

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()

    init(host: String, launch: String) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-tt",                                  // force a pty even without a local one
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            host, launch,
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.buffer.append(data)
            self.lock.unlock()
        }
        try process.run()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Polls until the accumulated output satisfies `condition`. Returns false
    /// on timeout rather than throwing, so the caller's assertion is the one
    /// that reports, with its own message.
    @discardableResult
    func wait(seconds: TimeInterval = 15, until condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(text) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition(text)
    }

    /// Waits for the shell to be ready to read a command.
    ///
    /// The marker is split so that the *echo* of this line cannot satisfy it —
    /// the shell sees `PORTSIDE"_READY"` and prints `PORTSIDE_READY`, so a match
    /// on the joined form is the shell having actually run something.
    func waitForPrompt() -> Bool {
        guard (try? send("echo PORTSIDE\"_READY\"")) != nil else { return false }
        return wait(seconds: 20) { $0.contains("PORTSIDE_READY") }
    }

    func close() {
        try? input.fileHandleForWriting.write(contentsOf: Data("exit\n".utf8))
        _ = wait(seconds: 3) { [weak self] _ in self?.process.isRunning == false }
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
    }
}
