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
        let existing = try await operations.list(destination.entry, destination.directory)
        try preflight(
            source: source, destination: destination,
            existingNames: Set(existing.map(\.name))
        )

        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent(source.name)

        onPhase(.downloading)
        try await operations.download(source.entry, source.remotePath, stagedFile)
        try Task.checkCancellation()

        onPhase(.uploading)
        try await operations.upload(destination.entry, stagedFile, destination.directory)
        onPhase(.finished)
    }

    enum Phase: Equatable {
        case downloading, uploading, finished
    }

    /// Where the staging file for `name` sits inside `directory`. Exposed so
    /// a progress poller can watch it grow during the download leg.
    static func stagedFile(in directory: URL, name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}
