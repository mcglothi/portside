import Foundation
import XCTest
@testable import Portside

/// The retire script aimed at *another account*, executed for real.
///
/// Stub binaries on `PATH` are what make this testable at all: a fake `sudo`
/// that execs the rest proves two layers of quoting survive, a fake `getent`
/// points the script at a home we control, and a fake `chown` records instead of
/// acting — the only way to assert ownership repair without being root.
///
/// This mirrors `KeyDistributorSudoExecutionTests`, because the retire path
/// reuses the same locate-and-claim machinery and inherits the same risks: the
/// one real-host finding from the push work was that a service account's
/// `~/.ssh` can belong to a **non-default group**, so an unconditional
/// `chown "$u:$u"` would silently move it.
final class KeyRotatorSudoTests: XCTestCase {

    private var home: URL!
    private var bin: URL!
    private var chownLog: URL!

    private let oldKey = PublicKey(
        path: "/tmp/old.pub", line: "ssh-rsa AAAAB3OLDBLOB tim@oldmac",
        algorithm: "ssh-rsa", blob: "AAAAB3OLDBLOB", comment: "tim@oldmac",
        fingerprint: "SHA256:old", bits: 4096)

    private let newKey = PublicKey(
        path: "/tmp/new.pub", line: "ssh-ed25519 AAAAC3NEWBLOB tim@newton",
        algorithm: "ssh-ed25519", blob: "AAAAC3NEWBLOB", comment: "tim@newton",
        fingerprint: "SHA256:new", bits: 256)

    private let nonce = "n0nce4rotate"
    private let account = "svc_goose"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-rotate-sudo-\(UUID().uuidString)")
        bin = home.appendingPathComponent("bin")
        chownLog = home.appendingPathComponent("chown.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        // Swallows sudo's own flags, drains the password, execs the rest.
        try """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          case "$1" in
            -S|-H) shift ;;
            -p) shift 2 ;;
            -u) shift 2 ;;
            *) break ;;
          esac
        done
        cat > /dev/null &
        exec "$@"
        """.write(to: bin.appendingPathComponent("sudo"), atomically: true, encoding: .utf8)

        // A passwd database naming the home this test can write to.
        try "#!/bin/sh\necho '\(account):x:900:900::\(home.path):/bin/sh'\n"
            .write(to: bin.appendingPathComponent("getent"), atomically: true, encoding: .utf8)

        // Records what would have been chowned, rather than acting.
        try "#!/bin/sh\necho \"$@\" >> \(chownLog.path)\nexit 0\n"
            .write(to: bin.appendingPathComponent("chown"), atomically: true, encoding: .utf8)

        for tool in ["sudo", "getent", "chown"] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(tool).path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var sshDir: URL { home.appendingPathComponent(".ssh") }
    private var authorizedKeys: URL { sshDir.appendingPathComponent("authorized_keys") }

    private func seed(_ contents: String) throws {
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        try contents.write(to: authorizedKeys, atomically: true, encoding: .utf8)
    }

    private func contents() throws -> String {
        try String(contentsOf: authorizedKeys, encoding: .utf8)
    }

    private func chownCalls() -> [String] {
        guard let log = try? String(contentsOf: chownLog, encoding: .utf8) else { return [] }
        return log.split(separator: "\n").map(String.init)
    }

    private struct Run {
        let out: String
        let err: String
        let outcome: KeyRetireOutcome
    }

    /// Runs the full wrapped command — `sudo`, base64, and the script — through
    /// a real shell, the way the host would.
    @discardableResult
    private func runWrapped(account: String? = nil) throws -> Run {
        let command = KeyRotator.retireCommand(
            removing: oldKey, keeping: newKey, nonce: nonce, account: account ?? self.account)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin"]
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.closeFile()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Run(out: o, err: e,
                   outcome: KeyRotator.retireOutcome(status: process.terminationStatus,
                                                     out: o, err: e, nonce: nonce))
    }

    // MARK: - The wrapped script reaches the host intact

    /// Two layers of quoting — the sudo wrapper around a script that is itself
    /// full of single-quoted paths and key lines. Base64 is what makes that safe,
    /// and executing it is what proves the claim.
    func testTheWrappedScriptRunsAndRetiresTheOldKey() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        let result = try runWrapped()
        XCTAssertEqual(result.outcome, .removed(1),
                       "outcome \(result.outcome) — err: \(result.err)")
        XCTAssertFalse(try contents().contains(oldKey.blob))
        XCTAssertTrue(try contents().contains(newKey.blob))
    }

    /// The home comes from the passwd database, not from `$HOME` and not from a
    /// guess at `/home/<account>`. Proven by pointing `getent` somewhere
    /// unexpected and seeing the script follow.
    func testTheAccountsHomeComesFromPasswdRatherThanAGuess() throws {
        let elsewhere = home.appendingPathComponent("unexpected-home")
        try FileManager.default.createDirectory(
            at: elsewhere.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try "\(oldKey.line)\n\(newKey.line)\n".write(
            to: elsewhere.appendingPathComponent(".ssh/authorized_keys"),
            atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho '\(account):x:900:900::\(elsewhere.path):/bin/sh'\n"
            .write(to: bin.appendingPathComponent("getent"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("getent").path)

        XCTAssertEqual(try runWrapped().outcome, .removed(1))
        let rewritten = try String(
            contentsOf: elsewhere.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8)
        XCTAssertFalse(rewritten.contains(oldKey.blob),
                       "the script did not follow the home passwd gave it")
    }

    /// An account that isn't in the passwd database is named, not reported as an
    /// exit code.
    func testAnUnknownAccountIsNamed() throws {
        try "#!/bin/sh\nexit 2\n"
            .write(to: bin.appendingPathComponent("getent"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("getent").path)

        let result = try runWrapped(account: "svc_definitely_not_a_user")
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertTrue(result.err.contains("unknown user svc_definitely_not_a_user"),
                      "stderr should name the account: \(result.err)")
    }

    // MARK: - Ownership

    /// Root writing a backup into someone's `~/.ssh` leaves it root-owned. The
    /// backup is the one file this script creates, so it is the one that needs
    /// claiming.
    func testTheBackupIsHandedToTheAccount() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        try runWrapped()

        let claimed = chownCalls()
        XCTAssertTrue(claimed.contains { $0.contains("authorized_keys\(KeyDistributor.backupSuffix)") },
                      "the backup was left owned by root: \(claimed)")
    }

    /// **The real-host finding, pinned.** `~svc_goose/.ssh` was owned
    /// `svc_goose:ai_agents` on a live host and survived a push unchanged. The
    /// group must never be forced, so the chown is `"$u:"` — which asks for the
    /// user's *login* group only when the file is being created by us, and here
    /// applies solely to the backup.
    func testOwnershipNeverForcesAGroup() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        try runWrapped()

        for call in chownCalls() {
            XCTAssertFalse(call.contains("\(account):\(account)"),
                           "an explicit group would move a non-default one: \(call)")
        }
    }

    /// Nothing the script did not create is re-owned. The `authorized_keys`
    /// file itself already existed, so it must not appear in the chown log.
    func testAnExistingAuthorizedKeysIsNotReowned() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        try runWrapped()

        for call in chownCalls() {
            XCTAssertFalse(call.hasSuffix("/authorized_keys"),
                           "an existing file's ownership is not ours to change: \(call)")
        }
    }

    // MARK: - Injection

    /// An account name is interpolated into a script that is then base64'd into
    /// a sudo command. The honest test is not "the dangerous substring is
    /// absent" — correctly escaped input still contains its own characters —
    /// but that running it has no effect.
    func testAMaliciousAccountNameExecutesNothing() throws {
        let canary = home.appendingPathComponent("PWNED")
        try seed("\(oldKey.line)\n\(newKey.line)\n")

        _ = try runWrapped(account: "svc'; touch \(canary.path); echo '")

        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path),
                       "the account name escaped its quoting and executed")
    }

    /// The same for a key comment, which is attacker-influenced in the sense
    /// that it can come from a `.pub` file someone was sent.
    func testAKeyCommentCannotEscapeIntoTheShell() throws {
        let canary = home.appendingPathComponent("PWNED-COMMENT")
        let nasty = PublicKey(
            path: "/tmp/nasty.pub",
            line: "ssh-rsa AAAAB3OLDBLOB '; touch \(canary.path); echo '",
            algorithm: "ssh-rsa", blob: "AAAAB3OLDBLOB",
            comment: "'; touch \(canary.path); echo '",
            fingerprint: "SHA256:old", bits: 4096)
        try seed("\(nasty.line)\n\(newKey.line)\n")

        let command = KeyRotator.retireCommand(removing: nasty, keeping: newKey,
                                               nonce: nonce, account: account)
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
                       "a key comment escaped its quoting and executed")
    }

    // MARK: - The guard still applies under sudo

    /// Escalating to root does not waive the rule. This is the most dangerous
    /// combination in the feature — root, rewriting someone else's
    /// `authorized_keys` — so the check has to hold here above all.
    func testTheGuardStillRefusesWhenRunningAsRoot() throws {
        let original = "\(oldKey.line)\n"
        try seed(original)

        let result = try runWrapped()
        guard case .refused = result.outcome else {
            return XCTFail("expected .refused, got \(result.outcome) — err: \(result.err)")
        }
        XCTAssertEqual(try contents(), original, "the file was rewritten anyway")
    }

    // MARK: - No account

    /// With no account there is no sudo, no getent and no chown — the script is
    /// handed over as itself.
    func testWithoutAnAccountNothingEscalates() {
        let command = KeyRotator.retireCommand(removing: oldKey, keeping: newKey, nonce: nonce)
        XCTAssertFalse(command.contains("sudo"))
        XCTAssertFalse(command.contains("getent"))
        XCTAssertFalse(command.contains("base64"))
        XCTAssertEqual(command,
                       KeyRotator.retireScript(removing: oldKey, keeping: newKey, nonce: nonce))
    }
}
