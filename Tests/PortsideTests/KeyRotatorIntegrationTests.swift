import Foundation
import XCTest
@testable import Portside

/// Drives a **whole rotation against real hosts**: push a throwaway key, prove
/// the host authenticates it, retire it again, and check the file afterwards.
///
/// **Opt-in.** Skipped unless `PORTSIDE_ITEST_HOSTS` names hosts.
///
/// ```sh
/// PORTSIDE_ITEST_HOSTS=turing,hopper swift test --filter KeyRotatorIntegration
/// ```
///
/// ## Why this has to run against a real sshd
///
/// The verify phase reads `ssh -v`'s `Server accepts key:` line to establish
/// *which* key authenticated. Nothing about that can be tested with a fake: the
/// format is OpenSSH's, the decision is the server's, and the specific hazard —
/// `~/.ssh/config` supplying an `IdentityFile` that `IdentitiesOnly=yes` still
/// permits — only exists on a host reached through a real config file. Every
/// host in the maintainer's library is aliased, so that hazard is the norm here
/// rather than a corner case.
///
/// ## Why it is safe to run
///
/// It rotates a **throwaway key it generates itself**, and the key it "keeps" is
/// the one the test is already authenticating with — so the worst case is a
/// leftover throwaway grant, which teardown removes whether or not the
/// assertions passed. It never retires a key the user relies on, and it never
/// touches another account.
final class KeyRotatorIntegrationTests: XCTestCase {

    private var hosts: [String] = []
    private var scratch: URL!
    /// The throwaway key generated for this run — the one being rotated.
    private var throwaway: PublicKey!
    /// The key the test itself logs in with, and therefore the one that must
    /// survive every retirement below.
    private var keeper: PublicKey!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["PORTSIDE_ITEST_HOSTS"], !list.isEmpty else {
            throw XCTSkip("set PORTSIDE_ITEST_HOSTS to run integration tests")
        }
        hosts = list.split(separator: ",").map(String.init)

        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-rotate-itest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        throwaway = try await generateKey(named: "rotate_throwaway")
        keeper = try await loadKeeper()
    }

    override func tearDownWithError() throws {
        if let throwaway { removeEverywhere(throwaway) }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Keys

    private func generateKey(named name: String) async throws -> PublicKey {
        let path = scratch.appendingPathComponent(name)
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-t", "ed25519", "-f", path.path, "-N", "", "-q",
                            "-C", "portside-rotation-itest"]
        keygen.standardOutput = Pipe()
        keygen.standardError = Pipe()
        try keygen.run()
        keygen.waitUntilExit()
        XCTAssertEqual(keygen.terminationStatus, 0, "ssh-keygen failed")

        let pub = path.appendingPathExtension("pub")
        let loaded = await PublicKeyLocator.load(path: pub.path)
        return try XCTUnwrap(loaded, "could not read the generated key")
    }

    /// The key this test authenticates with, taken from whatever the hosts
    /// already accept. It is loaded only so its blob can be asserted present
    /// after every rewrite.
    private func loadKeeper() async throws -> PublicKey {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["PORTSIDE_ITEST_KEEP_KEY"], "~/.ssh/id_rsa.pub",
                          "~/.ssh/id_ed25519.pub"].compactMap { $0 }
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded),
               let key = await PublicKeyLocator.load(path: expanded) {
                return key
            }
        }
        throw XCTSkip("no local key to keep — set PORTSIDE_ITEST_KEEP_KEY")
    }


    // MARK: - Hosts

    private func entry(_ alias: String) -> SessionEntry {
        var e = SessionEntry(name: alias)
        e.kind = .host
        e.sshAlias = alias
        return e
    }

    @discardableResult
    private func remote(_ host: String, _ command: String) async throws -> String {
        let result = try await SFTPClient.runProcess(
            "/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command],
            stdin: "")
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activeCount(of key: PublicKey, on host: String) async throws -> String {
        try await remote(host,
            "awk -v b='\(key.blob)' '/^[[:space:]]*#/ {next} "
            + "{for (i=1;i<=NF;i++) if ($i==b) c++} END {print c+0}' ~/.ssh/authorized_keys")
    }

    /// Best-effort teardown: a leftover throwaway key is a real grant.
    private func removeEverywhere(_ key: PublicKey) {
        let group = DispatchGroup()
        for host in hosts {
            group.enter()
            Task {
                defer { group.leave() }
                _ = try? await self.remote(host, """
                f=~/.ssh/authorized_keys; \
                [ -f "$f" ] && grep -v '\(key.blob)' "$f" > "$f.itest" && cat "$f.itest" > "$f" \
                && rm -f "$f.itest"; rm -f "$f.portside-backup"; echo done
                """)
            }
        }
        _ = group.wait(timeout: .now() + 60)
    }

    // MARK: - The whole rotation

    /// Add, verify, retire — the three phases in order, against a real host.
    func testARotationAddsVerifiesAndRetiresOnRealHosts() async throws {
        for host in hosts {
            let target = entry(host)

            // Phase 1: add. This is KeyDistributor unchanged.
            let added = await KeyDistributor.push(key: throwaway, to: target, password: nil)
            XCTAssertTrue(added.keyEntryPresent, "\(host): push failed — \(added.label)")
            let installed = try await activeCount(of: throwaway, on: host)
            XCTAssertEqual(installed, "1",
                           "\(host): expected exactly one copy of the throwaway key")

            // Phase 2: verify. The real test — a real sshd deciding, and ssh
            // naming the key it accepted, through a real ~/.ssh/config that
            // supplies an IdentityFile of its own.
            let verified = await KeyRotator.verify(key: throwaway, on: target)
            XCTAssertEqual(verified, .verified,
                           "\(host): verify should pass — got \(verified.label)")

            // Phase 3: retire the throwaway, keeping the key we log in with.
            let retired = await KeyRotator.retire(oldKey: throwaway, keeping: keeper,
                                                  on: target, password: nil)
            XCTAssertEqual(retired, .removed(1),
                           "\(host): retire should remove one entry — got \(retired.label)")

            let retiredCount = try await activeCount(of: throwaway, on: host)
            XCTAssertEqual(retiredCount, "0", "\(host): the retired key is still active")
            let keptCount = try await activeCount(of: keeper, on: host)
            XCTAssertEqual(keptCount, "1",
                           "\(host): the key we kept was lost — this is the lockout case")

            // And still being able to log in proves it end to end.
            let reachable = try await remote(host, "echo still-here")
            XCTAssertEqual(reachable, "still-here", "\(host): lost access after retiring")
        }
    }

    /// A key the host does not have must come back as `rejected` — a plain fact,
    /// not an error, and above all not a pass.
    func testAKeyTheHostDoesNotHaveIsRejected() async throws {
        let stranger = try await generateKey(named: "never_installed")
        for host in hosts {
            let outcome = await KeyRotator.verify(key: stranger, on: entry(host))
            XCTAssertFalse(outcome.provesKeyWorks,
                           "\(host): an uninstalled key must never verify")
            guard case .rejected = outcome else {
                XCTFail("\(host): expected .rejected, got \(outcome.label)")
                continue
            }
        }
    }

    /// **Trap 1, against a real host.** With a live `ControlMaster` for the same
    /// destination, a connection that joined it would authenticate nothing and
    /// report success. `ControlPath=none` is what keeps the verify honest, and
    /// this proves it on the wire: the *uninstalled* key must still be rejected
    /// even though a working multiplexed session to that host exists.
    func testVerifyIgnoresALiveControlMaster() async throws {
        let stranger = try await generateKey(named: "never_installed_mux")
        let host = try XCTUnwrap(hosts.first)
        let controlPath = "/tmp/portside-itest-mux-%C"

        let master = Process()
        master.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        master.arguments = ["-M", "-N", "-f", "-o", "ControlPath=\(controlPath)",
                            "-o", "BatchMode=yes", host]
        master.standardOutput = Pipe()
        master.standardError = Pipe()
        try master.run()
        master.waitUntilExit()
        defer {
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            stop.arguments = ["-O", "exit", "-o", "ControlPath=\(controlPath)", host]
            stop.standardOutput = Pipe()
            stop.standardError = Pipe()
            try? stop.run()
            stop.waitUntilExit()
        }

        // Confirm the master really is up, or this proves nothing either.
        let check = try await SFTPClient.runProcess(
            "/usr/bin/ssh", ["-O", "check", "-o", "ControlPath=\(controlPath)", host], stdin: "")
        try XCTSkipUnless(check.err.contains("Master running") || check.out.contains("Master running"),
                          "could not establish a ControlMaster to test against")

        let outcome = await KeyRotator.verify(key: stranger, on: entry(host))
        XCTAssertFalse(outcome.provesKeyWorks,
                       "\(host): the verify rode the ControlMaster and proved nothing")
    }

    /// **The rule, against a real host.** With the new key *not* installed, the
    /// host must refuse to remove the old one and leave the file untouched —
    /// enforced on the host, not merely by the app declining to ask.
    func testTheHostRefusesToRetireWhenTheNewKeyIsAbsent() async throws {
        let absent = try await generateKey(named: "not_on_any_host")
        for host in hosts {
            let before = try await remote(host, "sha256sum ~/.ssh/authorized_keys | cut -d' ' -f1")

            // Ask it to remove the key we actually log in with, "keeping" a key
            // the host has never seen. The guard must stop this.
            let outcome = await KeyRotator.retire(oldKey: keeper, keeping: absent,
                                                  on: entry(host), password: nil)
            guard case .refused = outcome else {
                XCTFail("\(host): expected .refused, got \(outcome.label)")
                continue
            }

            let after = try await remote(host, "sha256sum ~/.ssh/authorized_keys | cut -d' ' -f1")
            XCTAssertEqual(after, before, "\(host): authorized_keys changed despite the refusal")
            let stillThere = try await activeCount(of: keeper, on: host)
            XCTAssertEqual(stillThere, "1", "\(host): the key we log in with was removed")
        }
    }

    /// Retiring a key the host doesn't have is a no-op, not a failure — and must
    /// not rewrite the file.
    func testRetiringAKeyTheHostDoesNotHaveChangesNothing() async throws {
        let stranger = try await generateKey(named: "not_present_anywhere")
        for host in hosts {
            let before = try await remote(host, "sha256sum ~/.ssh/authorized_keys | cut -d' ' -f1")
            let outcome = await KeyRotator.retire(oldKey: stranger, keeping: keeper,
                                                  on: entry(host), password: nil)
            XCTAssertEqual(outcome, .notPresent, "\(host): got \(outcome.label)")
            let after = try await remote(host, "sha256sum ~/.ssh/authorized_keys | cut -d' ' -f1")
            XCTAssertEqual(after, before, "\(host): the file was rewritten for nothing")
        }
    }

    /// The local preflight, against a real key on disk.
    func testReadinessRecognisesARealUnencryptedKey() async throws {
        let readiness = await KeyRotator.readiness(of: throwaway)
        XCTAssertEqual(readiness, .ready, "a freshly generated passphrase-less key should be ready")
    }
}
