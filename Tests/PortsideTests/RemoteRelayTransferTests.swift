import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Portside

/// Host-to-host copy relays through a local staging file. These cover the
/// decisions that happen around the two transfers — where the file lands, when
/// the relay is refused, and whether the staging file survives a failure —
/// without needing two live SSH hosts.
final class RemoteRelayTransferTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEntry(name: String, kind: SessionKind = .host) -> SessionEntry {
        SessionEntry(name: name, hostname: "\(name).example.internal", kind: kind)
    }

    private func makeSource(
        entry: SessionEntry, path: String = "/var/log/app.log", name: String = "app.log"
    ) -> RemoteRelayTransfer.Source {
        RemoteRelayTransfer.Source(entry: entry, remotePath: path, name: name, size: 1_024)
    }

    private func file(_ name: String) -> RemoteFile {
        RemoteFile(
            name: name, isDirectory: false, isSymlink: false,
            size: 10, dateText: "", permissions: "-rw-r--r--"
        )
    }

    /// Operations that record what they were asked to do and succeed.
    private final class Recorder: @unchecked Sendable {
        var downloaded: [(String, URL)] = []
        var uploaded: [(URL, String)] = []
        var listed: [String] = []
        var pwdCalls = 0
        var downloadBody: ((URL) throws -> Void)?
        var uploadShouldFail = false

        func operations(listing: [RemoteFile] = []) -> RemoteRelayTransfer.Operations {
            RemoteRelayTransfer.Operations(
                pwd: { _ in self.pwdCalls += 1; return "/home/deploy" },
                list: { _, path in self.listed.append(path); return listing },
                download: { _, remote, url in
                    self.downloaded.append((remote, url))
                    // Materialise a file so staging cleanup is observable.
                    try self.downloadBody?(url)
                        ?? Data("payload".utf8).write(to: url)
                },
                upload: { _, url, dir in
                    if self.uploadShouldFail {
                        throw SFTPClientError.failed("upload refused")
                    }
                    self.uploaded.append((url, dir))
                }
            )
        }
    }

    // MARK: - Destination resolution

    /// The point of dropping on a particular pane is that the file lands where
    /// that shell is standing.
    func testResolvesToTheShellsReportedDirectory() async throws {
        let recorder = Recorder()
        let dir = try await RemoteRelayTransfer.resolveDirectory(
            sessionCurrentDirectory: "/srv/www",
            entry: makeEntry(name: "web-01"),
            operations: recorder.operations()
        )
        XCTAssertEqual(dir, "/srv/www")
        XCTAssertEqual(recorder.pwdCalls, 0, "no need to ask sftp when OSC 7 already told us")
    }

    /// A shell without the integration installed reports nothing. That must
    /// degrade to the SFTP default, not refuse the drop.
    func testFallsBackToPwdWhenShellReportsNothing() async throws {
        let recorder = Recorder()
        let dir = try await RemoteRelayTransfer.resolveDirectory(
            sessionCurrentDirectory: nil,
            entry: makeEntry(name: "web-01"),
            operations: recorder.operations()
        )
        XCTAssertEqual(dir, "/home/deploy")
        XCTAssertEqual(recorder.pwdCalls, 1)
    }

    func testEmptyReportedDirectoryIsTreatedAsAbsent() async throws {
        let recorder = Recorder()
        let dir = try await RemoteRelayTransfer.resolveDirectory(
            sessionCurrentDirectory: "",
            entry: makeEntry(name: "web-01"),
            operations: recorder.operations()
        )
        XCTAssertEqual(dir, "/home/deploy")
    }

    // MARK: - Preflight

    func testRefusesCopyingAFileOntoItself() {
        let entry = makeEntry(name: "web-01")
        XCTAssertThrowsError(
            try RemoteRelayTransfer.preflight(
                source: makeSource(entry: entry),
                destination: .init(entry: entry, directory: "/var/log"),
                existingNames: []
            )
        ) { error in
            XCTAssertEqual(error as? RemoteRelayTransfer.Failure, .sameLocation)
        }
    }

    /// Trailing slashes are not a real difference.
    func testSameLocationIgnoresTrailingSlash() {
        let entry = makeEntry(name: "web-01")
        XCTAssertThrowsError(
            try RemoteRelayTransfer.preflight(
                source: makeSource(entry: entry),
                destination: .init(entry: entry, directory: "/var/log/"),
                existingNames: []
            )
        )
    }

    /// Two panes on the *same* host in different directories is an ordinary
    /// way to move a file. Allowing it is deliberate.
    func testSameHostDifferentDirectoryIsAllowed() throws {
        let entry = makeEntry(name: "web-01")
        try RemoteRelayTransfer.preflight(
            source: makeSource(entry: entry),
            destination: .init(entry: entry, directory: "/tmp"),
            existingNames: []
        )
    }

    /// Consistent with the drag-in upload fix: never silently overwrite.
    func testRefusesNameCollision() {
        XCTAssertThrowsError(
            try RemoteRelayTransfer.preflight(
                source: makeSource(entry: makeEntry(name: "web-01")),
                destination: .init(entry: makeEntry(name: "db-01"), directory: "/tmp"),
                existingNames: ["app.log"]
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteRelayTransfer.Failure, .nameCollision("app.log")
            )
        }
    }

    func testRefusesDestinationWithoutAFileBrowser() {
        // A container session has no SFTP endpoint to talk to.
        let local = makeEntry(name: "app-container", kind: .container)
        XCTAssertThrowsError(
            try RemoteRelayTransfer.preflight(
                source: makeSource(entry: makeEntry(name: "web-01")),
                destination: .init(entry: local, directory: "/tmp"),
                existingNames: []
            )
        ) { error in
            guard case .unsupportedDestination = error as? RemoteRelayTransfer.Failure else {
                return XCTFail("expected unsupportedDestination, got \(error)")
            }
        }
    }

    func testAllowsAnOrdinaryHostToHostCopy() throws {
        try RemoteRelayTransfer.preflight(
            source: makeSource(entry: makeEntry(name: "web-01")),
            destination: .init(entry: makeEntry(name: "db-01"), directory: "/tmp"),
            existingNames: ["something-else.txt"]
        )
    }

    // MARK: - Execution

    func testRelayDownloadsThenUploadsAndReportsPhases() async throws {
        let recorder = Recorder()
        let phases = PhaseLog()
        try await RemoteRelayTransfer.run(
            source: makeSource(entry: makeEntry(name: "web-01")),
            destination: .init(entry: makeEntry(name: "db-01"), directory: "/srv/incoming"),
            operations: recorder.operations(),
            onPhase: { phases.record($0) }
        )

        XCTAssertEqual(recorder.downloaded.count, 1)
        XCTAssertEqual(recorder.downloaded.first?.0, "/var/log/app.log")
        XCTAssertEqual(recorder.uploaded.count, 1)
        XCTAssertEqual(recorder.uploaded.first?.1, "/srv/incoming")
        XCTAssertEqual(phases.recorded, [.downloading, .uploading, .finished])
    }

    /// The staged file keeps the source's name so it arrives at the
    /// destination correctly — `sftp put` takes the basename from the local
    /// file when no destination name is given.
    func testStagedFileKeepsTheSourceName() async throws {
        let recorder = Recorder()
        try await RemoteRelayTransfer.run(
            source: makeSource(entry: makeEntry(name: "web-01")),
            destination: .init(entry: makeEntry(name: "db-01"), directory: "/tmp"),
            operations: recorder.operations()
        )
        XCTAssertEqual(recorder.uploaded.first?.0.lastPathComponent, "app.log")
    }

    func testStagingDirectoryIsRemovedAfterSuccess() async throws {
        let recorder = Recorder()
        try await RemoteRelayTransfer.run(
            source: makeSource(entry: makeEntry(name: "web-01")),
            destination: .init(entry: makeEntry(name: "db-01"), directory: "/tmp"),
            operations: recorder.operations()
        )
        let staged = try XCTUnwrap(recorder.uploaded.first?.0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path),
            "staging directory outlived a successful relay"
        )
    }

    /// The failure path is the one that leaves litter if it is wrong.
    func testStagingDirectoryIsRemovedAfterAFailedUpload() async throws {
        let recorder = Recorder()
        recorder.uploadShouldFail = true
        do {
            try await RemoteRelayTransfer.run(
                source: makeSource(entry: makeEntry(name: "web-01")),
                destination: .init(entry: makeEntry(name: "db-01"), directory: "/tmp"),
                operations: recorder.operations()
            )
            XCTFail("expected the upload to throw")
        } catch {
            // expected
        }
        let staged = try XCTUnwrap(recorder.downloaded.first?.1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path),
            "staging directory outlived a failed relay"
        )
    }

    func testCollisionIsCheckedBeforeAnythingIsTransferred() async throws {
        let recorder = Recorder()
        do {
            try await RemoteRelayTransfer.run(
                source: makeSource(entry: makeEntry(name: "web-01")),
                destination: .init(entry: makeEntry(name: "db-01"), directory: "/tmp"),
                operations: recorder.operations(listing: [file("app.log")])
            )
            XCTFail("expected a collision")
        } catch {
            XCTAssertEqual(
                error as? RemoteRelayTransfer.Failure, .nameCollision("app.log")
            )
        }
        XCTAssertTrue(
            recorder.downloaded.isEmpty,
            "a doomed relay should not pull the file down first"
        )
    }

    func testStagingDirectoriesAreUniquePerTransfer() throws {
        let a = try RemoteRelayTransfer.makeStagingDirectory()
        let b = try RemoteRelayTransfer.makeStagingDirectory()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertNotEqual(a, b)
        let mode = try FileManager.default
            .attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "staging holds remote file contents; keep it private")
    }

    // MARK: - Path normalisation

    func testNormalizeCollapsesTrailingSlashesButKeepsRoot() {
        XCTAssertEqual(RemoteRelayTransfer.normalize("/tmp/"), "/tmp")
        XCTAssertEqual(RemoteRelayTransfer.normalize("/tmp///"), "/tmp")
        XCTAssertEqual(RemoteRelayTransfer.normalize("/tmp"), "/tmp")
        XCTAssertEqual(RemoteRelayTransfer.normalize("/"), "/")
    }

    func testSourceDirectoryDerivesFromRemotePath() {
        let source = makeSource(
            entry: makeEntry(name: "web-01"), path: "/var/log/nginx/access.log",
            name: "access.log"
        )
        XCTAssertEqual(source.directory, "/var/log/nginx")
    }

    func testSourceDirectoryOfARootLevelFileIsRoot() {
        let source = makeSource(
            entry: makeEntry(name: "web-01"), path: "/notes.txt", name: "notes.txt"
        )
        XCTAssertEqual(source.directory, "/")
    }
}

/// Collects phase callbacks from the relay, which runs them off the test's
/// own thread.
private final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [RemoteRelayTransfer.Phase] = []

    func record(_ phase: RemoteRelayTransfer.Phase) {
        lock.lock(); phases.append(phase); lock.unlock()
    }

    var recorded: [RemoteRelayTransfer.Phase] {
        lock.lock(); defer { lock.unlock() }
        return phases
    }
}

/// The drag payload crosses a pasteboard as JSON, so its encoding is a wire
/// format between two halves of the app rather than an implementation detail.
final class RemoteFileDragPayloadTests: XCTestCase {

    func testRoundTripsThroughJSON() throws {
        let original = RemoteFileDragPayload(
            entryID: UUID(), remotePath: "/var/log/nginx/access.log",
            name: "access.log", size: 4_096
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteFileDragPayload.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Names that are awkward on a command line still have to survive the trip
    /// intact — quoting happens at the sftp boundary, not here.
    func testPreservesAwkwardFilenames() throws {
        let original = RemoteFileDragPayload(
            entryID: UUID(), remotePath: "/tmp/a b'c\"d$e.log",
            name: "a b'c\"d$e.log", size: 1
        )
        let decoded = try JSONDecoder().decode(
            RemoteFileDragPayload.self, from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded.name, "a b'c\"d$e.log")
        XCTAssertEqual(decoded.remotePath, "/tmp/a b'c\"d$e.log")
    }

    func testExportedTypeMatchesTheDeclarationInMakeApp() {
        XCTAssertEqual(
            UTType.portsideRemoteFile.identifier, "net.timmcg.portside.remote-file",
            "Scripts/make_app.sh declares this identifier in UTExportedTypeDeclarations; " +
            "changing one without the other silently breaks the drop target"
        )
    }
}
