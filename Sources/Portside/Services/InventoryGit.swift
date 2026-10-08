import Foundation

/// The only git Portside does: clone a shared inventory, fast-forward it, read
/// one file out of it. Shells out to `/usr/bin/git`, the same "lean on the
/// stack that already works" choice as `/usr/bin/ssh` — so every forge and every
/// auth setup the user's git already handles just works, and none of it is
/// Portside's to maintain.
///
/// Blocking by design. Callers run it off the main thread.
enum InventoryGit {
    struct Failure: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    struct Result: Equatable {
        /// Short hash of the commit the clone now sits at.
        var commit: String
        /// Whether this run moved it.
        var changed: Bool
    }

    static let executable = "/usr/bin/git"
    static let timeout: TimeInterval = 60

    /// Clones `source` into `directory` if it isn't there yet, otherwise
    /// fetches and fast-forwards it.
    ///
    /// **Fast-forward only, never reset.** A shared source whose history was
    /// rewritten is a source whose contents changed in a way nobody reviewed
    /// as a change — a force-push is exactly how a host would be quietly
    /// slipped into everyone's sidebar. So it is refused and reported, and
    /// accepting it is an explicit act: remove the source and add it again.
    static func sync(_ source: InventorySource, into directory: URL) throws -> Result {
        if let problem = source.validationProblem { throw Failure(message: problem) }
        let remote = source.remote.trimmingCharacters(in: .whitespaces)
        let fm = FileManager.default

        let hasClone = fm.fileExists(atPath: directory.appendingPathComponent(".git").path)
        if hasClone, (try? run(["remote", "get-url", "origin"], in: directory)) == remote {
            let before = try run(["rev-parse", "HEAD"], in: directory)
            try run(["fetch", "--quiet", "origin", source.ref], in: directory)
            do {
                try run(["merge", "--ff-only", "--quiet", "FETCH_HEAD"], in: directory)
            } catch {
                throw Failure(message: "The source's history no longer follows on from the copy here "
                    + "(a force-push or rewritten branch), so it wasn't updated. "
                    + "Remove the source and add it again to accept the new history.")
            }
            let after = try run(["rev-parse", "HEAD"], in: directory)
            return Result(commit: String(after.prefix(8)), changed: before != after)
        }

        // No clone, a half-finished one, or the remote was edited: start over.
        // The directory is Portside's own, under the library's `sources/`.
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // `--` ends option parsing, so even a remote that slipped past
        // validation can't be read as one.
        try run(["clone", "--quiet", "--single-branch", "--branch", source.ref, "--", remote, directory.path],
                in: nil)
        let head = try run(["rev-parse", "HEAD"], in: directory)
        return Result(commit: String(head.prefix(8)), changed: true)
    }

    /// The manifest's bytes, refusing anything that resolves outside the
    /// clone — a manifest path is plain text in the user's settings, but a
    /// *symlink* in the repository is the publisher's choice, and following
    /// one could read any file this Mac's user can.
    static func readManifest(_ source: InventorySource, in directory: URL) throws -> Data {
        guard let parts = InventorySource.normalizedManifestPath(source.path) else {
            throw Failure(message: "The manifest path must be a file inside the repository.")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let file = parts.reduce(directory) { $0.appendingPathComponent($1) }
            .resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root + "/") else {
            throw Failure(message: "The manifest points outside the repository.")
        }
        guard let data = FileManager.default.contents(atPath: file.path) else {
            throw Failure(message: "No \(source.path) on \(source.ref) in that repository.")
        }
        return data
    }

    /// Runs git and returns trimmed stdout, or throws with git's own stderr.
    @discardableResult
    static func run(_ args: [String], in directory: URL?) throws -> String {
        try runFull(args, in: directory).out
    }

    /// `run`, keeping stderr too: a push reports the forge's "create a pull
    /// request" link there, on success.
    static func runFull(_ args: [String], in directory: URL?) throws -> (out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // Belt and braces on top of git's defaults: no ext:: transport, and
        // no hooks — none come with a clone, and none should ever run here.
        var full = ["-c", "protocol.ext.allow=never", "-c", "core.hooksPath=/dev/null"]
        if let directory { full += ["-C", directory.path] }
        process.arguments = full + args

        var env = ProcessInfo.processInfo.environment
        // Never stop to ask. A credential prompt has no terminal to appear in
        // and would hang the sync until the timeout; failing says what's wrong.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        if env["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        }
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch {
            throw Failure(message: "Couldn't run git: \(error.localizedDescription)")
        }

        let errBox = DataBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            drained.leave()
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        deadline.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw Failure(message: "git took longer than \(Int(timeout)) seconds and was stopped.")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errBox.data, as: UTF8.self)
                .split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
                .joined(separator: " ")
            throw Failure(message: message.isEmpty ? "git exited with status \(process.terminationStatus)." : message)
        }
        return (String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                String(decoding: errBox.data, as: UTF8.self))
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}
