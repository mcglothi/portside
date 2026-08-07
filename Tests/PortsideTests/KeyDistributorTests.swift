import Foundation
import XCTest
@testable import Portside

/// The key that all of these push around.
private let testKey = PublicKey(
    path: "/tmp/portside-test.pub",
    line: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPortsideTestKeyBlob tim@newton",
    algorithm: "ssh-ed25519",
    blob: "AAAAC3NzaC1lZDI1NTE5AAAAIPortsideTestKeyBlob",
    comment: "tim@newton",
    fingerprint: "SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
    bits: 256
)

private func host(_ name: String, protected: Bool = false) -> SessionEntry {
    var e = SessionEntry(name: name)
    e.kind = .host
    e.hostname = "\(name).internal"
    e.user = "tim"
    e.isProtected = protected
    return e
}

// MARK: - The rule the whole feature exists for

final class KeyDistributorSafetyTests: XCTestCase {

    /// Forty hosts pushed with a stale password is forty failed
    /// authentications and a locked account. There is no configuration, host
    /// kind, or credential state that may produce a second prompt.
    func testEveryConnectionCapsPasswordPromptsAtOne() {
        for hasPassword in [true, false] {
            for accept in [true, false] {
                for protected in [true, false] {
                    var defaults = ConnectionDefaults()
                    defaults.autoAcceptNewHostKeys = accept
                    let args = KeyDistributor.sshArguments(
                        for: host("h", protected: protected),
                        hasPassword: hasPassword, defaults: defaults)
                    XCTAssertTrue(
                        adjacent(args, "-o", "NumberOfPasswordPrompts=1"),
                        "password=\(hasPassword) accept=\(accept): prompt cap missing")
                    XCTAssertFalse(args.contains { $0.hasPrefix("NumberOfPasswordPrompts=") &&
                                                   $0 != "NumberOfPasswordPrompts=1" },
                                   "a second prompt count was set")
                }
            }
        }
    }

    /// With no password held there is nothing to answer a prompt with, so the
    /// connection must fail rather than block a queue nobody is watching.
    func testBatchModeOnlyWhenThereIsNoPassword() {
        XCTAssertTrue(adjacent(KeyDistributor.sshArguments(for: host("h"), hasPassword: false),
                               "-o", "BatchMode=yes"))
        XCTAssertFalse(adjacent(KeyDistributor.sshArguments(for: host("h"), hasPassword: true),
                                "-o", "BatchMode=yes"))
    }

    /// Every connection is bounded, so one unreachable host can't stall the run.
    func testConnectionsAreTimeBounded() {
        XCTAssertTrue(adjacent(KeyDistributor.sshArguments(for: host("h"), hasPassword: true),
                               "-o", "ConnectTimeout=15"))
    }

    /// Reuse a live session's master, never become one — a push must not leave
    /// a socket behind that other connections then depend on.
    func testPushesNeverBecomeTheControlMaster() {
        let args = KeyDistributor.sshArguments(for: host("h"), hasPassword: true)
        XCTAssertTrue(adjacent(args, "-o", "ControlMaster=no"))
        XCTAssertFalse(args.contains("ControlMaster=auto"))
        XCTAssertFalse(args.contains("ControlMaster=yes"))
    }

    /// Host-key policy follows the app's own setting and is never loosened
    /// beyond it — a push must not be the thing that quietly disables MITM
    /// protection.
    func testHostKeyPolicyFollowsTheSettingAndIsNeverDisabled() {
        var on = ConnectionDefaults(); on.autoAcceptNewHostKeys = true
        XCTAssertTrue(adjacent(KeyDistributor.sshArguments(for: host("h"), hasPassword: true, defaults: on),
                               "-o", "StrictHostKeyChecking=accept-new"))

        var off = ConnectionDefaults(); off.autoAcceptNewHostKeys = false
        let args = KeyDistributor.sshArguments(for: host("h"), hasPassword: true, defaults: off)
        XCTAssertFalse(args.contains { $0.hasPrefix("StrictHostKeyChecking=") })
        XCTAssertFalse(args.contains("StrictHostKeyChecking=no"))
    }

    /// A run must attempt each host exactly once. This is the assertion that
    /// would catch a retry loop being added later.
    func testEachHostIsContactedExactlyOnce() async {
        let calls = Counter()
        let hosts = [host("a"), host("b"), host("c")]
        let results = await KeyDistributor.push(
            key: testKey, to: hosts, password: { _ in "pw" },
            runner: { _, _, _, _ in
                await calls.bump()
                return (255, "", "Permission denied (publickey,password).")
            },
            progress: { _ in }
        )
        let count = await calls.value
        XCTAssertEqual(count, 3, "expected one attempt per host, got \(count)")
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { !$0.outcome.isSuccess })
    }

    /// A failure on one host must not abandon the rest — the report is the
    /// product, and a partial one is what makes a fleet push hard to trust.
    func testOneFailureDoesNotStopTheRun() async {
        let hosts = [host("a"), host("b"), host("c")]
        let results = await KeyDistributor.push(
            key: testKey, to: hosts, password: { _ in "pw" },
            runner: { _, args, _, _ in
                if args.contains(where: { $0.contains("b.internal") }) {
                    return (255, "", "Permission denied (publickey,password).")
                }
                return (0, "PORTSIDE-RESULT: added\n", "")
            },
            progress: { _ in }
        )
        XCTAssertEqual(results.map(\.hostName), ["a", "b", "c"])
        XCTAssertEqual(results[0].outcome, .added)
        XCTAssertFalse(results[1].outcome.isSuccess)
        XCTAssertEqual(results[2].outcome, .added)
    }

    /// Results arrive as they land, so a long run shows progress rather than
    /// sitting silent and then reporting everything at once.
    func testProgressIsReportedPerHostInOrder() async {
        let seen = Collector()
        _ = await KeyDistributor.push(
            key: testKey, to: [host("a"), host("b")], password: { _ in "pw" },
            runner: { _, _, _, _ in (0, "PORTSIDE-RESULT: added\n", "") },
            progress: { result in Task { await seen.add(result.hostName) } }
        )
        // Drain the progress hops before asserting.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let names = await seen.values
        XCTAssertEqual(names, ["a", "b"])
    }

    private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
        for (i, a) in args.enumerated() where a == flag {
            if i + 1 < args.count, args[i + 1] == value { return true }
        }
        return false
    }
}

private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

private actor Collector {
    private(set) var values: [String] = []
    func add(_ v: String) { values.append(v) }
}

// MARK: - Reading the result

final class KeyDistributorOutcomeTests: XCTestCase {

    func testMarkersDecideTheOutcome() {
        XCTAssertEqual(KeyDistributor.outcome(status: 0, out: "PORTSIDE-RESULT: added\n", err: ""), .added)
        XCTAssertEqual(KeyDistributor.outcome(status: 0, out: "PORTSIDE-RESULT: present\n", err: ""),
                       .alreadyPresent)
    }

    /// A login shell that prints a banner or exits non-zero must not turn a
    /// successful install into a reported failure.
    func testChattyHostsStillReportSuccess() {
        let out = """
        Welcome to Ubuntu 22.04.3 LTS
        Last login: Tue Aug  5 09:12:44 2026
        PORTSIDE-RESULT: added
        """
        XCTAssertEqual(KeyDistributor.outcome(status: 1, out: out, err: "motd noise"), .added)
    }

    /// No marker means it did not run, whatever the exit status says.
    func testMissingMarkerIsAlwaysAFailure() {
        XCTAssertFalse(KeyDistributor.outcome(status: 0, out: "", err: "").isSuccess)
        XCTAssertFalse(KeyDistributor.outcome(status: 0, out: "all done!", err: "").isSuccess)
    }

    /// ssh puts the useful line after its own noise; taking the first line
    /// would report "Warning: Permanently added…" as the reason a push failed.
    func testFailureReasonSkipsSshNoise() {
        let err = """
        Warning: Permanently added 'db1.internal' (ED25519) to the list of known hosts.
        tim@db1.internal: Permission denied (publickey,password).
        """
        let reason = KeyDistributor.failureReason(status: 255, err: err)
        XCTAssertTrue(reason.contains("Permission denied"), "got: \(reason)")
        XCTAssertFalse(reason.contains("Permanently added"))
    }

    func testFailureReasonNamesCommonFailures() {
        for phrase in ["Permission denied (publickey).",
                       "ssh: Could not resolve hostname nope: nodename nor servname provided",
                       "ssh: connect to host x port 22: Connection refused",
                       "Host key verification failed."] {
            XCTAssertEqual(KeyDistributor.failureReason(status: 255, err: phrase), phrase)
        }
    }

    func testFailureReasonFallsBackToTheExitCode() {
        XCTAssertTrue(KeyDistributor.failureReason(status: 255, err: "").contains("could not connect"))
        XCTAssertTrue(KeyDistributor.failureReason(status: 7, err: "").contains("status 7"))
    }
}

// MARK: - The script, run for real

/// Runs the *generated* script through `/bin/sh` against a throwaway `HOME`.
///
/// These are the assertions that matter most and the ones a mock cannot make:
/// the script is shell, its failure modes are shell failure modes, and two real
/// bugs in it (a `$HOME` that never expanded inside single quotes, and an
/// append that welded the key onto a file with no trailing newline, breaking
/// that host's existing access) were both invisible to everything except
/// running it. No network, no host, no ssh — just the script and a temp
/// directory.
final class KeyDistributorScriptTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-keytest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var authorizedKeys: URL {
        home.appendingPathComponent(".ssh/authorized_keys")
    }

    @discardableResult
    private func runScript(key: PublicKey = testKey) throws -> String {
        let script = home.appendingPathComponent("push.sh")
        try KeyDistributor.remoteScript(for: key).write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func seed(_ contents: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try contents.write(to: authorizedKeys, atomically: true, encoding: .utf8)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func contents() throws -> String {
        try String(contentsOf: authorizedKeys, encoding: .utf8)
    }

    func testFreshHostGetsTheKeyWithTightPermissions() throws {
        let out = try runScript()
        XCTAssertTrue(out.contains("PORTSIDE-RESULT: added"), out)
        XCTAssertEqual(try mode(home.appendingPathComponent(".ssh")), 0o700)
        XCTAssertEqual(try mode(authorizedKeys), 0o600)
        XCTAssertEqual(try contents(), testKey.line + "\n")
    }

    func testSecondPushIsANoOp() throws {
        try runScript()
        let after = try contents()
        let out = try runScript()
        XCTAssertTrue(out.contains("PORTSIDE-RESULT: present"), out)
        XCTAssertEqual(try contents(), after, "a repeat push must not append a duplicate")
    }

    /// A commented-out entry is not access. Reporting "already present" for one
    /// would leave the user believing a key is installed that isn't.
    func testCommentedOutKeyDoesNotCountAsPresent() throws {
        try seed("#\(testKey.line)\n")
        let out = try runScript()
        XCTAssertTrue(out.contains("PORTSIDE-RESULT: added"), out)
        XCTAssertTrue(try contents().hasSuffix(testKey.line + "\n"))
    }

    /// `authorized_keys` entries may carry `command=`/`from=` options, which
    /// push the algorithm out of the first field.
    func testKeyBehindOptionsCountsAsPresent() throws {
        try seed("command=\"/usr/bin/true\",no-pty \(testKey.line)\n")
        XCTAssertTrue(try runScript().contains("PORTSIDE-RESULT: present"))
    }

    /// The comment is decoration; the same key under a different comment is the
    /// same key, and appending it again would be a duplicate.
    func testSameKeyWithADifferentCommentCountsAsPresent() throws {
        try seed("\(testKey.algorithm) \(testKey.blob) someone@elsewhere\n")
        XCTAssertTrue(try runScript().contains("PORTSIDE-RESULT: present"))
    }

    /// A different key is not this key.
    func testAnotherKeyDoesNotCountAsPresent() throws {
        try seed("ssh-rsa AAAADIFFERENTBLOB someone@elsewhere\n")
        XCTAssertTrue(try runScript().contains("PORTSIDE-RESULT: added"))
        XCTAssertEqual(try contents().split(separator: "\n").count, 2)
    }

    /// **The one that corrupts a host.** Appending to a file with no trailing
    /// newline welds the new key onto the last entry, breaking that host's
    /// existing access as well as failing to install ours.
    func testAppendingToAFileWithNoTrailingNewlineKeepsBothKeysIntact() throws {
        try seed("ssh-rsa AAAAOTHERKEY other@host")   // deliberately no "\n"
        try runScript()
        let written = try contents()
        let lines = written.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2, "keys were merged onto one line: \(written)")
        XCTAssertEqual(String(lines[0]), "ssh-rsa AAAAOTHERKEY other@host")
        XCTAssertEqual(String(lines[1]), testKey.line)
    }

    /// An existing file's permissions are the user's business — a push tightens
    /// nothing it did not create.
    func testExistingPermissionsAreLeftAlone() throws {
        try seed("ssh-rsa AAAAOTHER other@host\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: authorizedKeys.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: home.appendingPathComponent(".ssh").path)
        try runScript()
        XCTAssertEqual(try mode(authorizedKeys), 0o644)
        XCTAssertEqual(try mode(home.appendingPathComponent(".ssh")), 0o755)
    }

    /// Cheap insurance, and the difference between a bad edit being a nuisance
    /// and being a trip to a console.
    func testTheFileIsCopiedAsideBeforeBeingChanged() throws {
        try seed("ssh-rsa AAAAOTHER other@host\n")
        try runScript()
        let backup = home.appendingPathComponent(".ssh/authorized_keys"
                                                 + KeyDistributor.backupSuffix)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8),
                       "ssh-rsa AAAAOTHER other@host\n")
    }

    func testNoBackupIsWrittenWhenNothingChanges() throws {
        try runScript()
        let backup = home.appendingPathComponent(".ssh/authorized_keys"
                                                 + KeyDistributor.backupSuffix)
        try? FileManager.default.removeItem(at: backup)
        try runScript()   // second push is a no-op
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "a no-op push should not rewrite the backup")
    }

    /// A key comment is attacker-adjacent input in the sense that matters here:
    /// it comes from a file, it reaches a shell, and it must arrive as data.
    func testAKeyCommentCannotInjectShell() throws {
        let nasty = PublicKey(
            path: "/tmp/x.pub",
            line: "ssh-ed25519 AAAABLOBSAFE it's me'; touch \(home.path)/PWNED; echo '",
            algorithm: "ssh-ed25519",
            blob: "AAAABLOBSAFE",
            comment: "it's me'; touch \(home.path)/PWNED; echo '",
            fingerprint: "SHA256:x", bits: 256)
        try runScript(key: nasty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("PWNED").path),
                       "the comment escaped its quoting and ran")
        XCTAssertTrue(try contents().contains("touch"), "the comment should be stored as text")
    }
}
