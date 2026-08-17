import Foundation
import XCTest
@testable import Portside

/// Runs the *generated* retire script against a throwaway `HOME`, under every
/// `sh` this Mac has.
///
/// This is the suite that earns its place. The push script's three worst bugs —
/// a `$HOME` that never expanded inside single quotes so no backup was ever
/// written, an append that welded a key onto a file with no trailing newline,
/// and an edit that left the remote command missing entirely — were all
/// invisible to reading and to mocks, and all three fell out of executing it.
/// A script that *deletes* lines from `authorized_keys` deserves more of that
/// treatment, not less.
///
/// No network, no host, no ssh: a temp directory and the real script.
final class KeyRotatorScriptTests: XCTestCase {

    private var home: URL!

    private let oldKey = PublicKey(
        path: "/tmp/old.pub",
        line: "ssh-rsa AAAAB3OLDBLOB tim@oldmac",
        algorithm: "ssh-rsa", blob: "AAAAB3OLDBLOB", comment: "tim@oldmac",
        fingerprint: "SHA256:old", bits: 4096)

    private let newKey = PublicKey(
        path: "/tmp/new.pub",
        line: "ssh-ed25519 AAAAC3NEWBLOB tim@newton",
        algorithm: "ssh-ed25519", blob: "AAAAC3NEWBLOB", comment: "tim@newton",
        fingerprint: "SHA256:new", bits: 256)

    private let nonce = "testnonce"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-rotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Harness

    /// Remote hosts run `dash` as `/bin/sh` far more often than bash, so
    /// "sh-portable" is only a claim if it is executed under both.
    static var shells: [String] {
        ["/bin/sh", "/bin/dash", "/bin/bash"].filter {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private var sshDir: URL { home.appendingPathComponent(".ssh") }
    private var authorizedKeys: URL { sshDir.appendingPathComponent("authorized_keys") }
    private var backup: URL {
        sshDir.appendingPathComponent("authorized_keys\(KeyDistributor.backupSuffix)")
    }

    private struct Run {
        let out: String
        let err: String
        let status: Int32
        var outcome: KeyRetireOutcome
    }

    @discardableResult
    private func runScript(shell: String = "/bin/sh", home overrideHome: URL? = nil) throws -> Run {
        let root = overrideHome ?? home!
        let script = home.appendingPathComponent("retire.sh")
        try KeyRotator.retireScript(removing: oldKey, keeping: newKey, nonce: nonce)
            .write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [script.path]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let o = String(decoding: outData, as: UTF8.self)
        let e = String(decoding: errData, as: UTF8.self)
        return Run(out: o, err: e, status: process.terminationStatus,
                   outcome: KeyRotator.retireOutcome(status: process.terminationStatus,
                                                     out: o, err: e, nonce: nonce))
    }

    private func seed(_ contents: String, at url: URL? = nil) throws {
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let target = url ?? authorizedKeys
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    private func contents(_ url: URL? = nil) throws -> String {
        try String(contentsOf: url ?? authorizedKeys, encoding: .utf8)
    }

    private func attribute(_ url: URL, _ key: FileAttributeKey) throws -> NSNumber? {
        try FileManager.default.attributesOfItem(atPath: url.path)[key] as? NSNumber
    }

    // MARK: - The happy path

    func testRemovesTheOldKeyAndKeepsEverythingElse() throws {
        let other = "ssh-ed25519 AAAASOMEONEELSE colleague@laptop"
        try seed("\(oldKey.line)\n\(newKey.line)\n\(other)\n")

        let result = try runScript()
        XCTAssertEqual(result.outcome, .removed(1))

        let after = try contents()
        XCTAssertFalse(after.contains(oldKey.blob), "the old key survived")
        XCTAssertTrue(after.contains(newKey.blob), "the new key was removed")
        XCTAssertTrue(after.contains(other), "an unrelated key was removed")
    }

    /// The backup is the difference between a bad edit being a nuisance and
    /// being a trip to a console.
    func testTheBackupIsTheFileAsItWasBeforeTheRewrite() throws {
        let original = "\(oldKey.line)\n\(newKey.line)\n"
        try seed(original)
        try runScript()
        XCTAssertEqual(try contents(backup), original,
                       "the backup must be the pre-rewrite file, byte for byte")
    }

    func testEveryCopyOfTheOldKeyGoesAndTheCountIsReported() throws {
        try seed("""
        \(oldKey.line)
        \(newKey.line)
        \(oldKey.algorithm) \(oldKey.blob) a-different-comment
        """ + "\n")
        let result = try runScript()
        XCTAssertEqual(result.outcome, .removed(2), "both entries for the old key should go")
        XCTAssertFalse(try contents().contains(oldKey.blob))
    }

    /// The old key carrying `command=`/`from=` options is still the old key —
    /// its algorithm is no longer the first field, which is why the check walks
    /// fields rather than anchoring.
    func testAnEntryWithOptionsIsStillMatched() throws {
        try seed("""
        command="/usr/bin/backup",no-pty \(oldKey.algorithm) \(oldKey.blob) restricted
        \(newKey.line)
        """ + "\n")
        XCTAssertEqual(try runScript().outcome, .removed(1))
        XCTAssertFalse(try contents().contains(oldKey.blob))
    }

    // MARK: - The guard

    /// **The rule, enforced on the host.** Without the new key active in the
    /// file, nothing is removed — whatever the app believed when it asked.
    func testRefusesAndChangesNothingWhenTheNewKeyIsAbsent() throws {
        let original = "\(oldKey.line)\nssh-ed25519 AAAAUNRELATED someone@else\n"
        try seed(original)

        let result = try runScript()
        guard case .refused = result.outcome else {
            return XCTFail("expected .refused, got \(result.outcome) — err: \(result.err)")
        }
        XCTAssertEqual(try contents(), original, "the file must be untouched after a refusal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "a refusal should not even write a backup")
    }

    /// A *commented-out* new key grants nothing, so it must not satisfy the
    /// guard — the same rule the append path uses when deciding a key isn't
    /// installed.
    func testACommentedOutNewKeyDoesNotSatisfyTheGuard() throws {
        try seed("\(oldKey.line)\n# \(newKey.line)\n")
        guard case .refused = try runScript().outcome else {
            return XCTFail("a commented-out new key must not authorise a removal")
        }
        XCTAssertTrue(try contents().contains(oldKey.blob))
    }

    /// A commented-out *old* key grants nothing either, so it is left alone
    /// rather than tidied away — someone's annotations are not ours to delete.
    func testCommentLinesArePreservedIncludingACommentedOldKey() throws {
        let commented = "# retired 2026-08: \(oldKey.line)"
        try seed("""
        # my authorized_keys
        \(commented)
        \(oldKey.line)
        \(newKey.line)
        """ + "\n")
        XCTAssertEqual(try runScript().outcome, .removed(1),
                       "only the active entry should count")
        let after = try contents()
        XCTAssertTrue(after.contains("# my authorized_keys"), "a comment was dropped")
        XCTAssertTrue(after.contains(commented), "a commented-out old key should be left alone")
        // The active line is gone: the blob now appears only inside comments.
        for line in after.split(separator: "\n") where line.contains(oldKey.blob) {
            XCTAssertTrue(line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                          "an active old-key entry survived: \(line)")
        }
    }

    // MARK: - Nothing to do

    func testAMissingFileIsReportedAsAbsentRatherThanFailing() throws {
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        XCTAssertEqual(try runScript().outcome, .notPresent)
    }

    func testAHostWithoutTheOldKeyIsAbsentAndKeepsItsFileUntouched() throws {
        let original = "\(newKey.line)\n"
        try seed(original)
        XCTAssertEqual(try runScript().outcome, .notPresent)
        XCTAssertEqual(try contents(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "nothing was rewritten, so nothing needed backing up")
    }

    /// Running twice must be a no-op the second time rather than an error.
    func testRetiringTwiceIsIdempotent() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        XCTAssertEqual(try runScript().outcome, .removed(1))
        XCTAssertEqual(try runScript().outcome, .notPresent)
    }

    // MARK: - Field equality, not substring

    /// A blob that *contains* the old key's blob is a different key. `grep -F`
    /// would remove it too and take away access the user never asked to lose.
    ///
    /// The real old key has to be in the file as well, or the count comes out
    /// zero, the script exits early as `absent`, and the rewrite this is about
    /// never runs — an earlier version of this test passed under a deliberately
    /// substring-matching script for exactly that reason.
    func testAKeyWhoseBlobContainsTheOldBlobSurvivesTheRewrite() throws {
        let lookalike = "ssh-rsa \(oldKey.blob)EXTRA colleague@laptop"
        try seed("\(oldKey.line)\n\(lookalike)\n\(newKey.line)\n")

        XCTAssertEqual(try runScript().outcome, .removed(1),
                       "only the exact old key should count")
        let after = try contents()
        XCTAssertTrue(after.contains(lookalike),
                      "a longer blob that merely starts with the old one is a different key")
        XCTAssertTrue(after.contains(newKey.blob))
        XCTAssertEqual(after.split(separator: "\n").count, 2)
    }

    /// The mirror image: a blob the old one contains. Removing by substring in
    /// the other direction would leave the old key in place while deleting a
    /// shorter, unrelated one.
    func testAKeyContainedByTheOldBlobSurvivesTheRewrite() throws {
        let shorter = "ssh-rsa AAAAB3OLD colleague@laptop"
        try seed("\(oldKey.line)\n\(shorter)\n\(newKey.line)\n")

        XCTAssertEqual(try runScript().outcome, .removed(1))
        let after = try contents()
        XCTAssertTrue(after.contains(shorter), "a shorter unrelated blob was removed")
        XCTAssertFalse(after.contains("\(oldKey.blob) "), "the old key survived")
    }

    // MARK: - File shapes found in the wild

    /// Written by hand, or by something that didn't bother with a final newline.
    func testAFileWithNoTrailingNewlineIsHandled() throws {
        try seed("\(oldKey.line)\n\(newKey.line)")
        XCTAssertEqual(try runScript().outcome, .removed(1))
        let after = try contents()
        XCTAssertTrue(after.contains(newKey.blob))
        XCTAssertFalse(after.contains(oldKey.blob))
    }

    /// Edited on Windows, or copied through something that converted endings.
    func testCRLFLineEndingsAreHandled() throws {
        try seed("\(oldKey.line)\r\n\(newKey.line)\r\n")
        XCTAssertEqual(try runScript().outcome, .removed(1))
        XCTAssertFalse(try contents().contains(oldKey.blob))
        XCTAssertTrue(try contents().contains(newKey.blob))
    }

    /// The remote `awk` treats tabs as separators; a `.pub` file written with
    /// them must not slip past the check. The two ends have to agree on what a
    /// field is — they disagreed once already, in the push path.
    func testTabSeparatedFieldsAreMatched() throws {
        try seed("\(oldKey.algorithm)\t\(oldKey.blob)\ttim@oldmac\n\(newKey.line)\n")
        XCTAssertEqual(try runScript().outcome, .removed(1))
        XCTAssertFalse(try contents().contains(oldKey.blob))
    }

    func testBlankLinesSurvive() throws {
        try seed("\(oldKey.line)\n\n\(newKey.line)\n\n")
        XCTAssertEqual(try runScript().outcome, .removed(1))
        XCTAssertTrue(try contents().contains("\n\n"), "blank lines were collapsed")
    }

    func testAHomeDirectoryWithSpacesWorks() throws {
        let spaced = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside rotate \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spaced) }
        let keys = spaced.appendingPathComponent(".ssh/authorized_keys")
        try FileManager.default.createDirectory(at: keys.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "\(oldKey.line)\n\(newKey.line)\n".write(to: keys, atomically: true, encoding: .utf8)

        XCTAssertEqual(try runScript(home: spaced).outcome, .removed(1))
        XCTAssertFalse(try contents(keys).contains(oldKey.blob))
    }

    func testALargeAuthorizedKeysFileIsRewrittenCorrectly() throws {
        var lines = (0..<500).map { "ssh-ed25519 AAAAFILLER\($0) filler\($0)@host" }
        lines.insert(oldKey.line, at: 250)
        lines.append(newKey.line)
        try seed(lines.joined(separator: "\n") + "\n")

        XCTAssertEqual(try runScript().outcome, .removed(1))
        let after = try contents().split(separator: "\n")
        XCTAssertEqual(after.count, 501, "exactly one line should have gone")
        XCTAssertFalse(after.contains { $0.contains(oldKey.blob) })
    }

    // MARK: - Preserving what we did not create

    /// `cat` into the original rather than `mv` over it: a rename would replace
    /// the inode and hand the file this script's ownership and permissions.
    func testTheRewriteKeepsTheOriginalInodeAndPermissions() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o640],
                                             ofItemAtPath: authorizedKeys.path)
        let inodeBefore = try attribute(authorizedKeys, .systemFileNumber)

        XCTAssertEqual(try runScript().outcome, .removed(1))

        XCTAssertEqual(try attribute(authorizedKeys, .systemFileNumber), inodeBefore,
                       "the file was replaced rather than rewritten in place")
        XCTAssertEqual(try attribute(authorizedKeys, .posixPermissions)?.intValue, 0o640,
                       "an existing file's permissions are the user's business")
    }

    /// A symlinked `authorized_keys` is followed, not replaced — the same
    /// behaviour the push path has, and the reason `cat >` is used.
    func testASymlinkedAuthorizedKeysIsFollowed() throws {
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let real = home.appendingPathComponent("real_keys")
        try "\(oldKey.line)\n\(newKey.line)\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: authorizedKeys, withDestinationURL: real)

        XCTAssertEqual(try runScript().outcome, .removed(1))

        let info = try FileManager.default.attributesOfItem(atPath: authorizedKeys.path)
        XCTAssertEqual(info[.type] as? FileAttributeType, .typeSymbolicLink,
                       "the symlink was replaced with a regular file")
        XCTAssertFalse(try contents(real).contains(oldKey.blob),
                       "the rewrite did not reach the file the link points at")
    }

    /// The temp file the rewrite goes through must not be left behind in
    /// `~/.ssh`, where anything unexpected invites suspicion.
    func testNoTemporaryFileIsLeftBehind() throws {
        try seed("\(oldKey.line)\n\(newKey.line)\n")
        try runScript()
        let left = try FileManager.default.contentsOfDirectory(atPath: sshDir.path)
        XCTAssertFalse(left.contains { $0.contains("portside-rewrite") },
                       "a scratch file survived: \(left)")
    }

    // MARK: - When it cannot proceed

    /// An unwritable file must fail *before* destroying anything, and say so.
    func testAnUnwritableDirectoryFailsWithoutLosingTheOriginal() throws {
        let original = "\(oldKey.line)\n\(newKey.line)\n"
        try seed(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                             ofItemAtPath: sshDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: sshDir.path)
        }

        let result = try runScript()
        XCTAssertFalse(result.outcome.isSuccess)
        XCTAssertEqual(try contents(), original,
                       "the original must survive a failure to back it up")
    }

    // MARK: - Every shell

    /// The whole claim is that this is sh-portable. Running the core case under
    /// each shell present is what makes that a claim rather than a hope — and
    /// `dash` is what most remote hosts actually use for `/bin/sh`.
    func testTheScriptBehavesIdenticallyUnderEveryShell() throws {
        XCTAssertFalse(Self.shells.isEmpty, "no shell to test with")
        for shell in Self.shells {
            try? FileManager.default.removeItem(at: sshDir)
            try seed("\(oldKey.line)\n\(newKey.line)\nssh-ed25519 AAAAKEEP me@here\n")

            let result = try runScript(shell: shell)
            XCTAssertEqual(result.outcome, .removed(1),
                           "\(shell): \(result.outcome) — err: \(result.err)")
            let after = try contents()
            XCTAssertFalse(after.contains(oldKey.blob), "\(shell): old key survived")
            XCTAssertTrue(after.contains(newKey.blob), "\(shell): new key lost")
            XCTAssertTrue(after.contains("AAAAKEEP"), "\(shell): unrelated key lost")
        }
    }

    func testTheGuardHoldsUnderEveryShell() throws {
        for shell in Self.shells {
            try? FileManager.default.removeItem(at: sshDir)
            let original = "\(oldKey.line)\n"
            try seed(original)

            let result = try runScript(shell: shell)
            guard case .refused = result.outcome else {
                XCTFail("\(shell): expected .refused, got \(result.outcome)")
                continue
            }
            XCTAssertEqual(try contents(), original, "\(shell): the file was touched anyway")
        }
    }
}
