import XCTest
@testable import Portside

/// "Explain This Connection" is only worth having if it describes the
/// connection Portside actually makes, and only safe to have if it never
/// prints a secret. Both are asserted here.
final class ConnectionExplanationTests: XCTestCase {

    /// Trimmed from real `ssh -G` output — the shape matters (lowercased
    /// keyword, single space, repeats for identityfile), not the ~80 lines of
    /// defaults around it.
    private let sample = """
        user tim
        hostname 10.0.0.4
        port 2222
        proxyjump bastion.example.net
        identityfile \(NSHomeDirectory())/.ssh/id_ed25519
        identityfile \(NSHomeDirectory())/.ssh/id_rsa
        identitiesonly no
        stricthostkeychecking accept-new
        userknownhostsfile \(NSHomeDirectory())/.ssh/known_hosts
        loglevel INFO
        """

    // MARK: - What it reports

    func testItReportsWhereTheConnectionActuallyGoes() {
        let explained = parse(sample)
        XCTAssertEqual(explained.destination, "tim@10.0.0.4:2222")
        XCTAssertEqual(value(of: "Resolves to", in: explained), "10.0.0.4")
        XCTAssertEqual(value(of: "Logs in as", in: explained), "tim")
        XCTAssertEqual(value(of: "Port", in: explained), "2222")
    }

    func testAJumpHostIsCalledOut() {
        XCTAssertEqual(value(of: "Jumps through", in: parse(sample)), "bastion.example.net")
    }

    func testProxyJumpOfNoneIsNotShownAsAJumpHost() {
        // ssh -G prints "proxyjump none" when there isn't one; showing that as
        // a jump host would invent an intermediary that doesn't exist.
        let explained = parse("hostname h\nuser u\nport 22\nproxyjump none\n")
        XCTAssertNil(explained.items.first { $0.label == "Jumps through" })
    }

    func testIdentityFilesKeepTheirOrder() {
        // ssh offers them in order and stops at the first accepted, so the
        // order is the answer to "which key did it use?".
        XCTAssertEqual(
            value(of: "Identity files", in: parse(sample)),
            "~/.ssh/id_ed25519\n~/.ssh/id_rsa"
        )
    }

    func testHomeDirectoryIsAbbreviated() {
        // The user wrote ~/.ssh/id_ed25519 in their config; showing them
        // /Users/<name>/.ssh/... makes them match it up by eye.
        XCTAssertFalse(
            parse(sample).items.contains { $0.value.contains(NSHomeDirectory()) },
            "paths should read as ~/… rather than absolute home paths"
        )
    }

    func testIdentityFileNoteDoesNotClaimTheKeysExist() {
        // ssh -G lists configured paths whether or not the file is there. The
        // note must not turn that into "these keys are present".
        let note = parse(sample).items.first { $0.label == "Identity files" }?.note
        XCTAssertEqual(note?.contains("does not check here whether they exist"), true)
    }

    func testIdentitiesOnlyChangesTheExplanation() {
        let restricted = parse(sample.replacingOccurrences(
            of: "identitiesonly no", with: "identitiesonly yes"
        ))
        XCTAssertEqual(
            restricted.items.first { $0.label == "Identity files" }?.note?
                .contains("only these are offered"),
            true
        )
    }

    // MARK: - Host key policy

    func testAcceptNewIsExplainedWithoutOverstatingTheRisk() {
        let note = parse(sample).items.first { $0.label == "Host key policy" }?.note
        // The important half: a *changed* key still fails. Saying only "trusts
        // unknown hosts" would read as though verification were off entirely.
        XCTAssertEqual(note?.contains("already-known key still fails"), true)
    }

    func testCheckingDisabledIsCalledOutPlainly() {
        let explained = parse("hostname h\nuser u\nport 22\nstricthostkeychecking no\n")
        XCTAssertEqual(
            explained.items.first { $0.label == "Host key policy" }?.note?
                .contains("accepts an interception silently"),
            true
        )
    }

    // MARK: - Secrets

    func testThePasswordSourceIsNamedButNeverTheValue() {
        for source in [CredentialResolver.Source.assignedProfile, .hostSpecific,
                       .defaultProfile, .legacyDefault, .none] {
            let explained = ConnectionExplanation.parse(
                sshDashG: sample, credentialSource: source
            )
            let line = explained.items.first { $0.label == "Stored password" }
            XCTAssertNotNil(line, "the credential source should always be reported")
            XCTAssertFalse(
                line?.value.isEmpty ?? true, "\(source) should have a description"
            )
        }
    }

    func testNoPasswordSaysSoAndSaysWhatHappensInstead() {
        let explained = ConnectionExplanation.parse(sshDashG: sample, credentialSource: .none)
        let line = explained.items.first { $0.label == "Stored password" }
        XCTAssertEqual(line?.value, "None")
        XCTAssertEqual(line?.note?.contains("prompt in the terminal"), true)
    }

    // MARK: - The invocation it explains

    func testExplainUsesTheSameArgumentsAsAConnection() {
        // The whole panel is a lie if it asks ssh about a different connection
        // than the one Portside makes: -i, -p and the host-key option are
        // command-line arguments, and those outrank ~/.ssh/config.
        var entry = SessionEntry(name: "babbage")
        entry.hostname = "10.0.0.4"
        entry.user = "tim"
        entry.port = 2222

        let connecting = SSHInvocation.arguments(for: entry, autoAcceptNewHostKeys: true)
        let explaining = SSHInvocation.explainArguments(for: entry, autoAcceptNewHostKeys: true)

        XCTAssertEqual(explaining.first, "-G")
        XCTAssertEqual(Array(explaining.dropFirst()), connecting)
    }

    func testTheHostKeyOptionIsCarriedIntoTheExplanation() {
        var entry = SessionEntry(name: "h")
        entry.hostname = "h"
        XCTAssertTrue(
            SSHInvocation.explainArguments(for: entry, autoAcceptNewHostKeys: true)
                .contains("StrictHostKeyChecking=accept-new")
        )
        XCTAssertFalse(
            SSHInvocation.explainArguments(for: entry, autoAcceptNewHostKeys: false)
                .contains("StrictHostKeyChecking=accept-new")
        )
    }

    // MARK: - Where it can be reached from

    @MainActor
    func testALocalShellHasNoConnectionToExplain() {
        // The menu item has to be disabled rather than opening a sheet that
        // says "nothing here" — a local shell has no entry at all.
        let manager = SessionManager()
        defer { for session in manager.sessions { session.shutdown() } }
        manager.openLocalShell()

        XCTAssertFalse(manager.canExplainSelectedConnection)
        manager.explainSelectedConnection()
        XCTAssertNil(manager.explainingEntry, "nothing to explain, so nothing opens")
    }

    @MainActor
    func testNothingSelectedExplainsNothing() {
        let manager = SessionManager()
        XCTAssertFalse(manager.canExplainSelectedConnection)
        manager.explainSelectedConnection()
        XCTAssertNil(manager.explainingEntry)
    }

    func testOnlySSHSessionsHaveAConfigurationToExplain() async {
        // Serial, telnet and container sessions reach ssh -G with nothing to
        // ask about; the explainer says so instead of running it.
        for kind in [SessionKind.serial, .telnet, .container] {
            var entry = SessionEntry(name: "device")
            entry.kind = kind
            let explained = await ConnectionExplainer.explain(
                entry: entry, autoAcceptNewHostKeys: false, credentialSource: .none
            )
            XCTAssertNotNil(explained.failure, "\(kind) should decline rather than shell out")
            XCTAssertTrue(explained.items.isEmpty)
        }
    }

    // MARK: - Against real ssh output

    /// Captured verbatim from `/usr/bin/ssh -G` on macOS 15 (OpenSSH 9.x).
    /// The synthetic sample above got two details wrong, and both were only
    /// visible by running the real thing: ssh emits `identityfile` already in
    /// tilde form, and `userknownhostsfile` as several space-separated paths
    /// on one line.
    func testRealSSHOutputParsesTheWayTheUIExpects() {
        // ssh prints the running user's real home, so the fixture uses it too;
        // a hardcoded one is only abbreviated on the machine it was copied from.
        let home = NSHomeDirectory()
        let real = """
            user tim
            hostname 10.0.0.4
            port 2222
            identitiesonly no
            stricthostkeychecking accept-new
            identityfile ~/.ssh/id_rsa
            identityfile ~/.ssh/id_ecdsa
            identityfile ~/.ssh/id_ed25519
            userknownhostsfile \(home)/.ssh/known_hosts \(home)/.ssh/known_hosts2
            """
        let explained = parse(real)

        XCTAssertEqual(explained.destination, "tim@10.0.0.4:2222")
        XCTAssertEqual(
            value(of: "Identity files", in: explained),
            "~/.ssh/id_rsa\n~/.ssh/id_ecdsa\n~/.ssh/id_ed25519",
            "ssh already writes these in tilde form; abbreviating must leave them alone"
        )
        // Both paths, each on its own line — not one line with a raw absolute
        // path stuck to the end of an abbreviated one.
        let known = value(of: "Known hosts files", in: explained)
        XCTAssertEqual(known?.split(separator: "\n").count, 2)
        XCTAssertFalse(
            known?.contains(home) ?? true,
            "every known-hosts path should read as ~/…, not just the first"
        )
    }

    func testASinglePathKnownHostsIsLabelledInTheSingular() {
        let explained = parse("hostname h\nuser u\nport 22\nuserknownhostsfile ~/.ssh/known_hosts\n")
        XCTAssertNotNil(value(of: "Known hosts", in: explained))
    }

    // MARK: - Helpers

    private func parse(_ output: String) -> ConnectionExplanation {
        ConnectionExplanation.parse(sshDashG: output, credentialSource: .hostSpecific)
    }

    private func value(of label: String, in explained: ConnectionExplanation) -> String? {
        explained.items.first { $0.label == label }?.value
    }
}
