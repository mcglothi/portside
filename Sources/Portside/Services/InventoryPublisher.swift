import Foundation

/// The git half of publishing: a working clone separate from the one
/// subscribers read, a branch, a commit, a push — and nothing a forge API
/// would be needed for. Blocking by design; callers run it off the main thread.
///
/// Rules, each one a lesson from someone else's tool:
/// - **Its own clone.** The subscriber clone is what the sidebar shows; a
///   publish half-done, rejected, or awaiting review must never change it.
/// - **Never `--force`.** A rejected push — someone pushed first, or the
///   branch is protected — is reported in git's own words. Insomnia's docs
///   make the same point: branch protection is enforced, and the pattern is
///   to push a branch and merge on the forge.
/// - **Never prompts**, the same environment as `InventoryGit`.
/// - **The user's own identity.** `user.useConfigOnly` makes git refuse rather
///   than invent an author from the hostname.
enum InventoryPublisher {
    typealias Failure = InventoryGit.Failure

    enum Mode: Equatable {
        /// Push a new branch and hand over a pull-request link. The default.
        case branch
        /// Fast-forward the source's own branch. Opt-in, per source.
        case direct
    }

    struct Result: Equatable {
        /// The branch pushed to.
        var branch: String
        var commit: String
        /// The forge's "open a pull request" page, when there is one to open.
        var pullRequestURL: URL?
        /// The source's branch didn't exist yet (a brand-new repository), so
        /// this publish created it — there was nothing to review against.
        var createdSourceBranch: Bool
    }

    /// Where the publishing clone lives for a source: beside the subscriber
    /// clone, never inside it.
    static func directory(for sourceID: UUID, in sourcesDirectory: URL) -> URL {
        sourcesDirectory.appendingPathComponent("\(sourceID.uuidString).publish", isDirectory: true)
    }

    /// Clones (or fetches) the source into the publishing directory.
    /// Returns whether the source's branch exists on the remote yet.
    @discardableResult
    static func fetch(_ source: InventorySource, into directory: URL) throws -> Bool {
        if let problem = source.validationProblem { throw Failure(message: problem) }
        let remote = source.remote.trimmingCharacters(in: .whitespaces)
        let fm = FileManager.default
        let hasClone = fm.fileExists(atPath: directory.appendingPathComponent(".git").path)
        if !hasClone || (try? InventoryGit.run(["remote", "get-url", "origin"], in: directory)) != remote {
            try? fm.removeItem(at: directory)
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Not --single-branch: publishing makes branches of its own.
            try InventoryGit.run(["clone", "--quiet", "--", remote, directory.path], in: nil)
        } else {
            try InventoryGit.run(["fetch", "--quiet", "--prune", "origin"], in: directory)
        }
        return (try? InventoryGit.run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(source.ref)"],
                                      in: directory)) != nil
    }

    /// The manifest as it stands on the remote branch, without checking
    /// anything out. Nil when the branch or the file doesn't exist yet.
    static func remoteManifest(_ source: InventorySource, in directory: URL) -> Data? {
        guard let parts = InventorySource.normalizedManifestPath(source.path) else { return nil }
        let spec = "origin/\(source.ref):" + parts.joined(separator: "/")
        guard let text = try? InventoryGit.runFull(["show", spec], in: directory).out else { return nil }
        return Data(text.utf8)
    }

    /// Commits `manifest` and pushes it.
    ///
    /// `branchName` is used in `.branch` mode; the caller names it so it can be
    /// shown before anything happens.
    /// What the publish was reviewed against: `.at(tip)` makes it refuse if
    /// the team's branch has moved since (`nil` tip: it didn't exist yet).
    enum Reviewed: Equatable { case unchecked, at(String?) }

    /// The team branch's current commit in a fetched clone, or nil.
    static func tip(_ source: InventorySource, in directory: URL) -> String? {
        try? InventoryGit.run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(source.ref)"], in: directory)
    }

    static func publish(_ source: InventorySource, manifest: Data, message: String, mode: Mode,
                        branchName: String, reviewed: Reviewed = .unchecked, in directory: URL) throws -> Result {
        guard let parts = InventorySource.normalizedManifestPath(source.path) else {
            throw Failure(message: "The manifest path must be a file inside the repository.")
        }
        guard !branchName.hasPrefix("-"), !branchName.contains(".."),
              !branchName.contains(where: { $0.isWhitespace }) else {
            throw Failure(message: "That isn't a usable branch name.")
        }
        let sourceBranchExists = try fetch(source, into: directory)
        // The manifest was merged against the team's version as reviewed. If
        // a teammate pushed since, `checkout -B` below would start from their
        // new commit and this file would quietly undo what they changed.
        if case .at(let reviewedTip) = reviewed, tip(source, in: directory) != reviewedTip {
            throw Failure(message: "The team's inventory changed since you reviewed it. Open Publish Changes "
                + "again to see what changed, then publish.")
        }

        // Start from the team's latest, or — for an empty repository — from
        // nothing at all.
        if sourceBranchExists {
            try InventoryGit.run(["checkout", "--quiet", "-B", branchName, "origin/\(source.ref)"], in: directory)
        } else {
            try InventoryGit.run(["checkout", "--quiet", "--orphan", branchName], in: directory)
            _ = try? InventoryGit.run(["rm", "-r", "--quiet", "--cached", "."], in: directory)
        }

        let file = parts.reduce(directory) { $0.appendingPathComponent($1) }
        // The same containment rule reading has: never write through a symlink
        // the repository put there. Checked before anything is created —
        // `createDirectory` follows a symlinked folder, so checking after it
        // had already made folders wherever the link pointed.
        var walked = directory
        for part in parts.dropLast() {
            walked = walked.appendingPathComponent(part)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: walked.path)) != nil {
                throw Failure(message: "The manifest path runs through a symlink in the repository; "
                    + "refusing to write through it.")
            }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == root || parent.hasPrefix(root + "/") else {
            throw Failure(message: "The manifest path leads outside the repository.")
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
            throw Failure(message: "The manifest in the repository is a symlink; refusing to write through it.")
        }
        try manifest.write(to: file, options: .atomic)

        let relative = parts.joined(separator: "/")
        try InventoryGit.run(["add", "--", relative], in: directory)
        let staged = try InventoryGit.run(["diff", "--cached", "--name-only"], in: directory)
        guard !staged.isEmpty else {
            throw Failure(message: "Nothing to publish: the repository already has exactly this.")
        }
        do {
            try InventoryGit.run(["-c", "user.useConfigOnly=true", "commit", "--quiet", "-m", message],
                                 in: directory)
        } catch let failure as Failure where failure.message.contains("user.email")
            || failure.message.contains("Please tell me who you are") {
            throw Failure(message: "git doesn't know who you are, so nothing was committed. Set it once with "
                          + "`git config --global user.name \"Your Name\"` and `git config --global user.email you@example.com`.")
        }
        let commit = String(try InventoryGit.run(["rev-parse", "HEAD"], in: directory).prefix(8))

        // A brand-new repository: the first version goes straight onto the
        // source branch — there's nothing for a pull request to compare with.
        let target = (mode == .direct || !sourceBranchExists) ? source.ref : branchName
        let push = try InventoryGit.runFull(["push", "--porcelain", "origin", "HEAD:refs/heads/\(target)"],
                                            in: directory)
        let url = target == source.ref ? nil
            : pullRequestURL(fromPushOutput: push.err, remote: source.remote, base: source.ref, head: target)
        return Result(branch: target, commit: commit, pullRequestURL: url,
                      createdSourceBranch: !sourceBranchExists)
    }

    /// The forge's own "create a pull/merge request" link from `git push`'s
    /// output — GitHub, GitLab, Gitea and Bitbucket all print one — or, for a
    /// GitHub remote that didn't, the documented compare URL.
    static func pullRequestURL(fromPushOutput output: String, remote: String, base: String, head: String) -> URL? {
        for line in output.split(separator: "\n") where line.hasPrefix("remote:") {
            if let range = line.range(of: #"https://\S+"#, options: .regularExpression),
               let url = URL(string: String(line[range])) {
                return url
            }
        }
        guard let repo = githubRepo(remote) else { return nil }
        let encode = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
        return URL(string: "https://github.com/\(repo)/compare/\(encode(base))...\(encode(head))?quick_pull=1")
    }

    /// `owner/repo` for a GitHub remote in any of its spellings.
    static func githubRepo(_ remote: String) -> String? {
        let patterns = [#"^git@github\.com:([^/\s]+/[^/\s]+?)(\.git)?$"#,
                        #"^ssh://git@github\.com/([^/\s]+/[^/\s]+?)(\.git)?$"#,
                        #"^https://github\.com/([^/\s]+/[^/\s]+?)(\.git)?/?$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: remote, range: NSRange(remote.startIndex..., in: remote)),
                  let range = Range(match.range(at: 1), in: remote) else { continue }
            return String(remote[range])
        }
        return nil
    }

    /// `portside/<who>-<yyyymmdd-hhmmss>-<4 hex>`: readable on the forge and
    /// sortable. The suffix keeps two publishes in the same second apart —
    /// with minutes alone, a second publish reset the first's still-open
    /// branch and its push was refused until the clock moved on.
    static func branchName(user: String = NSUserName(), date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let who = user.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let suffix = String(format: "%04x", UInt16.random(in: .min ... .max))
        return "portside/\(who.isEmpty ? "update" : who)-\(f.string(from: date))-\(suffix)"
    }
}
