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
