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


/// Mimics a host running the script: pulls this push's nonce out of the script
/// it was sent and echoes the marker with it. A fake that returns a hardcoded
/// marker is no longer believed — which is the nonce doing its job.
func hostReply(_ args: [String], _ result: String) -> String {
    guard let script = args.last else { return "" }
    // The script embeds it as: printf '%s%s added\n' 'PORTSIDE-RESULT:' '<nonce>'
    guard let marker = script.range(of: "'\(KeyDistributor.resultMarker)' '") else { return "" }
    let rest = script[marker.upperBound...]
    guard let end = rest.firstIndex(of: "'") else { return "" }
    return "\(KeyDistributor.resultMarker)\(rest[..<end]) \(result)\n"
}

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
                return (0, hostReply(args, "added"), "")
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
            runner: { _, args, _, _ in (0, hostReply(args, "added"), "") },
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

    /// **ssh writes its own client errors with CRLF.** Measured, not assumed:
    /// `ssh: Could not resolve hostname …` arrives `\r\n`-terminated. Since
    /// `\r\n` is a single Swift `Character`, splitting on `"\n"` found no
    /// separator and treated the whole transcript as one line — so the leading
    /// `Warning:` swallowed everything and the real reason was replaced by a
    /// bare exit code.
    ///
    /// Messages relayed from the *remote* side use plain `\n`, which is why
    /// sudo's refusals always looked right and hid this.
    func testFailureReasonHandlesSshsOwnCRLFOutput() {
        let err = "Warning: Permanently added 'db1.internal' (ED25519) to the list of known hosts.\r\n"
            + "tim@db1.internal: Permission denied (publickey,password).\r\n"
        let reason = KeyDistributor.failureReason(status: 255, err: err)

        XCTAssertTrue(reason.contains("Permission denied"), "got: \(reason)")
        XCTAssertFalse(reason.contains("Permanently added"),
                       "ssh's noise came back as the reason: \(reason)")
        XCTAssertFalse(reason.contains("could not connect"),
                       "fell through to the exit code instead of reading the message")
    }

    /// A reason is one line. Returning the whole transcript puts several lines
    /// of ssh debug output into a single result row.
    func testFailureReasonIsASingleLineWhateverTheLineEndings() {
        for (name, terminator) in [("LF", "\n"), ("CRLF", "\r\n")] {
            let err = ["ssh: connect to host db1 port 22: Connection refused",
                       "some trailing noise"].joined(separator: terminator)
            let reason = KeyDistributor.failureReason(status: 255, err: err)
            XCTAssertFalse(reason.contains("trailing noise"),
                           "\(name): the whole transcript came back as the reason")
            XCTAssertTrue(reason.contains("Connection refused"), "\(name): got \(reason)")
        }
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

    /// Remote hosts overwhelmingly run `dash` as `/bin/sh`, not bash. Testing
    /// under both is what makes "sh-portable" a claim rather than a hope.
    static var shells: [String] {
        ["/bin/sh", "/bin/dash", "/bin/bash"].filter {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    @discardableResult
    private func runScript(key: PublicKey = testKey, shell: String = "/bin/sh") throws -> String {
        let script = home.appendingPathComponent("push.sh")
        try KeyDistributor.remoteScript(for: key).write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
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


    // MARK: - Contents that already exist in authorized_keys

    /// A file edited on Windows, or copied through something that added CRs.
    func testCarriageReturnsDoNotHideAnExistingKey() throws {
        try seed("\(testKey.line)\r\n")
        XCTAssertTrue(try runScript().contains("present"),
                      "a CR after the comment must not make the key look absent")
    }

    func testTrailingWhitespaceDoesNotHideAnExistingKey() throws {
        try seed("\(testKey.line)   \n")
        XCTAssertTrue(try runScript().contains("present"))
    }

    func testAnIndentedEntryIsStillFound() throws {
        try seed("    \(testKey.line)\n")
        XCTAssertTrue(try runScript().contains("present"))
    }

    func testBlankLinesAreIgnored() throws {
        try seed("\n\n\(testKey.line)\n\n")
        XCTAssertTrue(try runScript().contains("present"))
    }

    /// A blob that is a *prefix* of ours is a different key. Matching on whole
    /// fields rather than substrings is what keeps this right — a `grep -F`
    /// would have called it present and installed nothing.
    func testAKeyWhoseBlobIsAPrefixOfOursIsNotUs() throws {
        try seed("\(testKey.algorithm) \(testKey.blob)EXTRALONGER other@host\n")
        XCTAssertTrue(try runScript().contains("added"))
        XCTAssertEqual(try contents().split(separator: "\n").count, 2)
    }

    /// **This used to assert the opposite, and the reasoning was wrong.**
    ///
    /// The old rule was "any field equal to the blob", and the old comment here
    /// called a match in someone else's comment field harmless because "the
    /// file already contains the string". A comment grants nothing — sshd
    /// authenticates on type and blob, not on text further along the line — so
    /// the host was reported as already trusting a key it does not have, the
    /// push installed nothing, and the operator was told it had worked.
    ///
    /// The retire path shares this check, where the same false match deletes
    /// the unrelated key whose comment mentioned the blob. That is why this is
    /// a destructive bug and not a cosmetic one.
    func testOurBlobInAnotherKeysCommentIsNotUs() throws {
        try seed("ssh-rsa AAAADIFFERENT \(testKey.blob)\n")
        XCTAssertTrue(try runScript().contains("added"),
                      "a blob in a comment is not an installed key")
        XCTAssertEqual(try contents().split(separator: "\n").count, 2,
                       "our key should have been appended alongside")
    }

    /// The type alone is not us either — every ed25519 key on the host shares
    /// it, so matching on it without the blob beside it would call the first
    /// one a match.
    func testAnotherKeyOfTheSameTypeIsNotUs() throws {
        try seed("\(testKey.algorithm) AAAACOMPLETELYDIFFERENT other@host\n")
        XCTAssertTrue(try runScript().contains("added"))
        XCTAssertEqual(try contents().split(separator: "\n").count, 2)
    }

    /// The pair has to be **adjacent**. Our type at the end of one field group
    /// and our blob somewhere further along is not an entry granting our key.
    func testTheTypeAndBlobMustBeSideBySide() throws {
        try seed("ssh-rsa AAAADIFFERENT \(testKey.algorithm) trailing \(testKey.blob)\n")
        XCTAssertTrue(try runScript().contains("added"),
                      "type and blob separated by another field is not an installed key")
    }

    // MARK: - Hostile filesystem states

    /// `~/.ssh` existing as a *file* must fail cleanly, not report success.
    func testSSHDirectoryBeingAFileFailsWithoutClaimingSuccess() throws {
        try "not a directory".write(to: home.appendingPathComponent(".ssh"),
                                    atomically: true, encoding: .utf8)
        let out = try runScript()
        XCTAssertFalse(out.contains("added"))
        XCTAssertFalse(out.contains("present"))
    }

    /// A read-only `authorized_keys` must not produce a success marker — the
    /// user needs to know the key did not land.
    func testAReadOnlyFileDoesNotReportSuccess() throws {
        try seed("ssh-rsa AAAAOTHER other@host\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                              ofItemAtPath: authorizedKeys.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: authorizedKeys.path)
        }
        let out = try runScript()
        XCTAssertFalse(out.contains("added"), "reported success while unable to write")
    }

    /// A `~/.ssh` we cannot write into likewise fails rather than claiming.
    func testAnUnwritableSSHDirectoryDoesNotReportSuccess() throws {
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ssh.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        }
        let out = try runScript()
        XCTAssertFalse(out.contains("added"))
    }

    /// `authorized_keys` is often a symlink into a managed directory. Follow
    /// it; do not replace it with a regular file, which would silently detach
    /// the host from whatever manages it.
    func testASymlinkedAuthorizedKeysIsFollowedNotReplaced() throws {
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let real = home.appendingPathComponent("real_keys")
        try "ssh-rsa AAAAOTHER other@host\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: authorizedKeys, withDestinationURL: real)

        XCTAssertTrue(try runScript().contains("added"))
        XCTAssertTrue(try String(contentsOf: real, encoding: .utf8).contains(testKey.blob),
                      "the symlink target should have received the key")
        let type = try FileManager.default.attributesOfItem(atPath: authorizedKeys.path)[.type]
        XCTAssertEqual(type as? FileAttributeType, .typeSymbolicLink,
                       "the symlink was replaced with a regular file")
    }

    /// Home directories with spaces exist. Every path in the script is quoted.
    func testAHomeDirectoryWithSpacesWorks() throws {
        let spaced = home.appendingPathComponent("home with spaces")
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let script = spaced.appendingPathComponent("push.sh")
        try KeyDistributor.remoteScript(for: testKey).write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["HOME": spaced.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("added"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: spaced.appendingPathComponent(".ssh/authorized_keys").path))
    }

    /// A jump host's `authorized_keys` can be long. Nothing here is quadratic
    /// or line-limited.
    func testALargeAuthorizedKeysFileIsHandled() throws {
        let existing = (0..<500).map { "ssh-rsa AAAAKEY\($0) user\($0)@host" }.joined(separator: "\n")
        try seed(existing + "\n")
        XCTAssertTrue(try runScript().contains("added"))
        XCTAssertEqual(try contents().split(separator: "\n").count, 501)
    }

    /// The backup is a copy of a file full of credentials; it must not be
    /// created world-readable.
    func testTheBackupIsNotWorldReadable() throws {
        try seed("ssh-rsa AAAAOTHER other@host\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: authorizedKeys.path)
        try runScript()
        let backup = home.appendingPathComponent(".ssh/authorized_keys"
                                                 + KeyDistributor.backupSuffix)
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Portability

    /// The claim is "sh-portable". Remote hosts run `dash` as `/bin/sh` far
    /// more often than bash, and the two differ on exactly the kind of thing
    /// this script does.
    func testTheScriptBehavesIdenticallyUnderEveryShell() throws {
        for shell in Self.shells {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(".ssh"))
            XCTAssertTrue(try runScript(shell: shell).contains("added"), "add under \(shell)")
            XCTAssertTrue(try runScript(shell: shell).contains("present"), "idempotent under \(shell)")
        }
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

// MARK: - The success marker

final class KeyDistributorMarkerTests: XCTestCase {

    /// **Regression.** An edit once left `push` sending ssh arguments with no
    /// remote command attached at all — every host would have been logged into
    /// and handed nothing. Nothing else in the suite would have noticed,
    /// because the runner is injected and a mock happily returns success.
    func testTheScriptIsActuallySentToTheHost() async {
        let key = PublicKey(path: "/k.pub", line: "ssh-ed25519 AAAABLOB t@n",
                            algorithm: "ssh-ed25519", blob: "AAAABLOB",
                            comment: "t@n", fingerprint: "f", bits: 256)
        var host = SessionEntry(name: "h")
        host.kind = .host
        host.hostname = "h.internal"

        let seen = ArgsBox()
        _ = await KeyDistributor.push(key: key, to: host, password: nil,
                                      runner: { _, args, _, _ in
            await seen.set(args)
            return (0, "", "")
        })
        let args = await seen.value
        XCTAssertTrue(args.contains { $0.contains("authorized_keys") },
                      "the remote script must be the last argument: \(args)")
        XCTAssertTrue(args.last?.contains("AAAABLOB") ?? false,
                      "the key must reach the host")
    }

    /// The marker decides success and is read from output the host controls.
    /// A per-push nonce means a banner containing the bare marker can't turn a
    /// failure into a reported success.
    func testAMarkerWithoutTheNonceIsNotBelieved() {
        let outcome = KeyDistributor.outcome(
            status: 0, out: "PORTSIDE-RESULT: added\n", err: "", nonce: "abc123")
        XCTAssertFalse(outcome.isSuccess, "a marker without this push's nonce must not count")
    }

    func testAMarkerWithTheNonceIsBelieved() {
        XCTAssertEqual(
            KeyDistributor.outcome(status: 0, out: "PORTSIDE-RESULT:abc123 added\n",
                                   err: "", nonce: "abc123"),
            .added)
        XCTAssertEqual(
            KeyDistributor.outcome(status: 0, out: "PORTSIDE-RESULT:abc123 present\n",
                                   err: "", nonce: "abc123"),
            .alreadyPresent)
    }

    /// A nonce from a *different* push must not be accepted either.
    func testAnotherPushesNonceIsNotBelieved() {
        let outcome = KeyDistributor.outcome(
            status: 0, out: "PORTSIDE-RESULT:deadbeef added\n", err: "", nonce: "abc123")
        XCTAssertFalse(outcome.isSuccess)
    }

    func testNoncesAreDistinctAndSubstantial() {
        let nonces = (0..<200).map { _ in KeyDistributor.newNonce() }
        XCTAssertEqual(Set(nonces).count, 200, "nonces must not repeat")
        XCTAssertTrue(nonces.allSatisfy { $0.count >= 16 })
        // Must survive being embedded in single quotes in the script.
        XCTAssertTrue(nonces.allSatisfy { $0.allSatisfy(\.isHexDigit) })
    }
}

private actor ArgsBox {
    private(set) var value: [String] = []
    func set(_ v: [String]) { value = v }
}

// MARK: - Reaching another account, via sudo

/// One rule: an account means sudo. Writing into another account's home always
/// requires escalation — the same reason Ansible's `authorized_key` pairs its
/// `user:` parameter with `become`.
final class KeyDistributorSudoTests: XCTestCase {

    private let key = PublicKey(
        path: "/k.pub", line: "ssh-ed25519 AAAABLOB it's mine",
        algorithm: "ssh-ed25519", blob: "AAAABLOB", comment: "it's mine",
        fingerprint: "f", bits: 256)

    func testNoAccountSendsThePlainScript() {
        let command = KeyDistributor.remoteCommand(for: key, nonce: "n1", account: nil)
        XCTAssertEqual(command, KeyDistributor.remoteScript(for: key, nonce: "n1"))
        XCTAssertFalse(command.contains("sudo"))
    }

    func testAnEmptyAccountIsNotAnOverride() {
        for account in ["", "   "] {
            XCTAssertFalse(KeyDistributor.remoteCommand(for: key, nonce: "n", account: account)
                .contains("sudo"))
            XCTAssertFalse(KeyDistributor.requiresSudo(account: account))
        }
    }

    func testAnAccountWrapsTheScriptInSudo() {
        let command = KeyDistributor.remoteCommand(for: key, nonce: "n", account: "svc_ansible")
        XCTAssertTrue(command.contains("sudo -S -p '' sh -c"), command)
        XCTAssertTrue(KeyDistributor.requiresSudo(account: "svc_ansible"))
    }

    /// The home comes from the host's passwd database, not from `-H` and not
    /// from assuming `/home/$u`. `~u` cannot be expanded from a variable in
    /// POSIX sh, and plenty of hosts don't lay homes out that way.
    func testTheTargetHomeIsResolvedFromPasswd() {
        let script = KeyDistributor.remoteScript(for: key, nonce: "n", account: "svc")
        XCTAssertTrue(script.contains(#"getent passwd "$u""#), script)
        XCTAssertTrue(script.contains("/etc/passwd"), "no fallback when getent is absent")
        // Comments stripped: one of them explains why /home/$u is wrong, and
        // would otherwise fail this on working code.
        let code = script.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("/home/"), "the home layout must not be assumed")
    }

    /// **Runs as root, deliberately.** `sudo -u <account>` cannot bootstrap:
    /// the account can't create its own home under `/home`, and a `~/.ssh`
    /// made earlier by a bare `sudo mkdir` is root-owned and closed to it.
    /// Both were live failures. Root plus explicit `chown` is what Ansible's
    /// `authorized_key` does with `become`, and for the same reason.
    /// **This asserted the opposite, and passed for the wrong reason.**
    ///
    /// It used to require `!command.contains("-u svc")` with the message "must
    /// not drop to the target account" — the old root-does-everything design.
    /// After the change it kept passing only because the drop lives inside the
    /// base64-encoded inner script, so the literal never appears in the outer
    /// command. A test that cannot fail is not evidence.
    func testTheOuterCommandEscalatesAndTheInnerScriptDropsBack() {
        let command = KeyDistributor.remoteCommand(for: key, nonce: "n", account: "svc")
        XCTAssertTrue(command.contains("sudo -S -p ''"),
                      "the outer command must escalate once, reading the password from stdin")

        let script = KeyDistributor.remoteScript(for: key, nonce: "n", account: "svc")
        XCTAssertTrue(script.contains(#"sudo -n -u "$u""#),
                      "the script must drop to the account rather than staying root")
        // Root's half creates the home and nothing else; anything touching the
        // account's files belongs after the drop.
        let rootHalf = script.components(separatedBy: "sudo -n -u").first ?? script
        XCTAssertFalse(rootHalf.contains("authorized_keys"),
                       "root touches authorized_keys before dropping: \(rootHalf)")
        XCTAssertFalse(rootHalf.contains(".ssh\" ||"),
                       "root creates ~/.ssh instead of leaving it to the account")
    }

    /// The plain path is untouched by any of this: no passwd lookup, no chown,
    /// no new dependency on `getent`.
    func testTheNoAccountScriptIsUnchanged() {
        let script = KeyDistributor.remoteScript(for: key, nonce: "n", account: nil)
        XCTAssertTrue(script.contains(#"h="$HOME""#))
        XCTAssertFalse(script.contains("getent"))
        XCTAssertFalse(script.contains("chown"))
    }

    /// The script is quoted shell containing single quotes of its own. It
    /// travels base64-encoded precisely so it can't terminate the wrapper's
    /// quoting — the classic way this kind of nesting breaks.
    func testTheScriptTravelsEncodedNotInterpolated() {
        let command = KeyDistributor.remoteCommand(for: key, nonce: "n", account: "svc")
        XCTAssertFalse(command.contains("authorized_keys"),
                       "the raw script must not be interpolated into the wrapper")
        let encoded = Data(KeyDistributor.remoteScript(for: key, nonce: "n", account: "svc").utf8)
            .base64EncodedString()
        XCTAssertTrue(command.contains(encoded))
    }

    /// An account name is user input reaching a shell, so it must arrive as a
    /// single word.
    ///
    /// Asserted on the *quoting* rather than on the absence of the payload
    /// text: correctly escaped input still contains its own characters, so
    /// "the dangerous substring isn't present" is a check that fails on
    /// working code. `KeyDistributorSudoExecutionTests` proves the real
    /// property by running it.
    func testAnAccountNameIsShellQuoted() {
        let nasty = "svc'; rm -rf /; echo '"
        // The name now lives inside the base64'd script rather than in the
        // wrapper, so the assertion has to look where it actually goes.
        let script = KeyDistributor.remoteScript(for: key, nonce: "n", account: nasty)
        XCTAssertTrue(script.contains("u=\(ShellQuoting.quote(nasty))"),
                      "the account name was not quoted: \(script)")
    }

    /// The prompt is silenced so it can't be mistaken for host output, and the
    /// password comes from stdin rather than a tty we don't have.
    func testSudoReadsThePasswordFromStdinWithNoPrompt() {
        let command = KeyDistributor.remoteCommand(for: key, nonce: "n", account: "svc")
        XCTAssertTrue(command.contains("-S"))
        XCTAssertTrue(command.contains("-p ''"))
    }

    /// **One attempt, extended to sudo.** A failed sudo is logged on the host
    /// and repeats carry the same lockout risk as repeated ssh authentications.
    func testTheSudoPasswordIsSentExactlyOnce() async {
        var host = SessionEntry(name: "h")
        host.kind = .host
        host.hostname = "h.internal"
        let calls = StdinBox()
        _ = await KeyDistributor.push(
            key: key, to: host, password: "hunter2", account: "svc",
            runner: { _, _, _, stdin in
                await calls.record(stdin)
                return (1, "", "sudo: 1 incorrect password attempt")
            })
        let seen = await calls.values
        XCTAssertEqual(seen.count, 1, "sudo must not be retried")
        XCTAssertEqual(seen.first, "hunter2\n")
    }

    /// Nothing is sent on stdin when there is no account — there is no sudo to
    /// feed, and a stray password on stdin would reach the remote script.
    func testNoPasswordIsSentOnStdinWithoutAnAccount() async {
        var host = SessionEntry(name: "h")
        host.kind = .host
        host.hostname = "h.internal"
        let calls = StdinBox()
        _ = await KeyDistributor.push(
            key: key, to: host, password: "hunter2", account: nil,
            runner: { _, _, _, stdin in
                await calls.record(stdin)
                return (0, "", "")
            })
        let seen = await calls.values
        XCTAssertEqual(seen.first, "")
    }

    /// sudo's refusals are the answer the user needs; a generic exit code makes
    /// the feature look broken rather than unpermitted.
    func testSudoRefusalsAreReportedInPlainWords() {
        for phrase in ["sudo: a password is required",
                       "deploy is not in the sudoers file.  This incident will be reported.",
                       "sudo: no tty present and no askpass program specified",
                       "sudo: unknown user: svc_ansible"] {
            XCTAssertEqual(KeyDistributor.failureReason(status: 1, err: phrase), phrase)
        }
    }
}

private actor StdinBox {
    private(set) var values: [String] = []
    func record(_ v: String) { values.append(v) }
}

/// Runs the sudo wrapper for real, against a stub `sudo` on `PATH`.
///
/// The wrapper nests a base64 command substitution inside a double-quoted
/// argument to `sh -c`, wrapping a script that is itself full of single quotes.
/// Reading that and believing it works is not the same as running it — this is
/// the only test that proves the quoting survives a real shell.
final class KeyDistributorSudoExecutionTests: XCTestCase {

    private var home: URL!
    private var bin: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-sudo-\(UUID().uuidString)")
        bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // A stub sudo: swallow its own flags, ignore the target user (we can't
        // switch users in a test), and exec the rest. Enough to prove the
        // command reaches it intact.
        let stub = """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            -S|-H|-n) shift ;;
            -p) shift 2 ;;
            -u) shift 2 ;;
            *) break ;;
          esac
        done
        cat > /dev/null &   # drain the password on stdin
        exec "$@"
        """
        let sudo = bin.appendingPathComponent("sudo")
        try stub.write(to: sudo, atomically: true, encoding: .utf8)

        // The script now resolves the target's home from passwd rather than
        // using $HOME, so it needs a passwd database to read.
        try "#!/bin/sh\necho 'svc:x:900:900::\(home.path):/bin/sh'\n"
            .write(to: bin.appendingPathComponent("getent"), atomically: true, encoding: .utf8)
        // Ownership can't be changed in a test; record instead of acting.
        try "#!/bin/sh\nexit 0\n"
            .write(to: bin.appendingPathComponent("chown"), atomically: true, encoding: .utf8)
        // These cases are about quoting surviving two layers, not about
        // ownership, so `find` reports whatever was asked for. Ownership itself
        // is covered by KeyDistributorBootstrapTests, which models it properly.
        try "#!/bin/sh\necho \"$1\"\n"
            .write(to: bin.appendingPathComponent("find"), atomically: true, encoding: .utf8)

        for tool in ["sudo", "getent", "chown", "find"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(tool).path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// The real proof that an account name can't inject: run it and check the
    /// side effect never happens.
    func testAMaliciousAccountNameRunsNothing() throws {
        let canary = home.appendingPathComponent("PWNED")
        let key = PublicKey(path: "/k.pub", line: "ssh-ed25519 AAAABLOB t@n",
                            algorithm: "ssh-ed25519", blob: "AAAABLOB",
                            comment: "t@n", fingerprint: "f", bits: 256)
        let command = KeyDistributor.remoteCommand(
            for: key, nonce: "n", account: "svc'; touch \(canary.path); echo '")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path),
                       "the account name escaped its quoting and executed")
    }

    func testTheWrappedScriptSurvivesRealShellQuoting() throws {
        let key = PublicKey(
            path: "/k.pub",
            line: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 it's a comment with 'quotes'",
            algorithm: "ssh-ed25519", blob: "AAAAC3NzaC1lZDI1NTE5",
            comment: "it's a comment with 'quotes'", fingerprint: "f", bits: 256)
        let command = KeyDistributor.remoteCommand(for: key, nonce: "nonce123", account: "svc")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data("password\n".utf8))
        stdin.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(output.contains("PORTSIDE-RESULT:nonce123 added"),
                      "the wrapped script did not run cleanly: \(output)")

        let installed = try String(
            contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8)
        XCTAssertEqual(installed, key.line + "\n",
                       "the key must arrive byte-identical through two layers of quoting")
    }
}

/// Bootstrapping an account whose home does not exist yet.
///
/// Both of these were live failures on a real host. The first design ran the
/// script *as* the target account, which gets ownership for free and cannot
/// bootstrap: `mkdir -p /home/svc_goose` as `svc_goose` fails because `/home`
/// isn't theirs, and a `~/.ssh` created earlier with a bare `sudo mkdir` is
/// root-owned, so the target can't create `authorized_keys` inside it either.
/// Running as root and repairing ownership is the fix — and ownership then has
/// to be *tested*, because root-owned files in someone's `~/.ssh` are silent
/// breakage: sshd's `StrictModes` refuses them and the key just never works.
final class KeyDistributorBootstrapTests: XCTestCase {

    private var root: URL!
    private var bin: URL!
    private var chownLog: URL!

    private let key = PublicKey(
        path: "/k.pub", line: "ssh-ed25519 AAAAGOOSE svc_goose@home",
        algorithm: "ssh-ed25519", blob: "AAAAGOOSE",
        comment: "svc_goose@home", fingerprint: "f", bits: 256)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-bootstrap-\(UUID().uuidString)")
        bin = root.appendingPathComponent("bin")
        chownLog = root.appendingPathComponent("chown.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `getent` stands in for the host's passwd database, so the script can be
    /// pointed at a home of our choosing. `chown` records rather than acts,
    /// since a test can't own files as another user.
    /// Paths whose ownership the stub `find` should report as something other
    /// than root. Written as "path owner writable" lines.
    private var ownersFile: URL { root.appendingPathComponent("owners") }

    /// The path as `cd … && pwd -P` reports it — which is what the script
    /// validates, and is not always what Foundation returns.
    private func shellResolved(_ path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cd \"$1\" 2>/dev/null && pwd -P", "sh", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func declareOwner(_ path: String, _ owner: String, writable: Bool = false) throws {
        let line = "\(path) \(owner) \(writable ? "yes" : "no")\n"
        let existing = (try? String(contentsOf: ownersFile, encoding: .utf8)) ?? ""
        try (existing + line).write(to: ownersFile, atomically: true, encoding: .utf8)
    }

    private func installStubs(home: String?) throws {
        let getent = home.map {
            "#!/bin/sh\necho 'svc_goose:x:900:900::\($0):/bin/sh'\n"
        } ?? "#!/bin/sh\nexit 2\n"     // no such user
        try getent.write(to: bin.appendingPathComponent("getent"),
                         atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        echo "$@" >> \(chownLog.path)
        """.write(to: bin.appendingPathComponent("chown"), atomically: true, encoding: .utf8)
        // The script drops privileges for the install phase. A test can't
        // actually switch user, so this stub swallows sudo's flags and runs the
        // rest as-is — enough to prove the hand-off is well formed and that the
        // inner script reaches the right home.
        try """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            -n|-S|-H) shift ;;
            -u|-p) shift 2 ;;
            *) break ;;
          esac
        done
        exec "$@"
        """.write(to: bin.appendingPathComponent("sudo"), atomically: true, encoding: .utf8)
        // A test cannot create root-owned ancestors or files owned by another
        // account, so ownership is modelled rather than real. Anything not
        // named in the owners file is reported as root-owned and unwritable by
        // others, which is what a sane host looks like.
        try """
        #!/bin/sh
        p=$1; shift
        want=""; perm=no
        while [ $# -gt 0 ]; do
          case "$1" in
            -user) want=$2; shift 2 ;;
            -perm) perm=yes; shift 2 ;;
            *) shift ;;
          esac
        done
        owner=$(awk -v p="$p" '$1 == p {print $2}' \(ownersFile.path) 2>/dev/null)
        writable=$(awk -v p="$p" '$1 == p {print $3}' \(ownersFile.path) 2>/dev/null)
        [ -n "$owner" ] || owner=root
        [ -n "$writable" ] || writable=no
        if [ "$perm" = yes ] && [ "$writable" = yes ]; then exit 0; fi
        if [ -z "$want" ] || [ "$want" = "$owner" ]; then echo "$p"; fi
        """.write(to: bin.appendingPathComponent("find"), atomically: true, encoding: .utf8)
        for stub in ["getent", "chown", "sudo", "find"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: bin.appendingPathComponent(stub).path)
        }
    }

    private func runPush(account: String? = "svc_goose")
        throws -> (out: String, err: String, status: Int32) {
        let script = root.appendingPathComponent("push.sh")
        try KeyDistributor.remoteScript(for: key, nonce: "n1", account: account)
            .write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        // The stubs come first so they shadow the real tools.
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: o, as: UTF8.self),
                String(decoding: e, as: UTF8.self),
                process.terminationStatus)
    }

    private var chownedPaths: String {
        (try? String(contentsOf: chownLog, encoding: .utf8)) ?? ""
    }

    /// **The reported failure.** The account's home doesn't exist at all.
    func testCreatesAHomeThatDoesNotExistYet() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        // Only the final component is created now — `mkdir`, not `mkdir -p` —
        // so the parent has to exist, exactly as /home does on a real host.
        try FileManager.default.createDirectory(at: home.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try installStubs(home: home.path)
        try declareOwner(home.path, "svc_goose")

        let result = try runPush()
        XCTAssertTrue(result.out.contains("PORTSIDE-RESULT:n1 added"),
                      "out=\(result.out) err=\(result.err)")
        let authorized = home.appendingPathComponent(".ssh/authorized_keys")
        XCTAssertEqual(try String(contentsOf: authorized, encoding: .utf8), key.line + "\n")
    }

    /// **Root creates the home and nothing else.**
    ///
    /// The home's parent (`/home`, or wherever passwd points) is root-owned, so
    /// it is not something the target account can redirect. Everything below it
    /// *is*, which is why `~/.ssh` and `authorized_keys` are created by the
    /// account after privileges are dropped — and therefore need no `chown` at
    /// all. A chown of either would mean root had written it.
    func testRootCreatesOnlyTheHomeAndChownsOnlyThat() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        try FileManager.default.createDirectory(at: home.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try installStubs(home: home.path)
        _ = try runPush()

        let log = chownedPaths
        XCTAssertTrue(log.contains(home.path), "the home was not chowned: \(log)")
        XCTAssertTrue(log.contains("svc_goose"), "chowned to the wrong account: \(log)")
        XCTAssertFalse(log.contains("/.ssh\n"),
                       "root created ~/.ssh instead of dropping privileges first: \(log)")
        XCTAssertFalse(log.contains("authorized_keys"),
                       "root created authorized_keys instead of dropping first: \(log)")
    }

    /// The install half must run as the account, not as root. This asserts on
    /// the generated script rather than the filesystem, because a test cannot
    /// actually switch user — the stub `sudo` runs the inner script in place.
    func testTheInstallPhaseIsHandedToTheAccount() {
        let script = KeyDistributor.remoteScript(for: key, nonce: "n1", account: "svc_goose")
        XCTAssertTrue(script.contains("sudo -n -u \"$u\""),
                      "the script never drops privileges: \(script)")
        // The part that writes authorized_keys must be inside the dropped half,
        // not in the root half.
        let rootHalf = script.components(separatedBy: "sudo -n -u").first ?? script
        XCTAssertFalse(rootHalf.contains("authorized_keys"),
                       "root touches authorized_keys before dropping: \(rootHalf)")
    }

    /// The home exists but `~/.ssh` doesn't — the state after someone made the
    /// home by hand.
    func testCreatesSSHInsideAnExistingHome() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try installStubs(home: home.path)
        try declareOwner(home.path, "svc_goose")

        XCTAssertTrue(try runPush().out.contains("added"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".ssh/authorized_keys").path))
        // An existing home is not ours to re-own, and ~/.ssh is the account's
        // to create.
        XCTAssertFalse(chownedPaths.contains("\(home.path)\n"),
                       "an existing home should not be chowned: \(chownedPaths)")
        XCTAssertFalse(chownedPaths.contains("/.ssh\n"),
                       "~/.ssh should be created by the account: \(chownedPaths)")
    }

    // MARK: - Hostile filesystem states in a home the account controls

    /// **The escalation this design exists to prevent.** The account owns its
    /// home, so it can point `~/.ssh` anywhere — at `/root/.ssh`, say — and a
    /// script running as root would happily install a key there.
    ///
    /// Root refuses rather than following it. Note what this test can and
    /// cannot show: it proves the refusal, but the privilege *drop* that makes
    /// the remaining paths safe cannot be exercised without a real second user,
    /// so the stub `sudo` runs the inner script in place.
    func testASymlinkedSSHDirectoryIsRefused() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        let victim = root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".ssh"), withDestinationURL: victim)
        try installStubs(home: home.path)
        try declareOwner(home.path, "svc_goose")

        let result = try runPush()
        XCTAssertNotEqual(result.status, 0, "a symlinked ~/.ssh must not succeed")
        XCTAssertTrue(result.err.contains("symbolic link"), "err=\(result.err)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: victim.appendingPathComponent("authorized_keys").path),
            "root wrote through the symlink into \(victim.path)")
    }

    /// The same for the home itself, which passwd points at and the account may
    /// have replaced.
    func testASymlinkedHomeIsRefused() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        let victim = root.appendingPathComponent("victim-home")
        try FileManager.default.createDirectory(at: home.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: victim)
        try installStubs(home: home.path)

        let result = try runPush()
        XCTAssertNotEqual(result.status, 0, "a symlinked home must not succeed")
        XCTAssertTrue(result.err.contains("symbolic link"), "err=\(result.err)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: victim.appendingPathComponent(".ssh").path),
            "root wrote through the symlinked home")
    }

    /// An existing `authorized_keys` belongs to the account already; appending
    /// to it must not change who owns it.
    func testAnExistingAuthorizedKeysIsNotReowned() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try "ssh-rsa AAAAOTHER other@host\n".write(
            to: ssh.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
        try installStubs(home: home.path)
        try declareOwner(home.path, "svc_goose")
        try declareOwner(ssh.path, "svc_goose")

        XCTAssertTrue(try runPush().out.contains("added"))
        XCTAssertFalse(chownedPaths.contains("authorized_keys\n"),
                       "an existing authorized_keys was re-owned: \(chownedPaths)")
    }

    /// **Blocker 2, pinned.** An earlier guard used `[ ! -O "$h/.ssh" ]`. `-O`
    /// asks whether the *effective* uid owns the path, which under root is true
    /// exactly when the directory is root-owned — so the conjunct exempted the
    /// one case the guard claimed to refuse, and a push proceeded against a
    /// root-owned `~/.ssh` that sshd would reject anyway.
    func testARootOwnedSSHDirectoryIsRefused() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try installStubs(home: home.path)
        try declareOwner(home.path, "svc_goose")
        try declareOwner(ssh.path, "root")

        let result = try runPush()
        XCTAssertNotEqual(result.status, 0, "a root-owned ~/.ssh must not be written to")
        XCTAssertTrue(result.err.contains("not owned by svc_goose"), "err=\(result.err)")
    }

    /// **Blocker 3, pinned.** Creating the home means root writes into a path it
    /// did not choose. That is only safe if no unprivileged party can modify any
    /// ancestor — otherwise a component can be swapped between the check and the
    /// `mkdir`. An ancestor writable by others must therefore stop the push
    /// rather than being created through.
    func testAnAncestorWritableByOthersRefusesToCreateTheHome() throws {
        let home = root.appendingPathComponent("home/svc_goose")
        let parent = home.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try installStubs(home: home.path)
        // Canonicalised before validation, so declare the path exactly as the
        // script will see it. Foundation's resolvingSymlinksInPath strips the
        // /private prefix that `pwd -P` produces, so resolve it the same way
        // the shell does rather than guessing.
        try declareOwner(shellResolved(parent.path), "root", writable: true)

        let result = try runPush()
        XCTAssertNotEqual(result.status, 0, "a world-writable ancestor must not be built through")
        XCTAssertTrue(result.err.contains("refusing to create"), "err=\(result.err)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path),
                       "the home was created despite an unsafe ancestor")
    }

    /// No `mkdir -p`: only the final component is ever created, so a missing
    /// parent is reported rather than built through.
    func testAMissingParentIsReportedRatherThanCreated() throws {
        let home = root.appendingPathComponent("nonexistent/deeper/svc_goose")
        try installStubs(home: home.path)

        let result = try runPush()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.err.contains("does not exist"), "err=\(result.err)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("nonexistent").path))
    }

    /// A typo in the account name must fail with a sentence, not a bare exit
    /// code — and must certainly not fall back to somebody else's home.
    func testAnUnknownAccountFailsClearly() throws {
        try installStubs(home: nil)
        let result = try runPush()
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains("unknown user svc_goose"), result.err)
        XCTAssertFalse(result.out.contains("added"))
        XCTAssertFalse(result.out.contains("present"))
    }

    /// `getent` is absent on some hosts (and on macOS entirely), so the passwd
    /// file is read directly as a fallback. Proven by removing the stub.
    func testFallsBackToEtcPasswdWhenGetentIsMissing() throws {
        try installStubs(home: root.appendingPathComponent("home/svc_goose").path)
        try FileManager.default.removeItem(at: bin.appendingPathComponent("getent"))
        // No getent and no such user in the real /etc/passwd: must fail
        // cleanly rather than resolve to an empty path and write to "/.ssh".
        let result = try runPush()
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.err.contains("unknown user"), result.err)
    }

    /// Without an account the script is unchanged: `$HOME`, no passwd lookup,
    /// no chown. The common case must not have grown a dependency on `getent`.
    func testTheNoAccountScriptNeitherLooksUpNorChowns() throws {
        try installStubs(home: nil)
        let result = try runPush(account: nil)
        XCTAssertTrue(result.out.contains("added"), "out=\(result.out) err=\(result.err)")
        XCTAssertEqual(chownedPaths, "", "the plain path must not chown anything")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".ssh/authorized_keys").path))
    }
}

/// An adversarial corpus for "does this line grant this key".
///
/// Two cheaper rules shipped or nearly shipped before this one: blob-anywhere,
/// and type-and-blob-adjacent-anywhere. Both were defeated by a key quoted
/// inside a comment or an option — a *reference* to a key, which is not an
/// authorization for it. The predicate decides both whether to install and
/// which line to delete, so a false positive either silently skips a push or
/// removes somebody else's access.
///
/// Every case runs the real generated `awk` under every `sh` on this machine.
final class AuthorizedKeysMatchingTests: XCTestCase {

    private let target = PublicKey(
        path: "/tmp/t.pub", line: "ssh-ed25519 AAAATARGET tim@newton",
        algorithm: "ssh-ed25519", blob: "AAAATARGET", comment: "tim@newton",
        fingerprint: "SHA256:t", bits: 256)

    private func grants(_ line: String, shell: String) throws -> Bool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keys = dir.appendingPathComponent("authorized_keys")
        try (line + "\n").write(to: keys, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("check.sh")
        try "f=\(ShellQuoting.quote(keys.path))\nif \(KeyDistributor.installedCheck(for: target)); then exit 0; else exit 1; fi\n"
            .write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [script.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func assertGrants(_ expected: Bool, _ line: String,
                              _ why: String, file: StaticString = #filePath,
                              line loc: UInt = #line) throws {
        for shell in KeyDistributorScriptTests.shells {
            let actual = try grants(line, shell: shell)
            XCTAssertEqual(actual, expected,
                           "\(shell): \(why) — \(line)", file: file, line: loc)
        }
    }

    // MARK: - Must NOT count as granting the key

    /// Codex's counter-example: the pair appears *adjacent*, but in the comment
    /// of a line that actually grants a different key.
    func testAKeyQuotedInAnotherKeysCommentDoesNotGrantIt() throws {
        try assertGrants(false, "ssh-rsa AAAAOTHER note ssh-ed25519 AAAATARGET",
                         "a key named in a comment is a reference, not a grant")
    }

    /// The same, hidden inside a quoted option value.
    func testAKeyQuotedInsideAnOptionDoesNotGrantIt() throws {
        try assertGrants(false,
                         "command=\"echo ssh-ed25519 AAAATARGET now\",no-pty ssh-rsa AAAAOTHER real",
                         "a key inside an option value is not a grant")
    }

    func testACommentedOutLineDoesNotGrant() throws {
        try assertGrants(false, "# ssh-ed25519 AAAATARGET tim", "a commented line grants nothing")
        try assertGrants(false, "   #ssh-ed25519 AAAATARGET tim", "indented comment")
    }

    func testADifferentKeyDoesNotGrant() throws {
        try assertGrants(false, "ssh-rsa AAAAOTHER other@host", "different type and blob")
        try assertGrants(false, "ssh-ed25519 AAAAOTHER other@host", "same type, different blob")
        try assertGrants(false, "ssh-rsa AAAATARGET other@host", "same blob, different type")
    }

    func testALongerBlobStartingWithOursDoesNotGrant() throws {
        try assertGrants(false, "ssh-ed25519 AAAATARGETLONGER tim", "prefix is not equality")
    }

    // MARK: - Must count as granting the key

    func testAPlainEntryGrants() throws {
        try assertGrants(true, "ssh-ed25519 AAAATARGET tim@newton", "the ordinary case")
        try assertGrants(true, "ssh-ed25519 AAAATARGET", "no comment at all")
        try assertGrants(true, "  ssh-ed25519 AAAATARGET tim", "leading whitespace")
        try assertGrants(true, "ssh-ed25519\tAAAATARGET\ttim", "tab separated")
    }

    /// Options push the key type out of the first field, which is the whole
    /// reason this needs a parser rather than a field index.
    func testAnEntryBehindOptionsGrants() throws {
        try assertGrants(true, "no-pty ssh-ed25519 AAAATARGET tim", "simple option")
        try assertGrants(true, "from=\"10.0.0.0/8\" ssh-ed25519 AAAATARGET tim", "quoted option")
        try assertGrants(true,
                         "command=\"/usr/bin/foo bar\",no-pty ssh-ed25519 AAAATARGET restricted",
                         "a quoted option containing a space")
    }

    /// The comment is decoration — the same key under a different comment is
    /// the same key.
    func testTheCommentIsNotPartOfIdentity() throws {
        try assertGrants(true, "ssh-ed25519 AAAATARGET someone@elsewhere", "different comment")
    }
}
