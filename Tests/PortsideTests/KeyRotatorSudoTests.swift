import Foundation
import XCTest
@testable import Portside

/// The retire script aimed at *another account*, executed for real.
///
/// Stub binaries on `PATH` make this testable without actually changing users:
/// fake `sudo` records the direct hop and execs the target-account script, while
/// fake `chown` proves the removed root phase never returns.
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

        // Present so its absence from the generated script is meaningful.
        try "#!/bin/sh\necho \"$@\" >> \(chownLog.path)\nexit 0\n"
            .write(to: bin.appendingPathComponent("chown"), atomically: true, encoding: .utf8)

        for tool in ["sudo", "chown"] {
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

    /// One escalation goes straight to the account; root never writes inside a
    /// directory controlled by that account.
    func testEscalationGoesDirectlyToTheAccountAndNeverViaRoot() {
        let command = KeyRotator.retireCommand(
            removing: oldKey, keeping: newKey, nonce: nonce, account: account)
        XCTAssertTrue(command.contains("sudo -S -p '' -H -u \(account)"), command)
        XCTAssertEqual(command.components(separatedBy: "sudo ").count - 1, 1)
    }

    func testTheScriptResolvesNothingAndIsIdenticalForAnAccount() {
        let targeted = KeyRotator.retireScript(
            removing: oldKey, keeping: newKey, nonce: nonce, account: account)
        let plain = KeyRotator.retireScript(
            removing: oldKey, keeping: newKey, nonce: nonce)
        XCTAssertEqual(targeted, plain)
        XCTAssertTrue(targeted.contains(#"h="$HOME""#))
        for gone in ["getent", "/etc/passwd", "chown", "sudo"] {
            XCTAssertFalse(targeted.contains(gone), "\(gone) belongs to the removed root phase")
        }
    }

    // MARK: - Ownership

    /// Files created by the account already have the right owner; nothing is
    /// repaired afterward with root.
    func testNothingIsEverChowned() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        try runWrapped()

        XCTAssertTrue(chownCalls().isEmpty, "something was chowned: \(chownCalls())")
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

    // MARK: - The guard still applies under direct account execution

    /// Changing users does not waive the new-key guard.
    func testTheGuardStillRefusesForATargetAccount() throws {
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
