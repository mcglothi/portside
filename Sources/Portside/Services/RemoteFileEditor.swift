import AppKit
import CryptoKit
import Foundation

/// Watches a single file for content changes, surviving the atomic
/// save-by-rename most editors use (write to a temp file, rename it over the
/// original). That rename swaps the inode out from under our descriptor, so a
/// naive watch fires exactly once and then goes permanently deaf — the classic
/// reason "edit remote file in your own editor" features only work the first
/// time. Re-arming on `.rename`/`.delete` is what makes the second save land.
final class FileWatcher {
    private let url: URL
    private let queue = DispatchQueue(label: "portside.filewatcher")
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?
    private var stopped = false
    private var retries = 0
    /// ~5s of re-arm attempts: generous for an atomic save's brief gap, short
    /// enough that a deleted file gives up quickly.
    private static let maxRetries = 25

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.debounce?.cancel()
            self.source?.cancel()
            self.source = nil
        }
    }

    private func arm() {
        guard !stopped else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // Mid-atomic-save the path can be momentarily absent; retry rather
            // than treating it as the file being gone for good. Bounded, so a
            // file that's genuinely been deleted doesn't leave a timer waking
            // this queue five times a second for the life of the app.
            retries += 1
            guard retries <= Self.maxRetries else { return }
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.arm() }
            return
        }
        retries = 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = src.data
            if flags.contains(.rename) || flags.contains(.delete) {
                src.cancel()
                self.source = nil
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.arm() }
            }
            self.scheduleChange()
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    /// Editors write in bursts (and an atomic save produces a rename plus a
    /// write); coalesce so one save means one upload.
    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.onChange()
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// One remote file checked out to a local temp copy and opened in its default
/// app. Holds the full `SessionEntry` (already credential-resolved by the
/// browser model) so uploads can run without going back through the store.
struct RemoteEdit: Identifiable {
    enum Status: Equatable {
        case downloading
        case watching
        case uploading
        case failed(String)
    }

    var id = UUID()
    let entry: SessionEntry
    let remotePath: String
    let name: String
    let localURL: URL
    var status: Status = .downloading
    var uploadCount = 0
    var lastUploaded: Date?
    /// Any state change, used to decide when the pane's notice has been quiet
    /// long enough to collapse out of the way.
    var lastActivity = Date()
    /// nil = whatever the system default is for this file type.
    var appURL: URL?
    /// The remote file's size/mtime/mode as last confirmed — at checkout, and
    /// refreshed after each successful upload. A save compares the *current*
    /// remote state against this before writing, so a change made elsewhere
    /// in between (another admin, another tool) is caught instead of quietly
    /// overwritten.
    var checkoutSnapshot: RemoteFile?
    /// Size from the directory listing, so a transfer can show real progress
    /// (batch-mode `sftp -q` reports none) and a mis-click on a huge file can
    /// be caught before any bytes move.
    var totalBytes: Int = 0
    var transferredBytes: Int = 0

    var fractionComplete: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    var entryID: UUID { entry.id }

    /// The remote directory `put` writes back into. `put` truncates an existing
    /// file rather than recreating it, so the remote file keeps its mode and
    /// ownership — important when editing things like `/etc` configs.
    var remoteDirectory: String {
        let dir = (remotePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }
}

/// Backs the "double-click a remote file, edit it in your own app, saves go
/// back automatically" workflow. There's no live mount behind this: the file is
/// downloaded to a private temp directory, opened with `NSWorkspace`, watched,
/// and re-uploaded whenever its contents actually change.
///
/// App-wide (not per-pane) so an edit survives switching hosts, closing the
/// file browser, or closing the tab it was started from.
@MainActor
final class RemoteFileEditor: ObservableObject {
    static let shared = RemoteFileEditor()

    @Published private(set) var edits: [RemoteEdit] = []

    /// The app remote files open in by default, from Settings ▸ Connection.
    /// nil means "whatever macOS would use for the file type", which for
    /// config files is often nothing useful — hence the setting.
    var preferredEditor: URL?

    private var watchers: [UUID: FileWatcher] = [:]
    /// Content hash at the last known-synced state, so an editor touching the
    /// file without changing it (or our own download) doesn't cause an upload.
    private var digests: [UUID: Data] = [:]
    /// Edits whose file changed again while an upload was already in flight.
    private var pending: Set<UUID> = []
    /// In-flight transfers, so Stop can actually kill the `sftp` child rather
    /// than just hiding the row while the bytes keep coming.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Above this, opening a file for editing asks first. Editing is a
    /// text-file workflow; anything this large is a mis-click (a model file, a
    /// tarball, a VM image) and downloading it silently would be hostile.
    static let largeFileThreshold = 10 * 1024 * 1024

    nonisolated private static let tempPrefix = "portside-edit-"

    func edits(for entryID: UUID) -> [RemoteEdit] {
        edits.filter { $0.entryID == entryID }
    }

    /// Downloads `remotePath`, opens it, and starts watching. `app` overrides
    /// the choice for this file only; nil uses `preferredEditor`, and failing
    /// that the system default.
    ///
    /// Re-opening a file that's already checked out just brings the existing
    /// copy forward instead of racing two watchers over two temp files.
    func open(
        file: RemoteFile, remotePath: String, on entry: SessionEntry,
        using app: URL? = nil
    ) {
        let chosen = app ?? preferredEditor ?? EditorApps.safeDefaultEditor()
        if let existing = edits.first(where: { $0.entryID == entry.id && $0.remotePath == remotePath }) {
            _ = EditorApps.open(existing.localURL, with: app ?? existing.appURL ?? EditorApps.safeDefaultEditor())
            touch(existing.id)
            return
        }

        let id = UUID()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.tempPrefix + id.uuidString)
        let localURL = dir.appendingPathComponent(file.name)
        edits.append(RemoteEdit(
            id: id, entry: entry, remotePath: remotePath, name: file.name,
            localURL: localURL, appURL: chosen, checkoutSnapshot: file,
            totalBytes: file.size
        ))

        tasks[id] = Task { await self.checkout(id: id, directory: dir) }
    }

    /// Why this edit's local copy is not safe to delete, or nil if it is.
    ///
    /// The only state that is genuinely disposable is content the host already
    /// has. A `.failed` upload, an upload cancelled in flight, and a save the
    /// watcher has not managed to push all look like "nothing is happening" in
    /// the UI, but each one means the only copy of the user's work is the
    /// local file we are about to delete.
    ///
    /// `.downloading` is not unsynced: nothing has been authored yet, so a
    /// partial download is genuinely disposable.
    func unsyncedReason(_ id: UUID) -> String? {
        guard let edit = edits.first(where: { $0.id == id }) else { return nil }
        return Self.unsyncedReason(
            status: edit.status, localURL: edit.localURL, lastSyncedDigest: digests[id]
        )
    }

    /// The decision itself, separated from the lookup so it can be tested
    /// against every status directly rather than through a live checkout.
    nonisolated static func unsyncedReason(
        status: RemoteEdit.Status, localURL: URL, lastSyncedDigest: Data?
    ) -> String? {
        switch status {
        case .downloading:
            return nil
        case .failed(let message):
            return message
        case .uploading:
            return "The upload was interrupted before it finished."
        case .watching:
            // The digest is only committed after a *successful* upload, so a
            // mismatch here means the file on disk was never pushed.
            guard let current = digest(of: localURL) else { return nil }
            return current == lastSyncedDigest
                ? nil
                : "Saved locally, but the change never reached the host."
        }
    }

    /// Edits whose local copy holds work the host does not have.
    var unsyncedEdits: [RemoteEdit] {
        edits.filter { unsyncedReason($0.id) != nil }
    }

    /// Moves an unsynced copy somewhere durable and returns where it landed.
    ///
    /// The checkout lives in `NSTemporaryDirectory`, which this app deletes on
    /// quit and macOS may reap on its own. Rescued work goes to Application
    /// Support instead, next to the library, with a manifest naming the host
    /// and remote path — a bare `file.conf` in a UUID directory is not
    /// recoverable by a human three days later.
    @discardableResult
    func rescue(_ edit: RemoteEdit, reason: String) -> URL? {
        let fm = FileManager.default
        let source = edit.localURL.deletingLastPathComponent()
        guard fm.fileExists(atPath: edit.localURL.path) else { return nil }

        let destination = Self.rescueDirectory
            .appendingPathComponent(Self.timestamp() + "-" + edit.name, isDirectory: true)
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let file = destination.appendingPathComponent(edit.name)
            // Copy rather than move: a move that half-succeeds across volumes
            // would take the only copy with it. The temp original is removed
            // only once the rescued file is known to be readable.
            try fm.copyItem(at: edit.localURL, to: file)
            guard fm.contentsEqual(atPath: edit.localURL.path, andPath: file.path) else {
                return nil
            }

            let manifest = """
                Portside — unsynced remote edit

                File:        \(edit.name)
                Remote path: \(edit.remotePath)
                Host:        \(edit.entry.name) (\(edit.entry.subtitle))
                Rescued:     \(ISO8601DateFormatter().string(from: Date()))
                Reason:      \(reason)

                This copy holds changes that never reached the host. Compare it
                against the current remote file before copying it back —
                something else may have changed the file in the meantime.
                """
            try? manifest.write(
                to: destination.appendingPathComponent("README.txt"),
                atomically: true, encoding: .utf8
            )

            try? fm.removeItem(at: source)
            NSLog("Portside: rescued unsynced edit of \(edit.remotePath) to \(destination.path)")
            return destination
        } catch {
            // Better to leak a temp directory than to delete the only copy.
            NSLog("Portside: could not rescue \(edit.remotePath): \(error.localizedDescription)")
            return nil
        }
    }

    /// Where rescued copies go. Honours the library override so tests and a
    /// throwaway library don't write into the user's real Application Support.
    nonisolated static var rescueDirectory: URL {
        let base = ProcessInfo.processInfo.environment[SessionStore.libraryDirectoryOverrideKey]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Portside")
        return base.appendingPathComponent("Unsynced Edits", isDirectory: true)
    }

    nonisolated private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

#if DEBUG
    /// Test seam: seeds an edit as though it had been checked out, so `stop`
    /// and `stopAll` can be exercised on their real code path without a live
    /// SFTP session. `syncedDigest` is what the host is believed to hold —
    /// pass the file's own digest for a synced edit, nil or a stale value for
    /// an unsynced one.
    func seedForTesting(_ edit: RemoteEdit, syncedDigest: Data?) {
        edits.append(edit)
        digests[edit.id] = syncedDigest
    }

    nonisolated static func digestForTesting(of url: URL) -> Data? { digest(of: url) }
#endif

    /// Stops watching and releases the checkout.
    ///
    /// A copy the host already has is deleted, as before. A copy holding
    /// unsynced work is moved to `rescueDirectory` instead — losing it was
    /// silent data loss, and the user pressing Stop (or quitting) is not
    /// consent to discard a save that failed to upload.
    func stop(_ id: UUID) {
        let reason = unsyncedReason(id)
        tasks[id]?.cancel()
        tasks[id] = nil
        watchers[id]?.stop()
        watchers[id] = nil
        digests[id] = nil
        pending.remove(id)
        if let edit = edits.first(where: { $0.id == id }) {
            if let reason {
                rescue(edit, reason: reason)
            } else {
                try? FileManager.default.removeItem(at: edit.localURL.deletingLastPathComponent())
            }
        }
        edits.removeAll { $0.id == id }
    }

    func stopAll() {
        for edit in edits { stop(edit.id) }
    }

    /// Temp copies from a previous run (a crash, or a force-quit that skipped
    /// `stopAll`) are unreachable once their edits are gone — clear them at
    /// launch so they don't accumulate.
    nonisolated static func purgeStaleCopies() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        guard let contents = try? fm.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil
        ) else { return }
        // Abandoned drag-out staging directories too: a cancelled or crashed
        // drag of a large file leaves multi-gigabyte partials behind, and
        // nothing else ever cleans them up.
        let prefixes = [tempPrefix, dragPrefix, comparePrefix]
        for url in contents where prefixes.contains(where: url.lastPathComponent.hasPrefix) {
            try? fm.removeItem(at: url)
        }
    }

    nonisolated static let dragPrefix = "portside-drag-"

    /// Scratch copies pulled purely to compare against the host. Swept at
    /// launch like the others: a crash mid-comparison leaves one behind.
    nonisolated static let comparePrefix = "portside-compare-"

    // MARK: - Checkout

    private func checkout(id: UUID, directory: URL) async {
        guard let edit = edits.first(where: { $0.id == id }) else { return }
        let progress = Task { await self.pollProgress(id: id, localURL: edit.localURL) }
        defer { progress.cancel() }

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try await SFTPClient(entry: edit.entry)
                .download(remotePath: edit.remotePath, to: edit.localURL)
            Self.hardenCheckout(edit.localURL)
        } catch {
            // A cancelled transfer isn't a failure to report — Stop already
            // removed the row. Just make sure the partial file goes with it,
            // since `sftp` may have written more after the row disappeared.
            if Task.isCancelled || error is CancellationError {
                try? FileManager.default.removeItem(at: directory)
                return
            }
            update(id) { $0.status = .failed(error.localizedDescription) }
            return
        }

        // Baseline the digest *before* opening: an app that rewrites the file
        // on open (trailing-newline fixers, format normalizers) would otherwise
        // read as a user edit and upload before the user has changed anything.
        digests[id] = Self.digest(of: edit.localURL)

        guard EditorApps.open(edit.localURL, with: edit.appURL) else {
            let target = edit.appURL.map { "\(EditorApps.displayName(of: $0)) could not be launched" }
                ?? "No app is available to open \"\(edit.name)\""
            update(id) { $0.status = .failed("\(target).") }
            return
        }

        update(id) { $0.status = .watching }
        watchers[id] = FileWatcher(url: edit.localURL) { [weak self] in
            Task { @MainActor in self?.localFileChanged(id) }
        }
    }

    private func localFileChanged(_ id: UUID) {
        guard let edit = edits.first(where: { $0.id == id }) else { return }
        // A save landing mid-upload can't start a second one, but it must not
        // be dropped either — that would leave the host holding stale content
        // with the pane cheerfully reporting a successful save. Queue it.
        if case .uploading = edit.status {
            pending.insert(id)
            return
        }
        guard let digest = Self.digest(of: edit.localURL), digest != digests[id] else { return }
        update(id) { $0.status = .uploading }
        // Tracked so Stop can kill an upload in flight too — a save of
        // something huge is just as un-abortable otherwise.
        tasks[id] = Task { await self.upload(id, digest: digest) }
    }

    /// Whether the host's copy differs from what we believe it holds, as a
    /// message to show — or nil when overwriting is safe.
    ///
    /// **Compares content, not metadata.** This used to compare the listing's
    /// size and date, which cannot see a change that keeps the byte count
    /// within the same minute — `ls` gives `Sep  9 21:03`, and for a file
    /// older than six months only `Sep  9  2025`. Two admins editing one
    /// config during an incident is exactly the case the guard exists for and
    /// exactly the case it missed.
    ///
    /// This half gathers the facts; `conflict(...)` decides on them.
    private func remoteChanged(
        _ edit: RemoteEdit, client: SFTPClient, id: UUID
    ) async throws -> String? {
        let believed = digests[id]

        // Cheap pre-filter: a size change is a definite change, and catching
        // it here refuses without transferring anything. A size *match* proves
        // nothing, so it never short-circuits the content check.
        let current = try await client.snapshot(of: edit.remotePath)
        if let decision = Self.conflict(
            name: edit.name, believed: believed, remoteExists: current != nil,
            currentSize: current?.size, checkoutSize: edit.checkoutSnapshot?.size,
            remoteDigestHex: nil, sizeCheckOnly: true
        ) {
            return decision
        }

        // Ask the host to hash it: one small command, no transfer.
        var remoteHex = try await client.remoteSHA256(of: edit.remotePath)

        if remoteHex == nil {
            // No hasher on the host. Read the file and hash it here — slower,
            // but it always works, so the guard is never skipped for want of a
            // tool on the far end.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.comparePrefix + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                try FileManager.default.createDirectory(
                    at: scratch, withIntermediateDirectories: true
                )
                let copy = scratch.appendingPathComponent(edit.name)
                try await client.download(remotePath: edit.remotePath, to: copy)
                remoteHex = Self.digest(of: copy).map(Self.hex)
            } catch {
                return "\(edit.name) couldn't be checked against the host "
                    + "(\(error.localizedDescription)). Nothing was written."
            }
        }

        return Self.conflict(
            name: edit.name, believed: believed, remoteExists: true,
            currentSize: current?.size, checkoutSize: edit.checkoutSnapshot?.size,
            remoteDigestHex: remoteHex, sizeCheckOnly: false
        )
    }

    /// The decision, separated from the I/O so every branch is testable.
    ///
    /// **Fails closed.** Every path that cannot establish "unchanged" refuses
    /// the save: the cost of refusing is reopening the file, and the cost of
    /// being wrong is someone else's work silently overwritten.
    nonisolated static func conflict(
        name: String,
        believed: Data?,
        remoteExists: Bool,
        currentSize: Int?,
        checkoutSize: Int?,
        remoteDigestHex: String?,
        sizeCheckOnly: Bool
    ) -> String? {
        let changed = "\(name) changed on the host since it was opened — reopen it "
            + "to see the current version before saving again."

        guard remoteExists else {
            return "\(name) is no longer on the host. Save a copy locally before "
                + "reopening — uploading now would recreate it from a stale copy."
        }
        guard let believed else {
            return "\(name) can't be checked against the host — Portside has no record "
                + "of what it held when this file was opened. Reopen it before saving."
        }
        if let currentSize, let checkoutSize, currentSize != checkoutSize {
            return changed
        }
        // The pre-filter pass has no digest yet and must not conclude anything
        // from a matching size alone.
        if sizeCheckOnly { return nil }

        guard let remoteDigestHex else {
            return "\(name) couldn't be checked against the host — no usable digest. "
                + "Nothing was written."
        }
        return remoteDigestHex == hex(believed) ? nil : changed
    }

    nonisolated static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func upload(_ id: UUID, digest: Data) async {
        guard let edit = edits.first(where: { $0.id == id }) else { return }
        let client = SFTPClient(entry: edit.entry)
        do {
            // Refuse rather than clobber: if the file changed on the host
            // since it was checked out (another admin, another tool, our own
            // earlier save landing under a stale snapshot), overwriting it
            // silently is exactly the data loss this exists to prevent.
            if let conflict = try await self.remoteChanged(edit, client: client, id: id) {
                update(id) { $0.status = .failed(conflict) }
                return
            }
            try await client.uploadReplacing(
                localURL: edit.localURL, remotePath: edit.remotePath,
                preservingModeFrom: edit.checkoutSnapshot
            )
            // Only now is this content known to be on the host. Committing the
            // digest earlier would make a failed upload look synced, so saving
            // the same content again wouldn't retry.
            digests[id] = digest
            // Re-read what's actually on the host now rather than guessing —
            // otherwise the *next* save's conflict check would compare against
            // this save's own now-stale pre-upload snapshot and always fail.
            let updatedSnapshot = try? await client.snapshot(of: edit.remotePath)
            update(id) {
                $0.status = .watching
                $0.uploadCount += 1
                $0.lastUploaded = Date()
                if let updatedSnapshot { $0.checkoutSnapshot = updatedSnapshot }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            // Stay armed after a failure (a read-only file, an expired
            // connection) so the next save retries rather than silently
            // dropping the user's work on the floor.
            update(id) { $0.status = .failed(error.localizedDescription) }
        }

        if pending.remove(id) != nil {
            localFileChanged(id)
        }
    }

    private func update(_ id: UUID, _ change: (inout RemoteEdit) -> Void) {
        guard let index = edits.firstIndex(where: { $0.id == id }) else { return }
        change(&edits[index])
        edits[index].lastActivity = Date()
    }

    /// Marks an edit active without changing it — reopening the same file
    /// should bring the pane's notice back, not leave it collapsed.
    private func touch(_ id: UUID) {
        update(id) { _ in }
    }

    /// Batch-mode `sftp -q` prints no progress, but the listing already told us
    /// the size, so watching the partial file grow gives a real percentage.
    /// Deliberately does not stamp `lastActivity` — progress ticks shouldn't
    /// count as user activity for the notice's collapse timer.
    private func pollProgress(id: UUID, localURL: URL) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int) ?? nil
            guard let size, let index = edits.firstIndex(where: { $0.id == id }) else { continue }
            edits[index].transferredBytes = size
        }
    }

    /// Neutralises a fresh checkout before it's handed to any app.
    ///
    /// `sftp get` preserves the remote file's mode, so a checked-out script
    /// can arrive executable; stripping that bit means opening it as text
    /// can't become running it. Quarantine mirrors what Safari/Mail stamp on
    /// their own downloads — network-sourced content, subject to Gatekeeper
    /// and the "are you sure" prompt if anything ever does try to execute it.
    nonisolated static func hardenCheckout(_ url: URL) {
        if let perms = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int {
            try? FileManager.default.setAttributes(
                [.posixPermissions: perms & ~0o111], ofItemAtPath: url.path
            )
        }
        var mutableURL = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineType": "LSQuarantineTypeOtherDownload",
            "LSQuarantineAgentName": "Portside",
        ]
        try? mutableURL.setResourceValues(values)
    }

    /// Pure file hash — no actor state, so the unsynced check can run it
    /// without hopping to the main actor.
    nonisolated private static func digest(of url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}
