import Foundation
import XCTest
@testable import Portside

// The two keys every rotation test moves between.
private let newRotationKey = PublicKey(
    path: "/tmp/portside-new.pub",
    line: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAANEWKEYBLOB tim@newton",
    algorithm: "ssh-ed25519",
    blob: "AAAAC3NzaC1lZDI1NTE5AAAANEWKEYBLOB",
    comment: "tim@newton",
    fingerprint: "SHA256:NEWKEYFINGERPRINTaaaaaaaaaaaaaaaaaaaaaaaaaa",
    bits: 256
)

private let oldRotationKey = PublicKey(
    path: "/tmp/portside-old.pub",
    line: "ssh-rsa AAAAB3NzaC1yc2EAAAADOLDKEYBLOB tim@oldmac",
    algorithm: "ssh-rsa",
    blob: "AAAAB3NzaC1yc2EAAAADOLDKEYBLOB",
    comment: "tim@oldmac",
    fingerprint: "SHA256:OLDKEYFINGERPRINTbbbbbbbbbbbbbbbbbbbbbbbbbb",
    bits: 4096
)

private func rotationHost(_ name: String, alias: String? = nil,
                          identity: String? = nil) -> SessionEntry {
    var e = SessionEntry(name: name)
    e.kind = .host
    e.hostname = "\(name).internal"
    e.user = "tim"
    e.sshAlias = alias
    e.identityFile = identity
    return e
}

// MARK: - Verify: the three ways it could pass while proving nothing

/// Each of these corresponds to a measured way `ssh` will happily report a
/// successful connection that says nothing about the new key. They are the
/// reason rotation is not simply "connect and see if it works".
final class KeyRotatorVerifyArgumentTests: XCTestCase {

    private func args(_ entry: SessionEntry) -> [String] {
        KeyRotator.verifyArguments(for: entry, privateKeyPath: "/Users/t/.ssh/new", logFile: "/tmp/l")
    }

    /// **Trap 1.** Portside opens a `ControlMaster` for interactive sessions,
    /// and a connection that rides one authenticates nothing at all — verified
    /// against a real host, where `ssh -v` through a live master prints
    /// `mux_client_request_session` and not a single `Server accepts key` line.
    /// `ControlMaster=no` alone does **not** prevent joining an existing master;
    /// only `ControlPath=none` does.
    func testVerifyRefusesToRideAnExistingControlMaster() {
        let a = args(rotationHost("web1"))
        XCTAssertTrue(hasOption(a, "ControlPath=none"),
                      "a verify over a multiplexed connection proves nothing")
        XCTAssertTrue(hasOption(a, "ControlMaster=no"))
        XCTAssertFalse(a.contains { $0.contains("ControlPath=/") },
                       "the shared control path must not appear anywhere")
    }

    /// **Trap 2.** `sshArgs` carries the entry's own `identityFile`, which in a
    /// rotation is precisely the key being retired. Offering it here lets the
    /// old key satisfy the verify that is supposed to justify deleting it.
    func testVerifyNeverOffersTheEntrysOwnIdentityFile() {
        let entry = rotationHost("web1", identity: "/Users/t/.ssh/old_rsa")
        let a = args(entry)
        XCTAssertFalse(a.contains("/Users/t/.ssh/old_rsa"),
                       "the host's configured key must not be offered during a verify")
        // Exactly one -i, and it is ours.
        XCTAssertEqual(a.filter { $0 == "-i" }.count, 1)
        XCTAssertEqual(a[a.firstIndex(of: "-i")! + 1], "/Users/t/.ssh/new")
    }

    /// **Trap 3**, indirectly: an aliased host's `IdentityFile` comes from
    /// `~/.ssh/config` and `IdentitiesOnly=yes` still permits it, with no option
    /// to suppress it while keeping the alias resolvable. So the args cannot fix
    /// this one — the *assertion* has to be about which key was accepted, which
    /// is what `verifyOutcome` requires. This test pins that the alias is still
    /// used as the destination, since resolving it is why we can't use `-F
    /// /dev/null`.
    func testAnAliasedHostStillConnectsThroughItsAlias() {
        let a = args(rotationHost("web1", alias: "prod-web-1"))
        XCTAssertEqual(a.last, "prod-web-1")
    }

    /// A verify must never fall back to a password: that would report the
    /// password working, which is the opposite of the question.
    func testVerifyIsKeyOnlyAndNeverPrompts() {
        let a = args(rotationHost("web1"))
        XCTAssertTrue(hasOption(a, "PreferredAuthentications=publickey"))
        XCTAssertTrue(hasOption(a, "BatchMode=yes"))
        XCTAssertTrue(hasOption(a, "NumberOfPasswordPrompts=0"))
    }

    /// **The transcript must go to a private file, not to stderr.**
    ///
    /// ssh's stderr is shared with the remote host's. A host can print a
    /// convincing `Server accepts key` line of its own, and reading the decision
    /// out of a channel the host can write to is not evidence. `-E` moves ssh's
    /// own log somewhere the host cannot reach.
    ///
    /// `-E` alone logs at default verbosity and omits the authentication trace,
    /// so the two flags are only useful together — hence both asserted here.
    func testTheTranscriptGoesToAPrivateFileRatherThanStderr() {
        let a = KeyRotator.verifyArguments(for: rotationHost("web1"),
                                           privateKeyPath: "/k", logFile: "/tmp/x/ssh.log")
        guard let i = a.firstIndex(of: "-E") else {
            return XCTFail("no -E: the transcript would come back on shared stderr — \(a)")
        }
        XCTAssertEqual(a[i + 1], "/tmp/x/ssh.log")
        XCTAssertTrue(a.contains("-v"), "-E without -v omits the authentication trace")
    }

    /// The transcript names hosts and key paths, so it is not left in a
    /// world-readable temp file.
    func testThePrivateLogLivesInAnOwnerOnlyDirectory() throws {
        let log = try XCTUnwrap(KeyRotator.makePrivateLogFile())
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }

        let dir = log.deletingLastPathComponent()
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o700,
                       "the transcript directory is readable by others")
    }

    /// `-v` is not debugging left in by accident — it is the only place ssh
    /// reports which key the server accepted.
    func testVerifyAsksSSHToSayWhichKeyWasAccepted() {
        XCTAssertTrue(args(rotationHost("web1")).contains("-v"))
    }

    /// An account push installs the key for someone else, so proving it means
    /// logging in *as* that account. It has to go in the destination: a
    /// `user@host` destination overrides `-l`, so `-l` would be ignored on
    /// exactly the hosts that name a user.
    func testAnAccountRotationVerifiesByLoggingInAsThatAccount() {
        let a = KeyRotator.verifyArguments(for: rotationHost("web1"), privateKeyPath: "/k",
                                          logFile: "/tmp/l", account: "svc_goose")
        XCTAssertEqual(a.last, "svc_goose@web1.internal")
        XCTAssertFalse(a.contains("-l"), "-l is silently overridden by a user@host destination")

        let aliased = KeyRotator.verifyArguments(for: rotationHost("w", alias: "prod-1"),
                                                privateKeyPath: "/k", logFile: "/tmp/l",
                                                account: "svc_goose")
        XCTAssertEqual(aliased.last, "svc_goose@prod-1",
                       "an alias must keep resolving while its User is overridden")
    }

    private func hasOption(_ args: [String], _ option: String) -> Bool {
        guard let i = args.firstIndex(of: option) else { return false }
        return i > 0 && args[i - 1] == "-o"
    }
}

// MARK: - Verify: reading the answer

final class KeyRotatorVerifyOutcomeTests: XCTestCase {

    private let nonce = "abc123"

    /// ssh's verbose logger writes **CRLF**, so every fixture here does too. That
    /// is not incidental: with `\n` fixtures the CRLF bug below is invisible.
    private func accepted(_ fingerprint: String) -> String {
        "debug1: Offering public key: /Users/t/.ssh/new ED25519 \(fingerprint) explicit\r\n"
            + "debug1: Server accepts key: /Users/t/.ssh/new ED25519 \(fingerprint) explicit\r\n"
            + "Authenticated to web1 ([10.0.0.1]:22) using \"publickey\".\r\n"
    }

    /// What an aliased host really produces: our key offered and declined, then
    /// the config's own `IdentityFile` offered and accepted.
    private func offeredThenAnotherKeyAccepted(ours: String, theirs: String) -> String {
        "debug1: Offering public key: /Users/t/.ssh/new ED25519 \(ours) explicit\r\n"
            + "debug1: Offering public key: /Users/t/.ssh/id_rsa RSA \(theirs) explicit\r\n"
            + "debug1: Server accepts key: /Users/t/.ssh/id_rsa RSA \(theirs) explicit\r\n"
            + "Authenticated to web1 ([10.0.0.1]:22) using \"publickey\".\r\n"
    }

    private var ran: String { "\(KeyRotator.verifyMarker)\(nonce) ok\n" }

    /// `err` and `transcript` are separate channels now: the transcript is
    /// ssh's own `-E` log, which the remote cannot write to. Tests default to
    /// putting the transcript where it belongs and leaving stderr empty.
    private func outcome(out: String, err: String = "", transcript: String? = nil,
                         fingerprint: String = newRotationKey.fingerprint,
                         status: Int32 = 0) -> KeyVerifyOutcome {
        KeyRotator.verifyOutcome(status: status, out: out, err: err,
                                 transcript: transcript ?? err,
                                 nonce: nonce, fingerprint: fingerprint)
    }

    func testBothProofsPresentIsAPass() {
        XCTAssertEqual(outcome(out: ran, err: accepted(newRotationKey.fingerprint)), .verified)
    }

    /// **The trap-3 defence.** The connection succeeded and a session ran, but
    /// the key the server accepted was a different one — the old key, offered by
    /// `~/.ssh/config`. Reporting this as verified is how a fleet gets locked
    /// out, so it must not pass.
    func testAnotherKeyBeingAcceptedIsNotAPass() {
        let result = outcome(out: ran, err: accepted(oldRotationKey.fingerprint))
        XCTAssertNotEqual(result, .verified)
        XCTAssertFalse(result.provesKeyWorks)
    }

    /// **The regression that a real host caught, and no fixture had.**
    ///
    /// This is the exact shape an aliased host produces: our key offered and
    /// declined, the config's key accepted. It reported `.verified` — because
    /// `\r\n` is a single Swift `Character`, so `split(separator: "\n")` found no
    /// separators, the whole transcript became one "line", and a check for
    /// "some line has the accepted-prefix **and** our fingerprint" was satisfied
    /// by two *different* lines. An uninstalled key verified.
    ///
    /// The fixture is CRLF deliberately. With `\n` this test cannot fail.
    func testAKeyOfferedAndDeclinedIsRejectedEvenWhenAnotherKeyGetsIn() {
        let err = offeredThenAnotherKeyAccepted(ours: newRotationKey.fingerprint,
                                                theirs: oldRotationKey.fingerprint)
        let result = outcome(out: ran, err: err)
        XCTAssertFalse(result.provesKeyWorks,
                       "an uninstalled key must never verify — got \(result.label)")
        XCTAssertEqual(result, .rejected("the host would not authenticate this key"))
    }

    /// **The positional rule, which replaced "was our fingerprint accepted".**
    ///
    /// This transcript is the exact shape a fixture host produced when one
    /// key's `.pub` sat beside another's private key: our probe accepted, our
    /// signature rejected, then a different identity authenticated and the
    /// command ran. The old question — "does an accept line carry our
    /// fingerprint" — answers yes here, and is wrong.
    func testTheKeyThatAuthenticatedIsTheLastOneAcceptedBeforeAuthenticated() {
        let transcript = """
        debug1: Offering public key: /Users/t/.ssh/new ED25519 \(newRotationKey.fingerprint) explicit
        debug1: Server accepts key: /Users/t/.ssh/new ED25519 \(newRotationKey.fingerprint) explicit
        identity_sign: private key /Users/t/.ssh/new contents do not match public
        debug1: Offering public key: /Users/t/.ssh/id_rsa RSA \(oldRotationKey.fingerprint) explicit
        debug1: Server accepts key: /Users/t/.ssh/id_rsa RSA \(oldRotationKey.fingerprint) explicit
        Authenticated to web1 ([10.0.0.1]:22) using "publickey".
        """
        XCTAssertEqual(KeyRotator.authenticatingFingerprint(in: transcript),
                       oldRotationKey.fingerprint,
                       "the last accept before Authenticated is the one that worked")

        let result = outcome(out: ran, transcript: transcript)
        XCTAssertFalse(result.provesKeyWorks, "got \(result.label)")
    }

    /// **Two failures that look identical if you only ask "did it authenticate".**
    ///
    /// Probe accepted then signature rejected means the host *does* trust the
    /// key and the private key beside it is a different one — a local fault.
    /// Never accepted at all means the host declined it — a definite negative
    /// about that host. Collapsing them tells the user to go and fix the wrong
    /// machine.
    func testAnAcceptedProbeWithARejectedSignatureBlamesTheLocalKey() {
        let transcript = """
        debug1: Offering public key: /k ED25519 \(newRotationKey.fingerprint) explicit
        debug1: Server accepts key: /k ED25519 \(newRotationKey.fingerprint) explicit
        identity_sign: private key /k contents do not match public
        debug1: Offering public key: /o RSA \(oldRotationKey.fingerprint) explicit
        debug1: Server accepts key: /o RSA \(oldRotationKey.fingerprint) explicit
        Authenticated to web1 ([10.0.0.1]:22) using "publickey".
        """
        guard case .failed(let why) = outcome(out: ran, transcript: transcript) else {
            return XCTFail("a signature rejection is not a host declining the key")
        }
        XCTAssertTrue(why.contains("private key beside"), why)
    }

    func testAKeyTheHostNeverAcceptedIsRejectedNotBlamedLocally() {
        let transcript = """
        debug1: Offering public key: /k ED25519 \(newRotationKey.fingerprint) explicit
        debug1: Offering public key: /o RSA \(oldRotationKey.fingerprint) explicit
        debug1: Server accepts key: /o RSA \(oldRotationKey.fingerprint) explicit
        Authenticated to web1 ([10.0.0.1]:22) using "publickey".
        """
        XCTAssertEqual(outcome(out: ran, transcript: transcript),
                       .rejected("the host would not authenticate this key"))
    }

    /// Both keys offered, ours accepted last and authentication follows: ours.
    func testOurKeyAuthenticatingIsRecognised() {
        XCTAssertEqual(
            KeyRotator.authenticatingFingerprint(in: accepted(newRotationKey.fingerprint)),
            newRotationKey.fingerprint)
    }

    /// Authenticating by password proves the password works, not the key.
    func testAuthenticatingByPasswordIsNotAKeyAuthenticating() {
        let transcript = """
        debug1: Server accepts key: /k ED25519 \(newRotationKey.fingerprint) explicit
        Authenticated to web1 ([10.0.0.1]:22) using "password".
        """
        XCTAssertNil(KeyRotator.authenticatingFingerprint(in: transcript))
    }

    /// **Anchored, not searched.** ssh logs the command it is sending, so a
    /// `contains` test can be satisfied by text we handed it. Measured on a real
    /// host: a remote printing a fake accept line to its stderr never reaches
    /// the -E log, but the command echo does.
    func testTextInsideTheCommandEchoIsNotAnAcceptLine() {
        let forged = "SHA256:FORGEDfingerprintAAAAAAAAAAAAAAAAAAAAAAAA"
        let transcript = """
        debug1: Sending command: printf '%s' 'debug1: Server accepts key: /tmp/evil ED25519 \(forged) explicit'
        Authenticated to web1 ([10.0.0.1]:22) using "publickey".
        """
        XCTAssertNil(KeyRotator.authenticatingFingerprint(in: transcript),
                     "the command echo was read as an accept line")
        XCTAssertNotEqual(KeyRotator.authenticatingFingerprint(in: transcript), forged)
    }

    func testOfferedFingerprintsAreAnchoredToo() {
        let transcript = """
        debug1: Offering public key: /k ED25519 \(newRotationKey.fingerprint) explicit
        debug1: Sending command: echo Offering public key: fake MD5:aa
        """
        XCTAssertEqual(KeyRotator.offeredFingerprints(in: transcript),
                       [newRotationKey.fingerprint])
    }

    /// CRLF and LF must parse identically. Pinned because the difference is
    /// invisible to the eye and cost a real bug.
    func testCRLFAndLFTranscriptsParseTheSame() {
        let crlf = accepted(newRotationKey.fingerprint)
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(KeyRotator.authenticatingFingerprint(in: crlf),
                       KeyRotator.authenticatingFingerprint(in: lf))
        XCTAssertEqual(KeyRotator.authenticatingFingerprint(in: crlf),
                       newRotationKey.fingerprint)
    }

    /// **The trap-1 defence.** A multiplexed connection runs the command and
    /// authenticates nothing, so there is no `Server accepts key` line — and no
    /// `Offering public key` line either, which is what distinguishes it from a
    /// host that simply said no.
    func testAMultiplexedSessionIsNotAPass() {
        let muxed = "debug1: mux_client_request_session: entering\r\n"
        let result = outcome(out: ran, err: muxed)
        XCTAssertFalse(result.provesKeyWorks)
        guard case .failed(let why) = result else {
            return XCTFail("expected .failed, got \(result.label)")
        }
        XCTAssertTrue(why.contains("multiplexed"), "the reason should name the cause: \(why)")
    }

    /// Authentication worked but the host could not run a command — a login
    /// shell that dies, a `ForceCommand`, a full disk. The key may be fine, but
    /// this is not the moment to delete the one that still works.
    func testAcceptedButNoSessionIsNotAPass() {
        let result = outcome(out: "", err: accepted(newRotationKey.fingerprint))
        XCTAssertNotEqual(result, .verified)
    }

    /// The expected answer before the key has been added, and it must read as a
    /// plain fact rather than an error.
    func testAHostThatDeclinesTheKeyIsRejectedNotFailed() {
        let denied = "tim@web1: Permission denied (publickey).\n"
        XCTAssertEqual(outcome(out: "", err: denied, status: 255),
                       .rejected("the host would not authenticate this key"))
    }

    /// Without a fingerprint there is no way to say which key authenticated, so
    /// the only honest answer is that we don't know.
    func testNoFingerprintCannotBeAPass() {
        let result = outcome(out: ran, err: accepted("SHA256:whatever"), fingerprint: "")
        XCTAssertNotEqual(result, .verified)
        XCTAssertFalse(result.provesKeyWorks)
    }

    /// Only `.verified` unlocks a retirement — not merely "didn't fail".
    func testOnlyVerifiedProvesTheKeyWorks() {
        XCTAssertTrue(KeyVerifyOutcome.verified.provesKeyWorks)
        XCTAssertFalse(KeyVerifyOutcome.rejected("x").provesKeyWorks)
        XCTAssertFalse(KeyVerifyOutcome.failed("x").provesKeyWorks)
        XCTAssertFalse(KeyVerifyOutcome.skipped("x").provesKeyWorks)
    }

    /// A verify sends no password under any circumstances.
    func testVerifySendsNoPasswordAndNoStdin() async {
        let recorder = ArgumentRecorder()
        _ = await KeyRotator.verify(key: newRotationKey, on: rotationHost("web1"),
                                    runner: recorder.runner)
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].stdin, "", "a verify must never send a password")
        XCTAssertNil(calls[0].environment, "no askpass environment for a key-only check")
    }
}

/// Records what a runner was asked to do.
private actor ArgumentRecorder {
    struct Call {
        let args: [String]
        let environment: [String]?
        let stdin: String
    }
    private(set) var calls: [Call] = []

    func record(_ args: [String], _ environment: [String]?, _ stdin: String) {
        calls.append(Call(args: args, environment: environment, stdin: stdin))
    }

    nonisolated var runner: KeyDistributor.Runner {
        { _, args, environment, stdin in
            await self.record(args, environment, stdin)
            return (0, "", "")
        }
    }
}

// MARK: - The gate

final class KeyRotationGateTests: XCTestCase {

    private let hosts = [rotationHost("web1"), rotationHost("web2"), rotationHost("db1")]

    private func rotation() -> KeyRotation {
        KeyRotation(hosts: hosts, newKey: newRotationKey, oldKey: oldRotationKey)
    }

    /// The rule, stated as a test: a successful push earns nothing.
    func testAPushSucceedingDoesNotPermitRetirement() {
        var r = rotation()
        for host in hosts { r.record(KeyPushOutcome.added, forHost: host.id) }
        XCTAssertTrue(r.retirable.isEmpty,
                      "an appended line is not evidence that sshd will authenticate with it")
        XCTAssertNotNil(r.retirementBlocker)
    }

    func testOnlyAVerifiedHostBecomesRetirable() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        r.record(KeyVerifyOutcome.rejected("no"), forHost: hosts[1].id)
        r.record(KeyVerifyOutcome.failed("unknown"), forHost: hosts[2].id)

        XCTAssertEqual(r.retirable.map(\.name), ["web1"])
        XCTAssertTrue(r.canRetire(hostID: hosts[0].id))
        XCTAssertFalse(r.canRetire(hostID: hosts[1].id))
        XCTAssertFalse(r.canRetire(hostID: hosts[2].id))
    }

    /// Re-verifying a host that has since broken must *withdraw* permission, not
    /// leave the earlier pass standing.
    func testAFailedReverifyWithdrawsPermission() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        XCTAssertTrue(r.canRetire(hostID: hosts[0].id))

        r.record(KeyVerifyOutcome.failed("host rebuilt"), forHost: hosts[0].id)
        XCTAssertFalse(r.canRetire(hostID: hosts[0].id),
                       "an earlier pass must not outlive a later failure")
    }

    /// Rotating a key to itself would delete what was just installed.
    func testRotatingAKeyToItselfIsRefused() {
        var r = KeyRotation(hosts: hosts, newKey: newRotationKey, oldKey: newRotationKey)
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        XCTAssertTrue(r.retirable.isEmpty)
        XCTAssertEqual(r.retirementBlocker,
                       "The old and new keys are the same key — there is nothing to rotate.")
    }

    /// Same key under a different comment is still the same key: `authorized_keys`
    /// authenticates on type and blob.
    func testTheSameKeyWithADifferentCommentIsStillTheSameKey() {
        var renamed = newRotationKey
        renamed = PublicKey(path: "/tmp/other.pub", line: newRotationKey.line,
                            algorithm: newRotationKey.algorithm, blob: newRotationKey.blob,
                            comment: "someone@else", fingerprint: newRotationKey.fingerprint,
                            bits: 256)
        var r = KeyRotation(hosts: hosts, newKey: newRotationKey, oldKey: renamed)
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        XCTAssertTrue(r.retirable.isEmpty, "a comment edit does not make it a different key")
    }

    func testNoOldKeyMeansNothingToRetire() {
        var r = KeyRotation(hosts: hosts, newKey: newRotationKey, oldKey: nil)
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        XCTAssertTrue(r.retirable.isEmpty)
        XCTAssertEqual(r.retirementBlocker, "Choose the key you want to retire.")
    }

    /// **A failed retirement must stay retryable.** Any result at all used to
    /// remove a host from the pending list, so one timeout meant starting the
    /// whole rotation over.
    func testAFailedRetirementCanBeRetried() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        r.record(KeyRetireOutcome.failed("connection reset"), forHost: hosts[0].id)
        XCTAssertEqual(r.awaitingRetirement.map(\.name), ["web1"],
                       "a failure must not drop the host from the retire targets")
    }

    /// Refusal is the host's own guard firing; the operator fixes the cause and
    /// tries again.
    func testARefusedRetirementCanBeRetried() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        r.record(KeyRetireOutcome.refused("the new key is not active"), forHost: hosts[0].id)
        XCTAssertEqual(r.awaitingRetirement.map(\.name), ["web1"])
    }

    /// **Stop was the worst case.** It marks every remaining host skipped, which
    /// emptied the retire targets for the rest of the sheet's life.
    func testStoppingMidRunLeavesTheRestRetryable() {
        var r = rotation()
        for host in hosts { r.record(KeyVerifyOutcome.verified, forHost: host.id) }
        r.record(KeyRetireOutcome.removed(1), forHost: hosts[0].id)
        for host in hosts.dropFirst() {
            r.record(KeyRetireOutcome.skipped("cancelled"), forHost: host.id)
        }
        XCTAssertEqual(r.awaitingRetirement.map(\.name), ["web2", "db1"],
                       "cancelling must not permanently drop the hosts it skipped")
    }

    /// A host already retired drops out of the pending list but keeps its
    /// permission, so re-running is a no-op rather than an error.
    func testARetiredHostLeavesTheAwaitingList() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        XCTAssertEqual(r.awaitingRetirement.map(\.name), ["web1"])
        r.record(KeyRetireOutcome.removed(1), forHost: hosts[0].id)
        XCTAssertTrue(r.awaitingRetirement.isEmpty)
        XCTAssertTrue(r.canRetire(hostID: hosts[0].id))
        XCTAssertEqual(r.retiredCount, 1)
    }

    /// Worth surfacing: verified without the push having reported success
    /// usually means the key arrived by another route.
    func testVerifiedWithoutASuccessfulPushIsReported() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        r.record(KeyPushOutcome.failed("timeout"), forHost: hosts[0].id)
        XCTAssertEqual(r.verifiedWithoutSuccessfulPush.map(\.name), ["web1"])

        r.record(KeyPushOutcome.added, forHost: hosts[0].id)
        XCTAssertTrue(r.verifiedWithoutSuccessfulPush.isEmpty)
    }

    // MARK: - Retargeting, which is what the sheet does when you tick a host

    /// Ticking another host must not throw away what the others proved — that
    /// would make the sheet unusable, since the host list is edited constantly.
    func testRetargetingKeepsWhatSurvivingHostsProved() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)
        r.record(KeyPushOutcome.added, forHost: hosts[0].id)

        let moved = r.retargeted(to: hosts)
        XCTAssertTrue(moved.canRetire(hostID: hosts[0].id))
        XCTAssertEqual(moved.addedCount, 1)
    }

    /// A host dropped from the selection takes its results with it, so
    /// re-adding it later cannot resurrect a stale proof.
    func testRetargetingDropsResultsForHostsNoLongerSelected() {
        var r = rotation()
        r.record(KeyVerifyOutcome.verified, forHost: hosts[0].id)

        let without = r.retargeted(to: [hosts[1], hosts[2]])
        XCTAssertTrue(without.retirable.isEmpty)

        let backAgain = without.retargeted(to: hosts)
        XCTAssertFalse(backAgain.canRetire(hostID: hosts[0].id),
                       "a proof must not survive the host leaving and returning")
    }

    /// Changing a key is not expressible as a retarget — the keys are `let`, so
    /// a different key is a different `KeyRotation` and starts with nothing.
    /// This is the mechanism behind "verified in this session".
    func testANewRotationForADifferentKeyStartsWithNoProofs() {
        var r = rotation()
        for host in hosts { r.record(KeyVerifyOutcome.verified, forHost: host.id) }
        XCTAssertEqual(r.retirable.count, 3)

        let other = PublicKey(path: "/tmp/third.pub", line: "ssh-ed25519 AAAATHIRD t@n",
                              algorithm: "ssh-ed25519", blob: "AAAATHIRD", comment: "t@n",
                              fingerprint: "SHA256:third", bits: 256)
        let fresh = KeyRotation(hosts: r.hosts, newKey: other, oldKey: r.oldKey)
        XCTAssertTrue(fresh.retirable.isEmpty,
                      "a proof about one key says nothing about another")
    }

    // MARK: - The gate and the operation must describe the same thing

    /// **The fourth route through the invariant.** The sheet let keys, account
    /// and host selection change while work was in flight, and a progress
    /// callback from the superseded run reassigned the rotation it had
    /// captured — putting verifications for a *different* key back into the
    /// gate while the pickers said something else.
    ///
    /// Checked on the model so it is testable at all; the view additionally
    /// disables the controls and drops stale callbacks by generation.
    func testARotationKnowsWhenTheConfigurationHasMovedOn() {
        let r = rotation()
        XCTAssertTrue(r.matches(newKey: newRotationKey, oldKey: oldRotationKey,
                                account: "", hosts: hosts))

        let third = PublicKey(path: "/tmp/third.pub", line: "ssh-ed25519 AAAATHIRD t@n",
                              algorithm: "ssh-ed25519", blob: "AAAATHIRD", comment: "t@n",
                              fingerprint: "SHA256:third", bits: 256)
        XCTAssertFalse(r.matches(newKey: third, oldKey: oldRotationKey,
                                 account: "", hosts: hosts), "new key changed")
        XCTAssertFalse(r.matches(newKey: newRotationKey, oldKey: third,
                                 account: "", hosts: hosts), "old key changed")
        XCTAssertFalse(r.matches(newKey: newRotationKey, oldKey: oldRotationKey,
                                 account: "svc_goose", hosts: hosts), "account changed")
        XCTAssertFalse(r.matches(newKey: newRotationKey, oldKey: oldRotationKey,
                                 account: "", hosts: Array(hosts.dropLast())),
                       "host selection changed")
    }

    /// Host *order* is identity here, because the confirmation lists hosts in
    /// order and the operation walks them in order.
    func testHostOrderIsPartOfTheConfiguration() {
        let r = rotation()
        XCTAssertFalse(r.matches(newKey: newRotationKey, oldKey: oldRotationKey,
                                 account: "", hosts: hosts.reversed()))
    }

    /// Whitespace around an account name is not a change.
    func testSurroundingWhitespaceIsNotAConfigurationChange() {
        let r = KeyRotation(hosts: hosts, newKey: newRotationKey,
                            oldKey: oldRotationKey, account: "svc_goose")
        XCTAssertTrue(r.matches(newKey: newRotationKey, oldKey: oldRotationKey,
                                account: "  svc_goose  ", hosts: hosts))
    }

    func testBlockerNamesVerifyWhenNothingHasVerified() {
        let r = rotation()
        XCTAssertEqual(r.retirementBlocker,
                       "No host has proved the new key works yet. Verify first.")
    }
}

// MARK: - Local readiness

final class KeyRotatorReadinessTests: XCTestCase {

    /// `ssh-keygen -y` prints the public key derived from the private one.
    /// What it prints is the whole point of the check now — exit status alone
    /// says only that the file was readable.
    private func runner(keygen: Int32, derived: String = "", agentList: String = "")
        -> KeyDistributor.Runner {
        { executable, _, _, _ in
            if executable.hasSuffix("ssh-keygen") { return (keygen, derived, "") }
            return (0, agentList, "")
        }
    }

    private var matching: String {
        "\(newRotationKey.algorithm) \(newRotationKey.blob)"
    }

    func testAKeyWhoseDerivedPublicKeyMatchesIsReady() async {
        let r = await KeyRotator.readiness(of: newRotationKey, fileExists: { _ in true },
                                           runner: runner(keygen: 0, derived: matching))
        XCTAssertEqual(r, .ready)
    }

    /// `ssh-keygen -y` succeeds whenever it can read the private key and says
    /// nothing about the `.pub` beside it. A stale or swapped `.pub` therefore
    /// passed, and the failure surfaced much later and in the wrong place: the
    /// server accepts the probe for the advertised key, signing fails because
    /// the private key is a different one, and every host reports "key not
    /// accepted" for a fault that is entirely local. Reproduced on a fixture
    /// host before this check existed.
    func testAPrivateKeyThatDoesNotMatchItsPubIsCaughtLocally() async {
        let other = "\(oldRotationKey.algorithm) \(oldRotationKey.blob)"
        let r = await KeyRotator.readiness(of: newRotationKey, fileExists: { _ in true },
                                           runner: runner(keygen: 0, derived: other))
        guard case .mismatched(let why) = r else {
            return XCTFail("a mismatched pair must not be ready — got \(r)")
        }
        XCTAssertTrue(why.contains("different key"), why)
        XCTAssertFalse(r.isReady)
    }

    /// The comment differs between a `.pub` on disk and what `-y` derives, so
    /// identity must be type plus blob and nothing else.
    func testTheCommentIsIgnoredWhenComparing() async {
        let derivedWithoutComment = "\(newRotationKey.algorithm) \(newRotationKey.blob)"
        let r = await KeyRotator.readiness(of: newRotationKey, fileExists: { _ in true },
                                           runner: runner(keygen: 0, derived: derivedWithoutComment))
        XCTAssertEqual(r, .ready, "ssh-keygen -y emits no comment; that is not a mismatch")
    }

    func testUnreadableKeygenOutputIsNotSilentlyAccepted() async {
        let r = await KeyRotator.readiness(of: newRotationKey, fileExists: { _ in true },
                                           runner: runner(keygen: 0, derived: "not a key at all"))
        XCTAssertFalse(r.isReady)
    }

    /// An encrypted key already in the agent is usable, and is matched by
    /// fingerprint because `ssh-add -l` lists comments, not paths.
    func testAnEncryptedKeyLoadedInTheAgentIsReady() async {
        let listed = "256 \(newRotationKey.fingerprint) tim@newton (ED25519)\n"
        let r = await KeyRotator.readiness(of: newRotationKey, fileExists: { _ in true },
                                           runner: runner(keygen: 1, agentList: listed))
        XCTAssertEqual(r, .ready)
    }

    /// The case worth catching before touching forty hosts: a local problem
    /// that would otherwise report as forty rejections.
    func testAnEncryptedKeyNotInTheAgentIsLocked() async {
        let r = await KeyRotator.readiness(of: newRotationKey, fileExists: { _ in true },
                                           runner: runner(keygen: 1, agentList: "no identities"))
        XCTAssertFalse(r.isReady)
        XCTAssertTrue(r.problem?.contains("ssh-add") ?? false,
                      "the message should say how to fix it: \(r.problem ?? "nil")")
    }

    func testAMissingPrivateKeyIsNamed() async {
        let r = await KeyRotator.readiness(of: newRotationKey, fileExists: { _ in false },
                                           runner: runner(keygen: 0, derived: matching))
        guard case .missing(let why) = r else { return XCTFail("expected .missing, got \(r)") }
        XCTAssertTrue(why.contains("/tmp/portside-new"), "should name the path: \(why)")
    }

    func testThePrivateKeyIsThePubWithoutTheSuffix() {
        XCTAssertEqual(KeyRotator.privateKeyPath(for: newRotationKey), "/tmp/portside-new")
        let noSuffix = PublicKey(path: "/tmp/k", line: "l", algorithm: "ssh-ed25519",
                                blob: "b", comment: "", fingerprint: "f", bits: nil)
        XCTAssertEqual(KeyRotator.privateKeyPath(for: noSuffix), "/tmp/k")
    }
}

// MARK: - Retire outcomes

final class KeyRotatorRetireOutcomeTests: XCTestCase {

    private let nonce = "n1"

    private func outcome(_ out: String, _ err: String = "", status: Int32 = 0) -> KeyRetireOutcome {
        KeyRotator.retireOutcome(status: status, out: out, err: err, nonce: nonce)
    }

    func testRemovedCarriesTheCount() {
        XCTAssertEqual(outcome("\(KeyRotator.retireMarker)\(nonce) removed 2\n"), .removed(2))
    }

    func testAbsentIsASuccessNotAFailure() {
        XCTAssertEqual(outcome("\(KeyRotator.retireMarker)\(nonce) absent 0\n"), .notPresent)
        XCTAssertTrue(KeyRetireOutcome.notPresent.isSuccess)
    }

    /// The host's own guard firing is the safety rule working, and must not read
    /// as a malfunction — the host is untouched.
    func testTheHostsRefusalIsItsOwnOutcome() {
        let err = "portside: the new key is not active in /home/tim/.ssh/authorized_keys; "
            + "refusing to remove the old one\n"
        let result = outcome("", err, status: 3)
        guard case .refused(let why) = result else { return XCTFail("expected .refused, got \(result)") }
        XCTAssertTrue(why.contains("refusing to remove"))
        XCTAssertFalse(why.hasPrefix("portside: "), "the prefix is noise in a UI row")
    }

    func testASelfRepairIsReportedAsAFailureThatSaysWhatItDid() {
        let err = "portside: the rewrite lost the new key, so /home/tim/.ssh/authorized_keys "
            + "was restored from the backup\n"
        let result = outcome("", err, status: 4)
        guard case .failed(let why) = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertTrue(why.contains("restored from the backup"))
    }

    func testAMissingBackupIsReportedAsChangingNothing() {
        let err = "portside: could not back up /home/tim/.ssh/authorized_keys; "
            + "nothing was changed\n"
        guard case .failed(let why) = outcome("", err, status: 1) else {
            return XCTFail("expected .failed")
        }
        XCTAssertTrue(why.contains("nothing was changed"))
    }

    /// A marker carrying someone else's nonce is not this run's result.
    func testAForeignNonceIsNotBelieved() {
        let result = outcome("\(KeyRotator.retireMarker)otherNonce removed 1\n")
        XCTAssertFalse(result.isSuccess)
    }

    func testSudoRefusalIsNamedInSudosOwnWords() {
        guard case .failed(let why) = outcome("", "sudo: a password is required\n", status: 1) else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(why, "sudo: a password is required")
    }
}
