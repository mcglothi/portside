import Foundation
import XCTest
@testable import Portside

/// Adversarial coverage for the destructive half of rotation.
final class KeyRotatorRetirementSafetyTests: XCTestCase {

    private var home: URL!
    private var bin: URL!

    private let oldKey = PublicKey(
        path: "/tmp/old.pub", line: "ssh-rsa AAAAOLD tim@old",
        algorithm: "ssh-rsa", blob: "AAAAOLD", comment: "tim@old",
        fingerprint: "SHA256:old", bits: 4096)
    private let newKey = PublicKey(
        path: "/tmp/new.pub", line: "ssh-ed25519 AAAANEW tim@new",
        algorithm: "ssh-ed25519", blob: "AAAANEW", comment: "tim@new",
        fingerprint: "SHA256:new", bits: 256)
    private let nonce = "safety-nonce"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-retire-safety-\(UUID().uuidString)")
        bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var authorizedKeys: URL {
        home.appendingPathComponent(".ssh/authorized_keys")
    }

    private var backup: URL {
        home.appendingPathComponent(
            ".ssh/authorized_keys\(KeyDistributor.backupSuffix)")
    }

    private var temp: URL {
        home.appendingPathComponent(".ssh/authorized_keys.portside-rewrite")
    }

    private func seed(_ contents: String) throws {
        try contents.write(to: authorizedKeys, atomically: true, encoding: .utf8)
    }

    private struct Run {
        let status: Int32
        let out: String
        let err: String
        var outcome: KeyRetireOutcome
    }

    private func run(path: String = "/usr/bin:/bin") throws -> Run {
        let script = home.appendingPathComponent("retire.sh")
        try KeyRotator.retireScript(
            removing: oldKey, keeping: newKey, nonce: nonce
        ).write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["HOME": home.path, "PATH": path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(
            decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(
            decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Run(
            status: process.terminationStatus, out: output, err: errors,
            outcome: KeyRotator.retireOutcome(
                status: process.terminationStatus, out: output, err: errors, nonce: nonce))
    }

    private func installCatStub(_ body: String) throws {
        let stub = bin.appendingPathComponent("cat")
        try ("#!/bin/sh\n" + body + "\n").write(
            to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    // MARK: - One parser decides install, count, and removal

    func testNewKeyNamedInsideAnotherKeysCommentDoesNotSatisfyGuard() throws {
        let original = """
        \(oldKey.line)
        ssh-rsa AAAAOTHER note \(newKey.algorithm) \(newKey.blob)
        """ + "\n"
        try seed(original)

        guard case .refused = try run().outcome else {
            return XCTFail("a comment reference satisfied the new-key guard")
        }
        XCTAssertEqual(try String(contentsOf: authorizedKeys), original)
    }

    func testNewKeyNamedInsideAQuotedOptionDoesNotSatisfyGuard() throws {
        let original = """
        \(oldKey.line)
        command="echo \(newKey.algorithm) \(newKey.blob)",no-pty ssh-rsa AAAAOTHER real
        """ + "\n"
        try seed(original)

        guard case .refused = try run().outcome else {
            return XCTFail("an option reference satisfied the new-key guard")
        }
        XCTAssertEqual(try String(contentsOf: authorizedKeys), original)
    }

    func testOldKeyNamedInsideAnotherKeysCommentSurvives() throws {
        let reference = "ssh-ed25519 AAAAOTHER note \(oldKey.algorithm) \(oldKey.blob)"
        try seed("\(oldKey.line)\n\(newKey.line)\n\(reference)\n")

        XCTAssertEqual(try run().outcome, .removed(1))
        XCTAssertTrue(try String(contentsOf: authorizedKeys).contains(reference))
    }

    func testOldKeyNamedInsideAQuotedOptionSurvives() throws {
        let reference =
            "command=\"echo \(oldKey.algorithm) \(oldKey.blob)\",no-pty ssh-ed25519 AAAAOTHER real"
        try seed("\(oldKey.line)\n\(newKey.line)\n\(reference)\n")

        XCTAssertEqual(try run().outcome, .removed(1))
        XCTAssertTrue(try String(contentsOf: authorizedKeys).contains(reference))
    }

    // MARK: - The truncate-and-copy interval is transactional

    func testTermDuringRewriteRestoresOriginalAndRemovesTemporaryFile() throws {
        let original = "\(oldKey.line)\n\(newKey.line)\n"
        try seed(original)
        try installCatStub("""
        case "$1" in
          *.portside-rewrite)
            printf 'partial\n'
            kill -TERM "$PPID"
            exit 1
            ;;
          *) exec /bin/cat "$@" ;;
        esac
        """)

        let result = try run(path: "\(bin.path):/usr/bin:/bin")

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertTrue(result.err.contains("restored from the backup"), result.err)
        XCTAssertEqual(try String(contentsOf: authorizedKeys), original)
        XCTAssertEqual(try String(contentsOf: backup), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    func testRestoreFailureIsReportedHonestlyAndLeavesBackupForRecovery() throws {
        let original = "\(oldKey.line)\n\(newKey.line)\n"
        try seed(original)
        try installCatStub("""
        case "$1" in
          *.portside-rewrite)
            printf 'partial\n'
            kill -TERM "$PPID"
            exit 1
            ;;
          *.portside-backup) exit 1 ;;
          *) exec /bin/cat "$@" ;;
        esac
        """)

        let result = try run(path: "\(bin.path):/usr/bin:/bin")

        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertTrue(result.err.contains("restore FAILED"), result.err)
        XCTAssertTrue(result.err.contains("recover"), result.err)
        XCTAssertNotEqual(try String(contentsOf: authorizedKeys), original)
        XCTAssertEqual(try String(contentsOf: backup), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    // MARK: - Stop is a boundary between hosts

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var started = false

        func block() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testCancellationFinishesCurrentHostThenSkipsTheNext() async {
        let gate = Gate()
        let entries = [
            SessionEntry(name: "first", hostname: "first.example"),
            SessionEntry(name: "second", hostname: "second.example")
        ]
        let runner: KeyDistributor.Runner = { _, _, _, _ in
            await gate.block()
            return (status: 1, out: "", err: "first host completed")
        }

        let operation = Task {
            await KeyRotator.retire(
                oldKey: oldKey, keeping: newKey, on: entries,
                password: { _ in nil }, runner: runner,
                progress: { _ in })
        }

        await gate.waitUntilStarted()
        operation.cancel()
        await gate.release()
        let results = await operation.value

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].outcome, .failed("first host completed"))
        XCTAssertEqual(results[1].outcome, .skipped("cancelled"))
    }
}

/// The keep-key guard must prove the new key **grants access**, not merely that
/// its fields appear somewhere in a line.
///
/// Found by Codex reading the branch as one feature, and reproduced against a
/// fixture host running OpenSSH 9.2p1: prefixing a working `authorized_keys`
/// line with `portside-unknown-option` makes sshd deny the login outright,
/// because it refuses a line carrying an option it does not recognise. Portside's
/// field locator happily skipped the token and found the key behind it, so both
/// the pre-rewrite and post-rewrite guards passed for a line that authenticates
/// nothing — and those guards are what permit deleting the old key.
final class KeepKeyGuardTests: XCTestCase {

    private let key = PublicKey(
        path: "/n.pub", line: "ssh-ed25519 AAAAKEEPTHIS tim@newton",
        algorithm: "ssh-ed25519", blob: "AAAAKEEPTHIS", comment: "tim@newton",
        fingerprint: "SHA256:k", bits: 256)

    private func matchesBareEntry(_ contents: String) throws -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keys = dir.appendingPathComponent("authorized_keys")
        try contents.write(to: keys, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("g.sh")
        try("f=\(ShellQuoting.quote(keys.path))\n"
            + "if \(KeyDistributor.bareEntryCheck(for: key)); then exit 0; else exit 1; fi\n")
            .write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// The shape Portside installs, and the only shape it will retire against.
    func testABareEntryMatches() throws {
        XCTAssertTrue(try matchesBareEntry("\(key.line)\n"))
        XCTAssertTrue(try matchesBareEntry("ssh-ed25519 AAAAKEEPTHIS\n"), "a comment is optional")
        XCTAssertTrue(try matchesBareEntry("  \(key.line)\r\n"), "leading space and CRLF are not options")
    }

    /// **The reproduction.** sshd denies this line; the guard must too.
    func testAnUnknownOptionDoesNotMatch() throws {
        XCTAssertFalse(try matchesBareEntry("portside-unknown-option \(key.line)\n"),
                       "sshd refuses a line with an unrecognised option; so must the guard")
    }

    /// A *valid* option may still not authorize this connection — an expiry in
    /// the past, a `from=` that excludes you. Portside cannot evaluate those
    /// from here, so it fails closed rather than guessing.
    func testAValidButUnevaluatableOptionDoesNotMatch() throws {
        for line in ["expiry-time=\"19990101\" \(key.line)",
                     "from=\"10.0.0.0/8\" \(key.line)",
                     "command=\"/usr/bin/true\",no-pty \(key.line)",
                     "restrict \(key.line)"] {
            XCTAssertFalse(try matchesBareEntry(line + "\n"),
                           "must not treat a constrained entry as an unconditional grant: \(line)")
        }
    }

    func testACommentedOutEntryDoesNotMatch() throws {
        XCTAssertFalse(try matchesBareEntry("# \(key.line)\n"))
    }

    func testADifferentKeyDoesNotMatch() throws {
        XCTAssertFalse(try matchesBareEntry("ssh-ed25519 AAAASOMETHINGELSE other@host\n"))
        XCTAssertFalse(try matchesBareEntry("ssh-rsa AAAAKEEPTHIS other@host\n"), "wrong type")
    }

    /// **Pins the wiring, not just the helper.** Reverting `retireScript` to the
    /// field locator left every other test in this file green, because they all
    /// call `bareEntryCheck` directly. This one runs the real script.
    func testTheRetireScriptItselfRefusesAnOptionGuardedKeepKey() throws {
        let old = PublicKey(path: "/o.pub", line: "ssh-rsa AAAAOLDVICTIM old@host",
                            algorithm: "ssh-rsa", blob: "AAAAOLDVICTIM",
                            comment: "old@host", fingerprint: "f2", bits: 2048)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-wiring-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let keys = ssh.appendingPathComponent("authorized_keys")
        // The old key, and the keep-key sitting behind an option sshd refuses.
        try "\(old.line)\nportside-unknown-option \(key.line)\n"
            .write(to: keys, atomically: true, encoding: .utf8)
        let before = try String(contentsOf: keys, encoding: .utf8)

        let script = home.appendingPathComponent("retire.sh")
        try KeyRotator.retireScript(removing: old, keeping: key, nonce: "wire1")
            .write(to: script, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let err = Pipe()
        p.standardOutput = Pipe(); p.standardError = err
        try p.run()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(),
                             as: UTF8.self)
        p.waitUntilExit()

        XCTAssertNotEqual(p.terminationStatus, 0, "the script must refuse")
        XCTAssertTrue(message.contains("refusing to remove the old one"), message)
        XCTAssertEqual(try String(contentsOf: keys, encoding: .utf8), before,
                       "the old key was removed while the new one does not authenticate")
    }

    /// Failing closed costs a manual step. The guard existing at all is what
    /// stops the alternative, so a bare entry further down the file still counts.
    func testABareEntryAmongConstrainedOnesStillMatches() throws {
        try XCTAssertTrue(matchesBareEntry("""
        from="10.0.0.0/8" \(key.line)
        \(key.line)
        """ + "\n"))
    }
}
