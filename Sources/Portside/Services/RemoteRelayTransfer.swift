import Foundation

/// Copies one file straight from one host to another.
///
/// There is no zero-hop path here: OpenSSH cannot stream between two remote
/// hosts without either agent-forwarding into the source and pulling from the
/// destination, or standing up a direct connection between them — both of
/// which assume network reachability and trust that a workbench pointed at
/// unrelated boxes has no business assuming. So the bytes relay through a
/// local staging file: download from the source, upload to the destination,
/// remove the staging file on every path out.
///
/// The staging file lives in a per-transfer temp directory rather than beside
/// either endpoint. It never has the destination's name, so an interrupted
/// relay cannot leave something at the destination wearing the real filename
/// (the upload itself is what makes that guarantee — see `SFTPClient.upload`).
enum RemoteRelayTransfer {

    // MARK: - Inputs

    struct Source {
        let entry: SessionEntry
        /// Absolute path on the source host.
        let remotePath: String
        let name: String
        let size: Int

        var directory: String {
            let parent = (remotePath as NSString).deletingLastPathComponent
            return parent.isEmpty ? "/" : parent
        }
    }

    struct Destination {
        let entry: SessionEntry
        /// Absolute directory on the destination host. Resolved before the
        /// relay starts — see `resolveDirectory`.
        let directory: String
    }

    enum Failure: LocalizedError, Equatable {
        /// The file would be copied onto itself.
        case sameLocation
        /// Something with this name is already in the destination directory.
        case nameCollision(String)
        /// Destination is a local shell, container, or mosh session — nothing
        /// for SFTP to talk to.
        case unsupportedDestination(String)

        var errorDescription: String? {
            switch self {
            case .sameLocation:
                return "That file is already in this directory."
            case .nameCollision(let name):
                return "\(name) already exists on the destination. Rename or remove it first."
            case .unsupportedDestination(let host):
                return "\(host) has no file browser — host-to-host copy needs a plain SSH session."
            }
        }
    }

    // MARK: - Injectable operations
    //
    // The relay's decisions (where does it land, may it proceed, is the
    // staging file always cleaned up) are worth testing without two live SSH
    // hosts, so every side effect goes through here.

    struct Operations {
        var pwd: @Sendable (SessionEntry) async throws -> String
        var list: @Sendable (SessionEntry, String) async throws -> [RemoteFile]
        var download: @Sendable (SessionEntry, String, URL) async throws -> Void
        var upload: @Sendable (SessionEntry, URL, String) async throws -> Void

        static let live = Operations(
            pwd: { try await SFTPClient(entry: $0).pwd() },
            list: { try await SFTPClient(entry: $0).list($1) },
            download: { try await SFTPClient(entry: $0).download(remotePath: $1, to: $2) },
            upload: { try await SFTPClient(entry: $0).upload(localURL: $1, toDirectory: $2) }
        )
    }

    // MARK: - Destination resolution

    /// Where a file dropped on a pane should land.
    ///
    /// The pane's shell reports its working directory over OSC 7, which is the
    /// whole point of dropping onto *that* pane — the file arrives where the
    /// user is standing. Sessions whose shell has no integration installed
    /// never report one, so fall back to the SFTP default directory rather
    /// than refusing the drop.
    static func resolveDirectory(
        sessionCurrentDirectory: String?, entry: SessionEntry, operations: Operations = .live
    ) async throws -> String {
        if let reported = sessionCurrentDirectory, !reported.isEmpty { return reported }
        return try await operations.pwd(entry)
    }

    // MARK: - Preflight

    /// Refuses a relay that would be a no-op or would clobber something.
    ///
    /// Same-host drops are allowed on purpose: two panes on one host sitting
    /// in different directories is an ordinary way to move a file about, and
    /// refusing it would be a rule the user has to learn rather than one the
    /// tool enforces for a reason. Only copying a file *onto itself* is
    /// rejected.
    static func preflight(
        source: Source, destination: Destination, existingNames: Set<String>
    ) throws {
        guard destination.entry.supportsFileBrowser else {
            throw Failure.unsupportedDestination(destination.entry.name)
        }
        if source.entry.id == destination.entry.id,
           normalize(source.directory) == normalize(destination.directory) {
            throw Failure.sameLocation
        }
        if existingNames.contains(source.name) {
            throw Failure.nameCollision(source.name)
        }
    }

    /// Trailing slashes are not a difference; `/tmp` and `/tmp/` are one place.
    static func normalize(_ path: String) -> String {
        guard path != "/" else { return "/" }
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? "/" : trimmed
    }

    // MARK: - Staging

    /// A private directory for one relay. Per-transfer rather than a shared
    /// scratch area so two concurrent relays of same-named files from
    /// different hosts cannot collide, and so cleanup is a single recursive
    /// remove that cannot take anything else with it.
    static func makeStagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-relay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    // MARK: - Execution

    /// Runs one relay to completion. Throws on any failure; the staging
    /// directory is removed either way.
    ///
    /// `onPhase` reports which leg is running so the caller can relabel its
    /// progress entry — the download leg has a known total and shows a real
    /// bar, the upload leg does not (batch `sftp` prints no progress) and
    /// shows a spinner, exactly as the existing download and upload paths do.
    static func run(
        source: Source,
        destination: Destination,
        operations: Operations = .live,
        onPhase: @Sendable (Phase) -> Void = { _ in }
    ) async throws {
        try await check(source: source, destination: destination, operations: operations)

        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent(source.name)

        onPhase(.downloading(staged: stagedFile))
        try await operations.download(source.entry, source.remotePath, stagedFile)
        try Task.checkCancellation()

        onPhase(.uploading)
        try await operations.upload(destination.entry, stagedFile, destination.directory)
        onPhase(.finished)
    }

    /// Lists the destination and runs `preflight` against it.
    static func check(
        source: Source, destination: Destination, operations: Operations = .live
    ) async throws {
        let existing = try await operations.list(destination.entry, destination.directory)
        try preflight(
            source: source, destination: destination,
            existingNames: Set(existing.map(\.name))
        )
    }

    // MARK: - Fan-out

    /// What happened to one destination in a fan-out.
    enum Outcome: Equatable {
        case delivered
        /// The file is already there, in that exact directory — dragging onto
        /// a broadcast that includes the source's own pane is an ordinary way
        /// to hit this, so it is a skip rather than a failure.
        case skipped
        case failed(String)
    }

    /// Copies one file to several hosts, downloading it **once**.
    ///
    /// The staging file is the whole reason this is worth having as its own
    /// path: a broadcast to six hosts otherwise means six downloads of the
    /// same bytes over the same link. One download feeds every upload.
    ///
    /// A destination that fails does not stop the others. Uploads run in
    /// sequence rather than concurrently — each one is an `sftp` process, and
    /// a fan-out to a large group would otherwise open that many at once,
    /// against a link whose upstream they are all sharing anyway.
    static func runFanOut(
        source: Source,
        destinations: [Destination],
        operations: Operations = .live,
        onPhase: @Sendable (Phase) -> Void = { _ in },
        onDeliveryStarted: @Sendable (Destination, Int, Int) -> Void = { _, _, _ in },
        onDestination: @Sendable (Destination, Outcome) -> Void = { _, _ in }
    ) async throws -> [(Destination, Outcome)] {
        guard !destinations.isEmpty else { return [] }

        // Preflight everything first, so a group where one host already has
        // the file does not download megabytes before saying so.
        var eligible: [Destination] = []
        var results: [(Destination, Outcome)] = []
        for destination in destinations {
            do {
                try await check(source: source, destination: destination, operations: operations)
                eligible.append(destination)
            } catch Failure.sameLocation {
                results.append((destination, .skipped))
                onDestination(destination, .skipped)
            } catch {
                let outcome = Outcome.failed(error.localizedDescription)
                results.append((destination, outcome))
                onDestination(destination, outcome)
            }
        }
        guard !eligible.isEmpty else { return results }

        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent(source.name)

        onPhase(.downloading(staged: stagedFile))
        try await operations.download(source.entry, source.remotePath, stagedFile)
        try Task.checkCancellation()

        onPhase(.uploading)
        for (index, destination) in eligible.enumerated() {
            onDeliveryStarted(destination, index + 1, eligible.count)
            do {
                try Task.checkCancellation()
                try await operations.upload(destination.entry, stagedFile, destination.directory)
                results.append((destination, .delivered))
                onDestination(destination, .delivered)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let outcome = Outcome.failed(error.localizedDescription)
                results.append((destination, outcome))
                onDestination(destination, outcome)
            }
        }
        onPhase(.finished)
        return results
    }

    /// Sends a file that is **already local** to several hosts.
    ///
    /// A Finder drag needs no download leg — the dropped file is the staging
    /// file — so this is the fan-out without its first half. It deliberately
    /// does not copy into a staging directory first: the source is a file the
    /// user already has, and duplicating a large one to upload it would cost
    /// disk for nothing.
    static func runLocalFanOut(
        localURL: URL,
        name: String,
        destinations: [Destination],
        operations: Operations = .live,
        onDeliveryStarted: @Sendable (Destination, Int, Int) -> Void = { _, _, _ in },
        onDestination: @Sendable (Destination, Outcome) -> Void = { _, _ in }
    ) async throws -> [(Destination, Outcome)] {
        guard !destinations.isEmpty else { return [] }

        var eligible: [Destination] = []
        var results: [(Destination, Outcome)] = []
        for destination in destinations {
            do {
                guard destination.entry.supportsFileBrowser else {
                    throw Failure.unsupportedDestination(destination.entry.name)
                }
                let existing = try await operations.list(
                    destination.entry, destination.directory
                )
                if existing.contains(where: { $0.name == name }) {
                    throw Failure.nameCollision(name)
                }
                eligible.append(destination)
            } catch {
                let outcome = Outcome.failed(error.localizedDescription)
                results.append((destination, outcome))
                onDestination(destination, outcome)
            }
        }

        for (index, destination) in eligible.enumerated() {
            onDeliveryStarted(destination, index + 1, eligible.count)
            do {
                try Task.checkCancellation()
                try await operations.upload(destination.entry, localURL, destination.directory)
                results.append((destination, .delivered))
                onDestination(destination, .delivered)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let outcome = Outcome.failed(error.localizedDescription)
                results.append((destination, outcome))
                onDestination(destination, outcome)
            }
        }
        return results
    }

    enum Phase: Equatable {
        /// Carries the staging file so a caller can watch it grow. Batch
        /// `sftp` prints no progress, but the listing already gave us the
        /// size, so polling the partial file yields a real percentage — the
        /// same trick the browser's own downloads use.
        case downloading(staged: URL)
        case uploading
        case finished
    }

    /// Where the staging file for `name` sits inside `directory`. Exposed so
    /// a progress poller can watch it grow during the download leg.
    static func stagedFile(in directory: URL, name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}
