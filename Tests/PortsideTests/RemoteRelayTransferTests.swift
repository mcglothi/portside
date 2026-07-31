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
        // Compared by kind: the download phase carries the staging URL, which
        // is a fresh temp path every run.
        XCTAssertEqual(phases.recorded.map(\.label), ["downloading", "uploading", "finished"])
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

extension RemoteRelayTransfer.Phase {
    /// Kind only, ignoring the staging URL.
    var label: String {
        switch self {
        case .downloading: return "downloading"
        case .uploading: return "uploading"
        case .finished: return "finished"
        }
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

/// MultiExec fan-out: one file to every broadcasting host.
final class RemoteRelayFanOutTests: XCTestCase {

    private func makeEntry(_ name: String, kind: SessionKind = .host) -> SessionEntry {
        SessionEntry(name: name, hostname: "\(name).internal", kind: kind)
    }

    private func source(_ entry: SessionEntry) -> RemoteRelayTransfer.Source {
        RemoteRelayTransfer.Source(
            entry: entry, remotePath: "/etc/hosts", name: "hosts", size: 512
        )
    }

    private func remoteFile(_ name: String) -> RemoteFile {
        RemoteFile(
            name: name, isDirectory: false, isSymlink: false,
            size: 1, dateText: "", permissions: "-rw-r--r--"
        )
    }

    private final class Fake: @unchecked Sendable {
        var downloads = 0
        var uploads: [String] = []
        /// host name -> what its directory already contains
        var listings: [String: [RemoteFile]] = [:]
        var failUploadsTo: Set<String> = []

        func operations() -> RemoteRelayTransfer.Operations {
            RemoteRelayTransfer.Operations(
                pwd: { _ in "/home/deploy" },
                list: { entry, _ in self.listings[entry.name] ?? [] },
                download: { _, _, url in
                    self.downloads += 1
                    try Data("payload".utf8).write(to: url)
                },
                upload: { entry, _, _ in
                    if self.failUploadsTo.contains(entry.name) {
                        throw SFTPClientError.failed("no space left on device")
                    }
                    self.uploads.append(entry.name)
                }
            )
        }
    }

    /// The reason fan-out is its own path: N hosts must not mean N downloads
    /// of the same bytes.
    func testDownloadsOnceRegardlessOfHostCount() async throws {
        let fake = Fake()
        let hosts = ["web-01", "web-02", "web-03", "web-04"].map { makeEntry($0) }
        let results = try await RemoteRelayTransfer.runFanOut(
            source: source(makeEntry("build")),
            destinations: hosts.map { .init(entry: $0, directory: "/tmp") },
            operations: fake.operations()
        )
        XCTAssertEqual(fake.downloads, 1, "one download should feed every upload")
        XCTAssertEqual(fake.uploads.count, 4)
        XCTAssertEqual(results.filter { $0.1 == .delivered }.count, 4)
    }

    /// One bad host must not cost the others their copy.
    func testOneFailureDoesNotStopTheRest() async throws {
        let fake = Fake()
        fake.failUploadsTo = ["web-02"]
        let hosts = ["web-01", "web-02", "web-03"].map { makeEntry($0) }
        let results = try await RemoteRelayTransfer.runFanOut(
            source: source(makeEntry("build")),
            destinations: hosts.map { .init(entry: $0, directory: "/tmp") },
            operations: fake.operations()
        )
        XCTAssertEqual(fake.uploads.sorted(), ["web-01", "web-03"])
        let failed = results.filter { if case .failed = $0.1 { return true } else { return false } }
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.0.entry.name, "web-02")
    }

    /// Dragging onto a broadcast that includes the file's own pane is
    /// ordinary; that host is a skip, not an error.
    func testSourcesOwnHostIsSkippedNotFailed() async throws {
        let fake = Fake()
        let build = makeEntry("build")
        let results = try await RemoteRelayTransfer.runFanOut(
            source: source(build),
            destinations: [
                .init(entry: build, directory: "/etc"),        // where the file already is
                .init(entry: makeEntry("web-01"), directory: "/tmp"),
            ],
            operations: fake.operations()
        )
        XCTAssertEqual(results.first(where: { $0.0.entry.id == build.id })?.1, .skipped)
        XCTAssertEqual(fake.uploads, ["web-01"])
    }

    /// A host that already has the file is reported, and the group still goes.
    func testCollisionOnOneHostIsReportedWithoutBlockingOthers() async throws {
        let fake = Fake()
        fake.listings["web-02"] = [remoteFile("hosts")]
        let hosts = ["web-01", "web-02"].map { makeEntry($0) }
        let results = try await RemoteRelayTransfer.runFanOut(
            source: source(makeEntry("build")),
            destinations: hosts.map { .init(entry: $0, directory: "/tmp") },
            operations: fake.operations()
        )
        XCTAssertEqual(fake.uploads, ["web-01"])
        guard case .failed(let message)? = results.first(where: {
            $0.0.entry.name == "web-02"
        })?.1 else { return XCTFail("expected web-02 to report a collision") }
        XCTAssertTrue(message.contains("already exists"), message)
    }

    /// Preflight runs before the download so a doomed group does not pull
    /// bytes down first.
    func testNothingIsDownloadedWhenEveryHostIsIneligible() async throws {
        let fake = Fake()
        fake.listings["web-01"] = [remoteFile("hosts")]
        fake.listings["web-02"] = [remoteFile("hosts")]
        let hosts = ["web-01", "web-02"].map { makeEntry($0) }
        _ = try await RemoteRelayTransfer.runFanOut(
            source: source(makeEntry("build")),
            destinations: hosts.map { .init(entry: $0, directory: "/tmp") },
            operations: fake.operations()
        )
        XCTAssertEqual(fake.downloads, 0)
        XCTAssertTrue(fake.uploads.isEmpty)
    }

    func testEmptyDestinationListIsANoOp() async throws {
        let fake = Fake()
        let results = try await RemoteRelayTransfer.runFanOut(
            source: source(makeEntry("build")), destinations: [],
            operations: fake.operations()
        )
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(fake.downloads, 0)
    }

    func testStagingIsRemovedAfterAFanOut() async throws {
        let fake = Fake()
        var staged: URL?
        var ops = fake.operations()
        let inner = ops.download
        ops.download = { entry, path, url in
            staged = url
            try await inner(entry, path, url)
        }
        _ = try await RemoteRelayTransfer.runFanOut(
            source: source(makeEntry("build")),
            destinations: [.init(entry: makeEntry("web-01"), directory: "/tmp")],
            operations: ops
        )
        let dir = try XCTUnwrap(staged).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}

/// The fan-out summary has to account for every host. "Copied to 2 of 4" with
/// a single failure listed sends the reader hunting for a fourth host that was
/// only ever skipped — which is exactly what happened in live testing.
final class RemoteRelayReportingTests: XCTestCase {

    private func entry(_ name: String) -> SessionEntry {
        SessionEntry(name: name, hostname: "\(name).internal", kind: .host)
    }

    /// Mirrors the arithmetic the coordinator does when building its message.
    private func summary(for results: [RemoteRelayTransfer.Outcome]) -> String {
        let delivered = results.filter { $0 == .delivered }.count
        let skipped = results.filter { $0 == .skipped }.count
        var text = "Copied to \(delivered) of \(results.count) hosts."
        if skipped > 0 { text += " \(skipped) already had it." }
        return text
    }

    func testSkippedHostsAreAccountedForInTheSummary() {
        // The live case: 4 panes, source's own skipped, hopper unwritable.
        let outcomes: [RemoteRelayTransfer.Outcome] = [
            .delivered, .delivered, .skipped, .failed("Permission denied"),
        ]
        XCTAssertEqual(
            summary(for: outcomes),
            "Copied to 2 of 4 hosts. 1 already had it."
        )
    }

    func testNoSkipClauseWhenNothingWasSkipped() {
        let outcomes: [RemoteRelayTransfer.Outcome] = [
            .delivered, .failed("Permission denied"),
        ]
        XCTAssertEqual(summary(for: outcomes), "Copied to 1 of 2 hosts.")
    }

    /// Numbers must always reconcile: delivered + skipped + failed == total.
    func testEveryOutcomeIsCountedExactlyOnce() {
        let outcomes: [RemoteRelayTransfer.Outcome] = [
            .delivered, .skipped, .skipped, .failed("a"), .failed("b"), .delivered,
        ]
        let delivered = outcomes.filter { $0 == .delivered }.count
        let skipped = outcomes.filter { $0 == .skipped }.count
        let failed = outcomes.filter { if case .failed = $0 { return true } else { return false } }.count
        XCTAssertEqual(delivered + skipped + failed, outcomes.count)
    }
}

/// A relay changes what its progress bar counts partway through: bytes while
/// the file comes down, then hosts while it goes out to a broadcast group.
@MainActor
final class TransferCenterRescaleTests: XCTestCase {

    func testRescaleSwitchesUnitsWithoutLosingTheEntry() {
        let center = TransferCenter.shared
        let id = center.begin(
            entryID: UUID(), remotePath: "/tmp/f", label: "Copying…",
            total: 1_000, cancel: {}
        )
        defer { center.finish(id) }

        center.rescale(id, transferred: 400, total: 1_000)
        XCTAssertEqual(center.transfers.first { $0.id == id }?.fraction, 0.4)

        // Bytes -> hosts.
        center.rescale(id, transferred: 3, total: 8)
        let transfer = center.transfers.first { $0.id == id }
        XCTAssertEqual(transfer?.transferred, 3)
        XCTAssertEqual(transfer?.total, 8)
        XCTAssertEqual(transfer?.fraction, 0.375)
    }

    /// total 0 means "no measurable progress" — the view shows a spinner
    /// rather than a bar frozen at 100%.
    func testRescalingToZeroTotalYieldsNoFraction() {
        let center = TransferCenter.shared
        let id = center.begin(
            entryID: UUID(), remotePath: "/tmp/f", label: "Copying…",
            total: 1_000, cancel: {}
        )
        defer { center.finish(id) }

        center.rescale(id, transferred: 1_000, total: 1_000)
        XCTAssertEqual(center.transfers.first { $0.id == id }?.fraction, 1.0)

        center.rescale(id, transferred: 0, total: 0)
        XCTAssertNil(center.transfers.first { $0.id == id }?.fraction)
    }
}

/// Dropping a file from Finder onto a broadcasting pane. No download leg —
/// the dropped file is already the staging file.
final class RemoteRelayLocalFanOutTests: XCTestCase {

    private func makeEntry(_ name: String, kind: SessionKind = .host) -> SessionEntry {
        SessionEntry(name: name, hostname: "\(name).internal", kind: kind)
    }

    private func remoteFile(_ name: String) -> RemoteFile {
        RemoteFile(
            name: name, isDirectory: false, isSymlink: false,
            size: 1, dateText: "", permissions: "-rw-r--r--"
        )
    }

    private final class Fake: @unchecked Sendable {
        var uploads: [(host: String, url: URL)] = []
        var listings: [String: [RemoteFile]] = [:]
        var failUploadsTo: Set<String> = []
        var downloads = 0

        func operations() -> RemoteRelayTransfer.Operations {
            RemoteRelayTransfer.Operations(
                pwd: { _ in "/home/deploy" },
                list: { entry, _ in self.listings[entry.name] ?? [] },
                download: { _, _, _ in self.downloads += 1 },
                upload: { entry, url, _ in
                    if self.failUploadsTo.contains(entry.name) {
                        throw SFTPClientError.failed("no space left on device")
                    }
                    self.uploads.append((entry.name, url))
                }
            )
        }
    }

    private func tempFile(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-localfanout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("local payload".utf8).write(to: url)
        return url
    }

    func testUploadsTheLocalFileToEveryHostWithoutDownloading() async throws {
        let fake = Fake()
        let file = try tempFile(named: "deploy.sh")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let hosts = ["web-01", "web-02", "web-03"].map { makeEntry($0) }
        let results = try await RemoteRelayTransfer.runLocalFanOut(
            localURL: file, name: "deploy.sh",
            destinations: hosts.map { .init(entry: $0, directory: "/tmp") },
            operations: fake.operations()
        )
        XCTAssertEqual(fake.downloads, 0, "a local file needs no download leg")
        XCTAssertEqual(fake.uploads.map(\.host).sorted(), ["web-01", "web-02", "web-03"])
        XCTAssertEqual(results.filter { $0.1 == .delivered }.count, 3)
    }

    /// The dropped file is uploaded in place rather than copied to staging —
    /// duplicating a large file to upload it would cost disk for nothing.
    func testUploadsTheDroppedFileItselfNotACopy() async throws {
        let fake = Fake()
        let file = try tempFile(named: "deploy.sh")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        _ = try await RemoteRelayTransfer.runLocalFanOut(
            localURL: file, name: "deploy.sh",
            destinations: [.init(entry: makeEntry("web-01"), directory: "/tmp")],
            operations: fake.operations()
        )
        XCTAssertEqual(fake.uploads.first?.url, file)
    }

    func testCollisionIsReportedPerHostAndOthersStillGo() async throws {
        let fake = Fake()
        fake.listings["web-02"] = [remoteFile("deploy.sh")]
        let file = try tempFile(named: "deploy.sh")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let results = try await RemoteRelayTransfer.runLocalFanOut(
            localURL: file, name: "deploy.sh",
            destinations: ["web-01", "web-02"].map {
                .init(entry: makeEntry($0), directory: "/tmp")
            },
            operations: fake.operations()
        )
        XCTAssertEqual(fake.uploads.map(\.host), ["web-01"])
        guard case .failed(let message)? = results.first(where: {
            $0.0.entry.name == "web-02"
        })?.1 else { return XCTFail("expected a collision on web-02") }
        XCTAssertTrue(message.contains("already exists"), message)
    }

    func testHostWithoutAFileBrowserIsReportedNotUploadedTo() async throws {
        let fake = Fake()
        let file = try tempFile(named: "deploy.sh")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let results = try await RemoteRelayTransfer.runLocalFanOut(
            localURL: file, name: "deploy.sh",
            destinations: [
                .init(entry: makeEntry("web-01"), directory: "/tmp"),
                .init(entry: makeEntry("app-container", kind: .container), directory: "/tmp"),
            ],
            operations: fake.operations()
        )
        XCTAssertEqual(fake.uploads.map(\.host), ["web-01"])
        XCTAssertEqual(results.count, 2)
    }

    /// The per-host label needs a 1-based index and the eligible count, so
    /// "2 of 3" never counts hosts that were rejected before any upload.
    func testDeliveryStartedReportsPositionAmongEligibleHostsOnly() async throws {
        let fake = Fake()
        fake.listings["web-02"] = [remoteFile("deploy.sh")]   // ineligible
        let file = try tempFile(named: "deploy.sh")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let seen = LocalDeliveryLog()
        _ = try await RemoteRelayTransfer.runLocalFanOut(
            localURL: file, name: "deploy.sh",
            destinations: ["web-01", "web-02", "web-03"].map {
                .init(entry: makeEntry($0), directory: "/tmp")
            },
            operations: fake.operations(),
            onDeliveryStarted: { destination, index, total in
                seen.record("\(destination.entry.name) \(index)/\(total)")
            }
        )
        XCTAssertEqual(seen.recorded, ["web-01 1/2", "web-03 2/2"])
    }
}

private final class LocalDeliveryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

/// A failed upload must not leave anything at the destination that looks like
/// the real file — the collision preflight would then refuse the retry,
/// reporting "already exists" for the remains of the failed attempt. The live
/// operations are wired to `uploadReplacing` (temp name, then rename) rather
/// than plain `upload`, which puts straight to the final filename.
final class RemoteRelayUploadPathTests: XCTestCase {

    func testJoinsDirectoryAndName() {
        XCTAssertEqual(
            RemoteRelayTransfer.remotePath(directory: "/tmp/TEST", name: "testfile"),
            "/tmp/TEST/testfile"
        )
    }

    /// Naive concatenation yields `//testfile`, which some servers treat as a
    /// different path.
    func testRootDirectoryDoesNotDoubleTheSlash() {
        XCTAssertEqual(
            RemoteRelayTransfer.remotePath(directory: "/", name: "testfile"),
            "/testfile"
        )
    }

    func testTrailingSlashIsNotDoubled() {
        XCTAssertEqual(
            RemoteRelayTransfer.remotePath(directory: "/tmp/", name: "testfile"),
            "/tmp/testfile"
        )
    }
}
