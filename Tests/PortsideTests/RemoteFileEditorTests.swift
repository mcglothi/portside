import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import Portside

final class RemoteFileEditorTests: XCTestCase {

    // MARK: - Upload target

    func testRemoteDirectoryIsTheFilesParent() {
        XCTAssertEqual(edit(remotePath: "/etc/nginx/nginx.conf").remoteDirectory, "/etc/nginx")
        XCTAssertEqual(edit(remotePath: "/home/tim/notes.md").remoteDirectory, "/home/tim")
    }

    func testRemoteDirectoryOfARootLevelFileIsRoot() {
        // deletingLastPathComponent gives "/" here, but a bare filename with no
        // leading slash yields "" — which `cd ""` would turn into the wrong
        // directory rather than an error, silently uploading somewhere else.
        XCTAssertEqual(edit(remotePath: "/motd").remoteDirectory, "/")
        XCTAssertEqual(edit(remotePath: "motd").remoteDirectory, "/")
    }

    func testRemoteDirectoryKeepsSpacesInPath() {
        XCTAssertEqual(
            edit(remotePath: "/srv/my app/config.yml").remoteDirectory,
            "/srv/my app"
        )
    }

    // MARK: - FileWatcher

    func testWatcherFiresOnInPlaceWrite() throws {
        let url = try makeFile(contents: "one")
        let fired = expectation(description: "in-place write seen")
        let watcher = FileWatcher(url: url) { fired.fulfill() }
        defer { watcher.stop() }

        // Give the watcher a moment to arm before touching the file.
        Thread.sleep(forTimeInterval: 0.2)
        try "two".write(to: url, atomically: false, encoding: .utf8)

        wait(for: [fired], timeout: 5)
    }

    /// The case that breaks naive implementations: most editors save by writing
    /// a temp file and renaming it over the original, which swaps the inode out
    /// from under the watcher's descriptor. Without re-arming, the *second*
    /// save is never seen and the user's later edits never reach the host.
    func testWatcherSurvivesAtomicSaveAndSeesTheNextOne() throws {
        let url = try makeFile(contents: "one")
        let first = expectation(description: "first atomic save seen")
        let second = expectation(description: "second atomic save seen")
        var count = 0
        let watcher = FileWatcher(url: url) {
            count += 1
            if count == 1 { first.fulfill() } else if count == 2 { second.fulfill() }
        }
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        try "two".write(to: url, atomically: true, encoding: .utf8)
        wait(for: [first], timeout: 5)

        try "three".write(to: url, atomically: true, encoding: .utf8)
        wait(for: [second], timeout: 5)
    }

    func testWatcherCoalescesABurstOfWritesIntoOneCallback() throws {
        let url = try makeFile(contents: "start")
        let fired = expectation(description: "burst reported")
        var count = 0
        let watcher = FileWatcher(url: url) {
            count += 1
            if count == 1 { fired.fulfill() }
        }
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)
        for i in 0..<10 {
            try "chunk \(i)".write(to: url, atomically: false, encoding: .utf8)
            Thread.sleep(forTimeInterval: 0.01)
        }
        wait(for: [fired], timeout: 5)

        // A save is one upload: the debounce should have folded the burst
        // together rather than firing per write.
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(count, 1)
    }

    func testStoppedWatcherGoesQuiet() throws {
        let url = try makeFile(contents: "one")
        var count = 0
        let watcher = FileWatcher(url: url) { count += 1 }
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()
        Thread.sleep(forTimeInterval: 0.2)

        try "two".write(to: url, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Stale copy cleanup

    func testPurgeRemovesOnlyPortsideEditDirectories() throws {
        let temp = FileManager.default.temporaryDirectory
        let mine = temp.appendingPathComponent("portside-edit-\(UUID().uuidString)")
        let theirs = temp.appendingPathComponent("someone-else-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: theirs) }

        RemoteFileEditor.purgeStaleCopies()

        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: theirs.path))
    }

    // MARK: - Editor choice

    func testExtensionlessFilesStillOfferTextEditors() {
        // authorized_keys / motd / hosts have no UTI to look up, and they're a
        // large share of what actually gets edited over SFTP — an empty menu
        // would make "Edit With" useless for exactly those files.
        XCTAssertTrue(EditorApps.typeHandlers(for: "authorized_keys").isEmpty)
        XCTAssertFalse(
            EditorApps.candidates(for: "authorized_keys").isEmpty,
            "extensionless files should fall back to plain-text handlers"
        )
    }

    func testCandidatesIncludeTextEditorsForConfigExtensions() {
        // .conf may be registered to something unhelpful or nothing at all;
        // the text editors must still be reachable.
        let candidates = EditorApps.candidates(for: "nginx.conf")
        let textEditors = EditorApps.plainTextEditors()
        XCTAssertFalse(textEditors.isEmpty, "a Mac always has some plain-text handler")
        for editor in textEditors {
            XCTAssertTrue(candidates.contains(editor), "\(editor.lastPathComponent) missing")
        }
    }

    func testCandidatesAreDeduplicated() {
        // An app registered for both the extension and plain text would
        // otherwise appear twice in the menu.
        let candidates = EditorApps.candidates(for: "notes.txt")
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }

    func testOpeningWithAMissingAppFails() {
        let gone = URL(fileURLWithPath: "/Applications/DefinitelyNotInstalled.app")
        XCTAssertFalse(EditorApps.open(URL(fileURLWithPath: "/etc/hosts"), with: gone))
    }

    // MARK: - Preferred editor preference

    func testRemoteEditorURLIsNilWhenUnsetOrBlank() {
        var defaults = ConnectionDefaults()
        XCTAssertNil(defaults.remoteEditorURL)
        defaults.remoteEditorPath = ""
        XCTAssertNil(defaults.remoteEditorURL, "a blank path must not become file:///")
    }

    func testOlderLibrariesDecodeWithoutTheEditorKey() throws {
        let json = Data(#"{"user":"tim","autoAcceptNewHostKeys":true}"#.utf8)
        let defaults = try JSONDecoder().decode(ConnectionDefaults.self, from: json)
        XCTAssertEqual(defaults.user, "tim")
        XCTAssertNil(defaults.remoteEditorPath)
    }

    // MARK: - Transfer cancellation

    /// The mis-click-on-a-40GB-file case: cancelling has to kill the child
    /// process, not just abandon the await. If it doesn't, the transfer runs to
    /// completion in the background and the "cancel" was a lie.
    func testCancellingATransferKillsTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-cancel-\(UUID().uuidString)")

        let task = Task {
            // Stands in for a long transfer: sleeps, then proves it ran to
            // completion by creating the marker.
            try await SFTPClient.runProcess(
                "/bin/sh", ["-c", "sleep 5; touch \(marker.path)"], stdin: ""
            )
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()

        _ = try? await task.value
        // Well past when the un-cancelled command would have finished.
        try await Task.sleep(nanoseconds: 6_000_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "the child process kept running after cancellation"
        )
    }

    func testCancellingBeforeLaunchStillPreventsTheProcess() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-cancel-\(UUID().uuidString)")
        let task = Task {
            try await SFTPClient.runProcess(
                "/bin/sh", ["-c", "sleep 3; touch \(marker.path)"], stdin: ""
            )
        }
        // Cancel in the window around launch — the adopt/didLaunch handoff has
        // to cover whichever side wins.
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(nanoseconds: 4_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testUncancelledProcessStillCompletesNormally() async throws {
        // The cancellation plumbing sits under every sftp call in the app, so
        // the ordinary path must be untouched.
        let result = try await SFTPClient.runProcess("/bin/echo", ["hello"], stdin: "")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    // MARK: - Large file guard

    func testLargeFileThresholdCatchesModelFilesButNotConfigs() {
        let threshold = RemoteFileEditor.largeFileThreshold
        XCTAssertFalse(4_096 > threshold, "an nginx.conf must not prompt")
        XCTAssertFalse(2 * 1024 * 1024 > threshold, "a 2MB log must not prompt")
        XCTAssertTrue(40 * 1024 * 1024 * 1024 > threshold, "a 40GB gguf must prompt")
    }

    func testFractionCompleteIsNilWithoutAKnownSize() {
        // Listings occasionally yield size 0; a progress bar stuck at 0% would
        // read as a hung transfer, so callers get nil and show a spinner.
        var edit = self.edit(remotePath: "/tmp/x")
        XCTAssertNil(edit.fractionComplete)
        edit.totalBytes = 100
        edit.transferredBytes = 25
        XCTAssertEqual(edit.fractionComplete, 0.25)
    }

    func testFractionCompleteClampsWhenTheFileGrewSinceListing() {
        var edit = self.edit(remotePath: "/tmp/x")
        edit.totalBytes = 100
        edit.transferredBytes = 180
        XCTAssertEqual(edit.fractionComplete, 1, "progress must not exceed 100%")
    }

    // MARK: - Pane transfer progress

    func testTransferFractionIsNilUntilASizeIsKnown() {
        // Uploads can't report bytes (batch `sftp put` is silent and the remote
        // side isn't pollable), so they leave total at 0 and the view falls
        // back to a spinner instead of a bar pinned at 0%.
        var transfer = TransferCenter.Transfer(
            id: UUID(), entryID: UUID(), remotePath: "/x", label: "Uploading disk.img"
        )
        XCTAssertNil(transfer.fraction)
        transfer.total = 400
        transfer.transferred = 100
        XCTAssertEqual(transfer.fraction, 0.25)
    }

    func testTransferFractionClampsAtFullyComplete() {
        var transfer = TransferCenter.Transfer(
            id: UUID(), entryID: UUID(), remotePath: "/x", label: "Downloading x",
            transferred: 900, total: 400
        )
        XCTAssertEqual(transfer.fraction, 1)
        transfer.transferred = 400
        XCTAssertEqual(transfer.fraction, 1)
    }

    @MainActor
    func testDuplicateDragOfTheSameFileIsRefused() {
        // The 18GB-model case: dragging the same file out twice started a
        // second download competing with the first for the same connection.
        let center = TransferCenter()
        let host = UUID()
        XCTAssertFalse(center.isTransferring(remotePath: "/models/big.gguf", entryID: host))

        let id = center.begin(
            entryID: host, remotePath: "/models/big.gguf", label: "Dragging", cancel: {}
        )
        XCTAssertTrue(center.isTransferring(remotePath: "/models/big.gguf", entryID: host))
        // Same path on a different host is a genuinely different transfer.
        XCTAssertFalse(center.isTransferring(remotePath: "/models/big.gguf", entryID: UUID()))
        XCTAssertFalse(center.isTransferring(remotePath: "/models/other.gguf", entryID: host))

        center.finish(id)
        XCTAssertFalse(center.isTransferring(remotePath: "/models/big.gguf", entryID: host))
    }

    @MainActor
    func testCancelRunsTheHookAndClearsTheTransfer() {
        let center = TransferCenter()
        var cancelled = false
        let id = center.begin(
            entryID: UUID(), remotePath: "/x", label: "Dragging", cancel: { cancelled = true }
        )
        center.cancel(id)
        XCTAssertTrue(cancelled, "cancelling must reach the transfer's own hook")
        XCTAssertTrue(center.transfers.isEmpty)
    }

    @MainActor
    func testTransfersAreScopedToTheirHostsPane() {
        let center = TransferCenter()
        let a = UUID(), b = UUID()
        center.begin(entryID: a, remotePath: "/1", label: "A", cancel: {})
        center.begin(entryID: b, remotePath: "/2", label: "B", cancel: {})
        XCTAssertEqual(center.transfers(for: a).map(\.label), ["A"])
        XCTAssertEqual(center.transfers(for: b).map(\.label), ["B"])
    }

    // MARK: - Checkout hardening

    /// `sftp get` preserves the remote mode, so a checked-out script can
    /// arrive executable — hardenCheckout must strip that so opening it as
    /// text can never become running it.
    func testHardenCheckoutStripsExecutableBits() throws {
        let url = try makeFile(contents: "#!/bin/sh\necho pwned\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        RemoteFileEditor.hardenCheckout(url)

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms.map { $0 & 0o111 }, 0, "executable bits survived hardening")
        XCTAssertEqual(perms.map { $0 & 0o600 }, 0o600, "owner read/write should be preserved")
    }

    func testHardenCheckoutQuarantinesTheFile() throws {
        let url = try makeFile(contents: "just text")
        RemoteFileEditor.hardenCheckout(url)

        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        XCTAssertNotNil(values.quarantineProperties, "checked-out files should carry quarantine metadata")
    }

    func testSafeDefaultEditorIsAnActualTextEditor() {
        // The regression this guards: falling back to nil here means
        // NSWorkspace's system-default handler decides what opens the file —
        // Terminal for a .command script, Installer for a .pkg, etc.
        let editor = EditorApps.safeDefaultEditor()
        XCTAssertNotNil(editor, "there must always be a safe fallback editor")
        if let editor {
            XCTAssertTrue(FileManager.default.fileExists(atPath: editor.path))
        }
    }

    // MARK: - Live round trip

    /// The whole feature end to end against a real host, using the same
    /// `SFTPClient` + `FileWatcher` the pane does: check a file out, save it
    /// the way an editor does (atomic rename), and confirm the change actually
    /// landed back on the server. Skipped unless a host is named, so CI and a
    /// normal `swift test` stay offline.
    ///
    ///     PORTSIDE_LIVE_SFTP_HOST=myhost swift test --filter LiveRoundTrip
    func testLiveRoundTripWritesTheEditBackToTheHost() async throws {
        guard let host = ProcessInfo.processInfo.environment["PORTSIDE_LIVE_SFTP_HOST"] else {
            throw XCTSkip("Set PORTSIDE_LIVE_SFTP_HOST to a reachable host to run this.")
        }
        var entry = SessionEntry(name: host)
        entry.hostname = host

        let remotePath = "/tmp/portside-edit-test-\(UUID().uuidString).conf"
        let original = "listen = 8080\n"
        let edited = "listen = 9090\n"
        try await ssh(host, "printf %s '\(original)' > \(remotePath)")
        defer { Task { try? await self.ssh(host, "rm -f \(remotePath)") } }

        let client = SFTPClient(entry: entry)
        let local = try makeFile(contents: "").deletingLastPathComponent()
            .appendingPathComponent((remotePath as NSString).lastPathComponent)
        try await client.download(remotePath: remotePath, to: local)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), original)

        let saved = expectation(description: "editor save observed")
        let watcher = FileWatcher(url: local) { saved.fulfill() }
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        try edited.write(to: local, atomically: true, encoding: .utf8)
        await fulfillment(of: [saved], timeout: 5)

        let edit = RemoteEdit(entry: entry, remotePath: remotePath, name: local.lastPathComponent,
                              localURL: local)
        try await client.upload(localURL: local, toDirectory: edit.remoteDirectory)

        let remoteNow = try await ssh(host, "cat \(remotePath)")
        XCTAssertEqual(remoteNow, edited, "the save should have replaced the remote file's contents")
    }

    /// The whole point of moving drag-out to `NSFilePromiseProvider`: bytes go
    /// straight to the drop destination. Drives the promise delegate the way
    /// AppKit does and asserts the file lands at the given URL with no
    /// staging copy anywhere in temp.
    @MainActor
    func testLivePromiseWritesStraightToTheDropDestination() async throws {
        guard let host = ProcessInfo.processInfo.environment["PORTSIDE_LIVE_SFTP_HOST"] else {
            throw XCTSkip("Set PORTSIDE_LIVE_SFTP_HOST to a reachable host to run this.")
        }
        var entry = SessionEntry(name: host)
        entry.hostname = host

        let contents = "dropped straight to the destination\n"
        let remotePath = "/tmp/portside-promise-\(UUID().uuidString).txt"
        try await ssh(host, "printf %s '\(contents)' > \(remotePath)")
        defer { Task { try? await self.ssh(host, "rm -f \(remotePath)") } }

        let dropDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-droptarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dropDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dropDir) }
        let destination = dropDir.appendingPathComponent("dropped.txt")

        let stagingBefore = Self.stagingDirectoryCount()

        let delegate = RemoteFilePromiseDelegate(
            entry: entry, remotePath: remotePath, name: "dropped.txt",
            size: contents.utf8.count
        )
        let provider = NSFilePromiseProvider(
            fileType: UTType.plainText.identifier, delegate: delegate
        )
        await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { _ in
                continuation.resume()
            }
        }

        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8), contents,
            "the promise should have written the real contents to the drop destination"
        )
        XCTAssertEqual(
            Self.stagingDirectoryCount(), stagingBefore,
            "no temp staging copy should be made — that was the double-write bug"
        )
    }

    private static func stagingDirectoryCount() -> Int {
        let temp = FileManager.default.temporaryDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter {
            $0.lastPathComponent.hasPrefix(RemoteFileEditor.dragPrefix)
        }.count
    }

    @discardableResult
    private func ssh(_ host: String, _ command: String) async throws -> String {
        let result = try await SFTPClient.runProcess(
            "/usr/bin/ssh",
            ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"] + SSHControl.options + [host, command],
            stdin: ""
        )
        guard result.status == 0 else {
            throw SFTPClientError.failed("ssh \(command) failed: \(result.err)")
        }
        return result.out
    }

    // MARK: - Helpers

    private func edit(remotePath: String) -> RemoteEdit {
        RemoteEdit(
            entry: SessionEntry(name: "host"),
            remotePath: remotePath,
            name: (remotePath as NSString).lastPathComponent,
            localURL: URL(fileURLWithPath: "/tmp/unused")
        )
    }

    private func makeFile(contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-watcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("file.txt")
        try contents.write(to: url, atomically: false, encoding: .utf8)
        return url
    }
}
