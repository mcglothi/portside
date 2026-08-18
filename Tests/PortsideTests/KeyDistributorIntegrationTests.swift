import Foundation
import XCTest
@testable import Portside

/// Drives `KeyDistributor` against **real hosts**, through the same
/// `defaultRunner` the app uses. Everything else in the suite injects a runner;
/// this is the only thing that proves the whole path — argument construction,
/// the remote script, sudo, and result parsing — against a real sshd.
///
/// **Opt-in.** Skipped unless `PORTSIDE_ITEST_HOSTS` names hosts, because it
/// contacts machines and, in the sudo cases, changes them. Run it with:
///
/// ```sh
/// PORTSIDE_ITEST_HOSTS=turing,hopper \
/// PORTSIDE_ITEST_KEY=~/.ssh/svc_goose.pub \
/// PORTSIDE_ITEST_ACCOUNT=svc_goose \
/// PORTSIDE_ITEST_SCRATCH_KEY=/path/to/throwaway.pub \
/// swift test --filter KeyDistributorIntegration
/// ```
///
/// It authenticates by key: `password` is passed as nil throughout, so ssh runs
/// under `BatchMode` and no credential is read, stored, or spent. That also
/// means `sudo -S` gets an empty stdin — which is deliberate, and is what makes
/// a host with password-required sudo a *test case* rather than a blocker.
///
/// **Nothing here deletes a home directory.** Bootstrapping into a missing home
/// is covered by `KeyDistributorBootstrapTests` with stubs, and was validated by
/// hand on a real host. A populated service-account home is not something a test
/// suite should be removing to prove a point.
final class KeyDistributorIntegrationTests: XCTestCase {

    private var hosts: [String] = []
    private var account = "svc_goose"

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let list = env["PORTSIDE_ITEST_HOSTS"], !list.isEmpty else {
            throw XCTSkip("set PORTSIDE_ITEST_HOSTS to run integration tests")
        }
        hosts = list.split(separator: ",").map(String.init)
        account = env["PORTSIDE_ITEST_ACCOUNT"] ?? "svc_goose"
    }

    // MARK: - Helpers

    private func entry(_ alias: String) -> SessionEntry {
        var e = SessionEntry(name: alias)
        e.kind = .host
        e.sshAlias = alias          // resolved through ~/.ssh/config, as the app does
        return e
    }

    private func loadKey(_ path: String) throws -> PublicKey {
        let expanded = (path as NSString).expandingTildeInPath
        let line = try XCTUnwrap(
            String(contentsOfFile: expanded, encoding: .utf8).split(separator: "\n").first)
        return try XCTUnwrap(
            PublicKey.parse(line: String(line), path: expanded, fingerprint: "", bits: nil))
    }

    private func keyUnderTest() throws -> PublicKey {
        try loadKey(ProcessInfo.processInfo.environment["PORTSIDE_ITEST_KEY"]
                    ?? "~/.ssh/\(account).pub")
    }

    private func scratchKey() throws -> PublicKey {
        try loadKey(try XCTUnwrap(ProcessInfo.processInfo.environment["PORTSIDE_ITEST_SCRATCH_KEY"],
                                  "PORTSIDE_ITEST_SCRATCH_KEY is required"))
    }

    /// Runs a command on the host over the same key auth the tests use.
    @discardableResult
    private func remote(_ host: String, _ command: String) async throws -> String {
        let result = try await SFTPClient.runProcess(
            "/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command],
            stdin: "")
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func push(_ key: PublicKey, to host: String,
                      account: String? = nil) async -> KeyPushOutcome {
        await KeyDistributor.push(key: key, to: entry(host), password: nil, account: account)
    }

    // MARK: - The login-user path, no sudo

    /// The common case, end to end and fully reversible: a throwaway key into
    /// the login user's own `authorized_keys`, then removed again.
    func testPushToTheLoginUserAddsThenReportsPresent() async throws {
        let key = try scratchKey()
        defer { removeScratchKeyEverywhere(key) }

        for host in hosts {
            let first = await push(key, to: host)
            XCTAssertEqual(first, .added, "\(host): first push should add — got \(first.label)")

            let installed = try await remote(host, "grep -c '\(key.blob)' ~/.ssh/authorized_keys")
            XCTAssertEqual(installed, "1", "\(host): expected exactly one copy")

            let second = await push(key, to: host)
            XCTAssertEqual(second, .alreadyPresent,
                           "\(host): re-push should be a no-op — got \(second.label)")

            let after = try await remote(host, "grep -c '\(key.blob)' ~/.ssh/authorized_keys")
            XCTAssertEqual(after, "1", "\(host): a re-push duplicated the key")
        }
    }

    /// Best-effort teardown. A leftover throwaway key is a real (if small)
    /// grant, so it is removed even when an assertion above has already failed.
    private func removeScratchKeyEverywhere(_ key: PublicKey) {
        let group = DispatchGroup()
        for host in hosts {
            group.enter()
            Task {
                defer { group.leave() }
                _ = try? await self.remote(host, """
                f=~/.ssh/authorized_keys; \
                [ -f "$f" ] && grep -v '\(key.blob)' "$f" > "$f.itest" && cat "$f.itest" > "$f" \
                && rm -f "$f.itest"; echo done
                """)
            }
        }
        _ = group.wait(timeout: .now() + 60)
    }

    // MARK: - The sudo path

    /// **The fleet case, with a mixed outcome by design.** One host has
    /// passwordless sudo and should succeed; one requires a password that this
    /// test deliberately does not supply and should fail. That is the property
    /// worth proving: a failure is reported, named, and does not stop the run.
    func testFleetPushWithSudoReportsPerHostAndSurvivesAFailure() async throws {
        let key = try keyUnderTest()
        let entries = hosts.map(entry)

        let results = await KeyDistributor.push(
            key: key, to: entries, password: { _ in nil }, account: account, progress: { _ in })

        XCTAssertEqual(results.count, hosts.count, "every host must be reported")
        XCTAssertEqual(results.map(\.hostName), hosts, "reported in the order given")

        for result in results {
            switch result.outcome {
            case .added, .alreadyPresent:
                // Verify the host really does trust it now, rather than
                // believing the marker.
                let count = try await remote(
                    result.hostName,
                    "sudo -n awk -v b='\(key.blob)' '{for(i=1;i<=NF;i++) if($i==b) n++} END{print n+0}' "
                    + "~\(account)/.ssh/authorized_keys 2>/dev/null || echo unknown")
                if count != "unknown" {
                    XCTAssertEqual(count, "1",
                                   "\(result.hostName): expected exactly one copy, got \(count)")
                }
            case .failed(let why):
                // A failure has to say something useful. "exited with status 1"
                // is what this test exists to prevent.
                XCTAssertFalse(why.isEmpty, "\(result.hostName): empty failure reason")
                XCTAssertFalse(why.contains("exited with status"),
                               "\(result.hostName): unhelpful failure — \(why)")
                print("ITEST \(result.hostName) failed as expected: \(why)")
            case .skipped(let why):
                XCTFail("\(result.hostName): unexpectedly skipped — \(why)")
            }
        }

        XCTAssertTrue(results.contains { $0.outcome.keyEntryPresent },
                      "at least one host should have succeeded")
    }

    /// **Ownership of things we did not create must not change.** On a real
    /// host `~svc_goose/.ssh` can belong to a non-default group; re-owning it
    /// to the account's login group would be a silent, unasked-for change.
    func testAnExistingSSHDirectoryKeepsItsOwnership() async throws {
        let key = try keyUnderTest()
        var before: [String: String] = [:]
        for host in hosts {
            before[host] = try await remote(
                host, "sudo -n stat -c '%U:%G %a' ~\(account)/.ssh 2>/dev/null || echo unknown")
        }

        _ = await KeyDistributor.push(
            key: key, to: hosts.map(entry), password: { _ in nil },
            account: account, progress: { _ in })

        for host in hosts where before[host] != "unknown" {
            let after = try await remote(
                host, "sudo -n stat -c '%U:%G %a' ~\(account)/.ssh 2>/dev/null || echo unknown")
            XCTAssertEqual(after, before[host],
                           "\(host): an existing ~/.ssh had its ownership or mode changed")
        }
    }

    /// **The privilege drop, exercised end to end.** The other sudo cases here
    /// push a key the account already has, so they prove the *check* runs after
    /// dropping but never the write. This installs a throwaway key into the
    /// account's `authorized_keys` and removes it again.
    ///
    /// It is the only test that can show the drop works at all: `sudo -n -u`
    /// inside an already-root context cannot be reproduced with stubs, and if it
    /// failed on a real host the whole cross-account feature would be dead.
    func testAThrowawayKeyIsWrittenIntoTheAccountAfterDroppingPrivileges() async throws {
        let key = try scratchKey()
        // Only hosts whose sudo we can actually use without a password.
        var exercised = false
        for host in hosts {
            let probe = try? await remote(host, "sudo -n true 2>/dev/null && echo yes || echo no")
            guard probe == "yes" else { continue }
            exercised = true

            defer {
                let group = DispatchGroup()
                group.enter()
                Task {
                    defer { group.leave() }
                    _ = try? await self.remote(host, """
                    sudo -n sh -c 'f=~\(self.account)/.ssh/authorized_keys; \
                    [ -f "$f" ] && grep -v '"'"'\(key.blob)'"'"' "$f" > "$f.itest" \
                    && cat "$f.itest" > "$f" && rm -f "$f.itest"'; echo done
                    """)
                }
                _ = group.wait(timeout: .now() + 30)
            }

            let before = try await remote(
                host, "sudo -n stat -c '%U:%G %a' ~\(account)/.ssh 2>/dev/null || echo unknown")

            let outcome = await push(key, to: host, account: account)
            XCTAssertEqual(outcome, .added, "\(host): \(outcome.label)")

            let count = try await remote(
                host,
                "sudo -n awk -v t='\(key.algorithm)' -v b='\(key.blob)' "
                + "'{for (i=1;i<NF;i++) if ($i==t && $(i+1)==b) n++} END{print n+0}' "
                + "~\(account)/.ssh/authorized_keys")
            XCTAssertEqual(count, "1", "\(host): the key was not written under the drop")

            // The file the account created must belong to the account, with no
            // chown involved — that is the whole point of dropping first.
            let owner = try await remote(
                host, "sudo -n stat -c '%U' ~\(account)/.ssh/authorized_keys")
            XCTAssertEqual(owner, account, "\(host): authorized_keys is owned by \(owner)")

            let after = try await remote(
                host, "sudo -n stat -c '%U:%G %a' ~\(account)/.ssh 2>/dev/null || echo unknown")
            XCTAssertEqual(after, before, "\(host): ~/.ssh ownership or mode changed")
        }
        try XCTSkipUnless(exercised, "no host with passwordless sudo to test the drop against")
    }

    /// A typo must be a sentence, not a mystery — and must write nothing.
    func testAnUnknownAccountFailsWithItsName() async throws {
        let key = try keyUnderTest()
        for host in hosts {
            let outcome = await push(key, to: host, account: "svc_definitely_not_a_user")
            XCTAssertFalse(outcome.isSuccess, "\(host): a bogus account must not succeed")
            if case .failed(let why) = outcome {
                print("ITEST \(host) unknown-account: \(why)")
            }
        }
    }
}
