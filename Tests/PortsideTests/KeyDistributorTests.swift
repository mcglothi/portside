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

    /// Ours appearing as another key's *comment* is a real match by the rules
    /// we use (any field equal to the blob), and harmless: the file already
    /// contains the string, so re-adding gains nothing.
    func testOurBlobInAnotherKeysCommentCountsAsPresent() throws {
        try seed("ssh-rsa AAAADIFFERENT \(testKey.blob)\n")
        XCTAssertTrue(try runScript().contains("present"))
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

// MARK: - The account override

/// Overriding the account works by *logging in as it*, which is why there is no
/// permission story: `$HOME` is already the target's, nothing is escalated, and
/// the remote script is byte-for-byte the same one.
final class KeyDistributorAccountOverrideTests: XCTestCase {

    private func entry(alias: String? = nil) -> SessionEntry {
        var e = SessionEntry(name: "dns2")
        e.kind = .host
        e.hostname = "10.10.0.22"
        e.user = "mcglothi"
        e.sshAlias = alias
        return e
    }

    func testOverrideRetargetsAPlainHost() {
        let args = KeyDistributor.sshArguments(for: entry(), hasPassword: true,
                                               account: "svc_ansible")
        XCTAssertTrue(args.contains("svc_ansible@10.10.0.22"), "\(args)")
        XCTAssertFalse(args.contains("mcglothi@10.10.0.22"))
    }

    /// An aliased host's destination is the bare alias and carries no user at
    /// all, so `-l` is the only thing that can retarget it.
    func testOverrideRetargetsAnAliasedHost() {
        let args = KeyDistributor.sshArguments(for: entry(alias: "dns2-prod"),
                                               hasPassword: true, account: "svc_ansible")
        XCTAssertTrue(args.contains("dns2-prod"))
        XCTAssertTrue(adjacent(args, "-l", "svc_ansible"), "\(args)")
    }

    /// Both forms are set so the two always agree and neither depends on ssh's
    /// precedence between `-l` and `user@host`.
    func testOverrideSetsBothTheFlagAndTheDestination() {
        let args = KeyDistributor.sshArguments(for: entry(), hasPassword: true,
                                               account: "svc_ansible")
        XCTAssertTrue(adjacent(args, "-l", "svc_ansible"))
        XCTAssertTrue(args.contains("svc_ansible@10.10.0.22"))
    }

    func testNoOverrideLeavesTheHostAlone() {
        for account in [nil, "", "   "] as [String?] {
            let args = KeyDistributor.sshArguments(for: entry(), hasPassword: true,
                                                   account: account)
            XCTAssertTrue(args.contains("mcglothi@10.10.0.22"), "account=\(account ?? "nil")")
            XCTAssertFalse(args.contains("-l"))
        }
    }

    func testOverrideIsTrimmed() {
        let args = KeyDistributor.sshArguments(for: entry(), hasPassword: true,
                                               account: "  svc_ansible  ")
        XCTAssertTrue(args.contains("svc_ansible@10.10.0.22"))
    }

    /// The override still can't buy a second password prompt.
    func testOverrideDoesNotRelaxThePromptCap() {
        let args = KeyDistributor.sshArguments(for: entry(), hasPassword: true,
                                               account: "svc_ansible")
        XCTAssertTrue(adjacent(args, "-o", "NumberOfPasswordPrompts=1"))
    }

    // MARK: Which password gets spent

    /// **The host's own password belongs to a different account.** Offering it
    /// to the override target is a guaranteed failed authentication on every
    /// host in the run — the exact lockout this feature exists to avoid.
    func testAProfileWhoseUserMatchesSuppliesThePassword() {
        var profile = CredentialProfile(name: "Ansible")
        profile.user = "svc_ansible"
        let password = KeyDistributor.password(
            forAccount: "svc_ansible", profiles: [profile],
            profilePassword: { $0 == profile.id ? "secret" : nil })
        XCTAssertEqual(password, "secret")
    }

    func testNoMatchingProfileMeansNoPassword() {
        var profile = CredentialProfile(name: "Ops")
        profile.user = "someone-else"
        XCTAssertNil(KeyDistributor.password(forAccount: "svc_ansible", profiles: [profile],
                                             profilePassword: { _ in "secret" }))
        XCTAssertNil(KeyDistributor.password(forAccount: "svc_ansible", profiles: [],
                                             profilePassword: { _ in "secret" }))
    }

    /// A matching profile with no stored password yields nothing, so the push
    /// runs key/agent-only rather than under a password it doesn't have.
    func testMatchingProfileWithNoPasswordYieldsNothing() {
        var profile = CredentialProfile(name: "Ansible")
        profile.user = "svc_ansible"
        XCTAssertNil(KeyDistributor.password(forAccount: "svc_ansible", profiles: [profile],
                                             profilePassword: { _ in nil }))
    }

    func testAnEmptyAccountNeverResolvesAPassword() {
        var profile = CredentialProfile(name: "Blank")
        profile.user = ""
        XCTAssertNil(KeyDistributor.password(forAccount: "   ", profiles: [profile],
                                             profilePassword: { _ in "secret" }))
    }

    private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
        for (i, a) in args.enumerated() where a == flag {
            if i + 1 < args.count, args[i + 1] == value { return true }
        }
        return false
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
