import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A one-line, opt-in addition to a host's own `.bashrc`/`.zshrc` that reports
/// its working directory via OSC 7 on every prompt — the same "shell
/// integration" convention iTerm2, VS Code, and WezTerm all use for this exact
/// feature. Portside can't reliably force this from the ssh command line
/// (fragile across shells/configs), so it's copy-paste, applied once per host.
enum ShellIntegrationSnippet: String, CaseIterable, Identifiable {
    case bash, zsh

    var id: String { rawValue }
    var label: String { rawValue == "bash" ? "Bash" : "Zsh" }

    var text: String {
        switch self {
        case .bash:
            return #"""
            # Portside shell integration v3 (https://github.com/mcglothi/portside)
            # __portside_integration_v3 -- version marker; the installer greps for this
            # Reports the working directory (OSC 7) so the SFTP pane can follow `cd`,
            # and command boundaries (OSC 133) so commands can be timestamped.
            #
            # Interactive shells only. bash reads this file for NON-interactive
            # remote shells as well, and the DEBUG trap below fires there too --
            # its OSC 133 output then lands in whatever binary protocol is using
            # the channel. sftp reports that as "Received message too long", with
            # a length that decodes back to the escape's own first four bytes.
            case "$-" in
              *i*)
                __portside_preexec() {
                  [ -n "$COMP_LINE" ] && return              # tab completion, not a command
                  [ "$BASH_COMMAND" = "$PROMPT_COMMAND" ] && return
                  [ -n "$__portside_running" ] && return     # DEBUG fires per simple command
                  __portside_running=1
                  printf '\033]133;C\007'
                  printf '\033]133;E;%s\007' "$(printf '%s' "$BASH_COMMAND" | base64 | tr -d '\n')"
                }
                __portside_precmd() {
                  local __portside_ret=$?
                  if [ -n "$__portside_running" ]; then
                    printf '\033]133;D;%s\007' "$__portside_ret"
                    unset __portside_running
                  fi
                  printf '\033]7;file://%s%s\033\\' "${HOSTNAME:-$(hostname)}" "$PWD"
                  printf '\033]133;A\007'
                }
                case "$PROMPT_COMMAND" in
                  *__portside_precmd*) ;;
                  *) PROMPT_COMMAND="__portside_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
                esac
                trap '__portside_preexec' DEBUG
                ;;
              *)
                # Repairs a v2 block sitting earlier in this file, which set that
                # trap unconditionally. Appending this version is not enough on
                # its own -- v2's trap is already armed by the time we get here,
                # so it has to be disarmed. Only ever clears Portside's own trap.
                case "$(trap -p DEBUG 2>/dev/null)" in
                  *__portside_preexec*) trap - DEBUG ;;
                esac
                ;;
            esac
            """#
        case .zsh:
            return #"""
            # Portside shell integration v3 (https://github.com/mcglothi/portside)
            # __portside_integration_v3 -- version marker; the installer greps for this
            # Reports the working directory (OSC 7) so the SFTP pane can follow `cd`,
            # and command boundaries (OSC 133) so commands can be timestamped.
            #
            # Guarded to interactive shells to match bash, where an unguarded
            # DEBUG trap corrupted sftp. zsh was never exposed to that: it reads
            # .zshenv rather than .zshrc for non-interactive shells, and precmd
            # and preexec do not fire without a prompt. The guard is here so the
            # two snippets cannot drift apart on the point that mattered.
            case "$-" in
              *i*)
            autoload -Uz add-zsh-hook 2>/dev/null
            __portside_osc7() {
              local __portside_ret=$?
              if [[ -n "$__portside_running" ]]; then
                printf '\033]133;D;%s\007' "$__portside_ret"
                unset __portside_running
              fi
              printf '\033]7;file://%s%s\033\\' "${HOST:-$(hostname)}" "$PWD"
              printf '\033]133;A\007'
            }
            __portside_preexec() {
              __portside_running=1
              printf '\033]133;C\007'
              printf '\033]133;E;%s\007' "$(printf '%s' "$1" | base64 | tr -d '\n')"
            }
            add-zsh-hook precmd __portside_osc7 2>/dev/null
            add-zsh-hook preexec __portside_preexec 2>/dev/null
                ;;
            esac
            """#
        }
    }

    var rcFile: String { "~/.\(rawValue)rc" }

    /// Disarms a v2 block already in the file, before the v3 block is appended.
    ///
    /// Appending alone cannot fix an affected host. v2's `trap ... DEBUG` is
    /// armed the moment its line runs, and the DEBUG trap fires *before* every
    /// subsequent command — including the first command of the v3 block that
    /// would disarm it. The one OSC 133 burst is already on the wire by then,
    /// which is exactly the four bytes sftp chokes on. Verified by sourcing v2
    /// and v3 in that order under a real non-interactive bash: still corrupt.
    ///
    /// So the line itself has to go. The match is anchored to column zero,
    /// which only v2 wrote — v3's own `trap` sits indented inside its
    /// interactive guard and is left alone. A backup is kept beside the file,
    /// and the rewrite goes through `cat >` rather than `mv` so the original
    /// inode, permissions and ownership survive.
    ///
    /// zsh needs none of this: it never set a DEBUG trap.
    var repairCommand: String {
        switch self {
        case .zsh:
            return "# zsh needs no repair: it never set a DEBUG trap."
        case .bash:
            return #"""
            if grep -q "^trap '__portside_preexec' DEBUG$" "$f" 2>/dev/null; then
              cp "$f" "$f.portside-backup" 2>/dev/null
              sed "s|^trap '__portside_preexec' DEBUG$|# (disabled by Portside v3: this trap also fired in non-interactive shells, corrupting sftp)|" "$f" > "$f.portside-tmp" \
                && cat "$f.portside-tmp" > "$f" \
                && rm -f "$f.portside-tmp"
            fi
            """#
        }
    }

    /// Appends the snippet to the host's rc file over ssh — idempotent (a
    /// second install is a no-op, detected via the marker already baked into
    /// the snippet text) and reuses the interactive session's ControlMaster
    /// socket, so there's no extra auth prompt.
    ///
    /// The marker is version-stamped, and the installer greps for the *current*
    /// version so an older block does not count as installed. v1 only reported
    /// the working directory; v2 added command markers; **v3 fixes a bug that
    /// broke SFTP on hosts carrying v2**, so re-running the install is how an
    /// affected host is repaired.
    ///
    /// v3 has to do more than append, because v2's unguarded DEBUG trap is
    /// already armed by the time the appended block runs — see the snippet's
    /// non-interactive branch, which disarms it.
    ///
    /// Older blocks are left in place rather than edited out. They have a start
    /// marker but no end marker, so deleting a range from someone's `.bashrc`
    /// would be guesswork on a file we do not own. What survives is inert: on
    /// zsh the newer functions replace the old ones by name and `add-zsh-hook`
    /// will not double-register, and on bash the leftover PROMPT_COMMAND entry
    /// reports the same directory twice per prompt, which nothing notices.
    func install(on entry: SessionEntry) async throws {
        let remoteCommand = """
        f=\(rcFile)
        \(repairCommand)
        grep -qF '__portside_integration_v3' "$f" 2>/dev/null || cat >> "$f" <<'PORTSIDE_EOF'
        \(text)
        PORTSIDE_EOF
        """
        let result = try await Self.runRemote(remoteCommand, on: entry)
        guard result.status == 0 else {
            let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SFTPClientError.failed(detail.isEmpty ? "ssh exited with status \(result.status)" : detail)
        }
    }

    /// Best-effort detection of which shell is actually running, so the menu
    /// can default to it instead of making the user guess. `ssh host 'cmd'`
    /// runs `cmd` through the account's configured login shell — the same
    /// one the interactive session started in — so asking that shell to name
    /// itself is a reasonable proxy, though it won't notice a shell manually
    /// launched from within the session (e.g. typing `zsh` after logging
    /// into bash). Uses `$0` rather than `ps -p $$`: when a `-c` script is a
    /// single trailing command, some shells `exec()` straight into it instead
    /// of forking a child, replacing themselves in place under the same PID
    /// — so `ps -p $$` ends up reporting `ps` itself, not the shell. `$0` is
    /// substituted by the shell before that fork/exec strategy applies, so it
    /// isn't affected.
    static func detect(on entry: SessionEntry) async -> ShellIntegrationSnippet? {
        let result: (status: Int32, out: String, err: String)
        do {
            result = try await runRemote("echo $0", on: entry)
        } catch {
            if debugLogging { NSLog("Portside shell-detect » process launch failed: \(error)") }
            return nil
        }
        let name = result.out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if debugLogging {
            NSLog("Portside shell-detect » status=%d name=%@ stdout=%@ stderr=%@",
                  result.status, name, result.out, result.err)
        }
        guard result.status == 0 else { return nil }
        if name.contains("zsh") { return .zsh }
        if name.contains("bash") { return .bash }
        return nil
    }

    /// Set PORTSIDE_SFTP_DEBUG=1 to log the raw detect/install ssh commands
    /// and output to Console.app — mirrors SFTPClient's own debug flag.
    private static let debugLogging = ProcessInfo.processInfo.environment["PORTSIDE_SFTP_DEBUG"] != nil

    private static func runRemote(
        _ command: String, on entry: SessionEntry
    ) async throws -> (status: Int32, out: String, err: String) {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        args += SSHControl.options
        args += entry.sshArgs
        args.append(command)
        return try await SFTPClient.runProcess("/usr/bin/ssh", args, stdin: "")
    }
}

@MainActor
final class SFTPBrowserModel: ObservableObject {
    let entry: SessionEntry
    private let client: SFTPClient

    @Published var path = ""
    @Published var files: [RemoteFile] = []
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var showHidden = false

    private var loaded = false
    private var transferTask: Task<Void, Never>?

    init(entry: SessionEntry) {
        self.entry = entry
        self.client = SFTPClient(entry: entry)
    }

    var visibleFiles: [RemoteFile] {
        showHidden ? files : files.filter { !$0.name.hasPrefix(".") }
    }

    /// The directory has contents, but the hidden-file filter is hiding all of
    /// them — worth saying, because "Empty directory" over a folder full of
    /// dotfiles sends people hunting for a transfer that actually worked.
    var hasHiddenFilesOnly: Bool {
        !files.isEmpty && visibleFiles.isEmpty
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await withBusy {
            let home = try await self.client.pwd()
            try await self.load(home)
        }
    }

    func navigate(to file: RemoteFile) async {
        guard file.isDirectory || file.isSymlink else { return }
        await withBusy { try await self.load(self.join(file.name)) }
    }

    func navigateUp() async {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        await withBusy { try await self.load(parent.isEmpty ? "/" : parent) }
    }

    /// Follows the terminal's live working directory (OSC 7, reported via
    /// `TerminalSession.hostCurrentDirectoryUpdate`) so `cd` in the shell —
    /// relative or absolute — is reflected here automatically. No-ops if
    /// we're already there or mid-operation (a manual navigation in flight
    /// wins over a stale directory report).
    func followShellDirectory(_ newPath: String) async {
        guard newPath != path, !isBusy else { return }
        await withBusy { try await self.load(newPath) }
    }

    func refresh() async {
        await withBusy { try await self.load(self.path) }
    }

    func upload(_ urls: [URL]) async {
        let id = TransferCenter.shared.begin(
            entryID: entry.id, remotePath: "", label: "Uploading…",
            cancel: { [weak self] in self?.cancelTransfer() }
        )
        defer { TransferCenter.shared.finish(id) }
        await withBusy {
            // A drop before the first listing lands leaves `path` empty, which
            // would send the file to sftp's default dir and list the wrong one.
            let target = self.path.isEmpty ? try await self.client.pwd() : self.path
            for (index, url) in urls.enumerated() {
                // No byte-level progress going out: `sftp put` is silent in
                // batch mode and the remote side can't be polled the way a
                // partially-written local file can. Per-file is honest.
                TransferCenter.shared.relabel(id, urls.count == 1
                    ? "Uploading \(url.lastPathComponent)"
                    : "Uploading \(url.lastPathComponent) (\(index + 1) of \(urls.count))")
                try Task.checkCancellation()
                try await self.client.upload(localURL: url, toDirectory: target)
            }
            try await self.load(target)
        }
    }

    func makeDirectory(named name: String) async {
        guard !name.isEmpty else { return }
        await withBusy {
            try await self.client.mkdir(self.join(name))
            try await self.load(self.path)
        }
    }

    func delete(_ file: RemoteFile) async {
        await withBusy {
            try await self.client.delete(file, in: self.path)
            try await self.load(self.path)
        }
    }

    /// The Sendable pieces a drag-out promise needs. Captured on the main actor
    /// at drag start; the actual download must run OFF the main actor (a Finder
    /// drag spins a nested run loop on the main thread, so a @MainActor download
    /// would deadlock and the promised file would never arrive).
    func dragSpec(for file: RemoteFile) -> (entry: SessionEntry, remotePath: String, name: String) {
        (entry, join(file.name), file.name)
    }

    /// Checks the file out to a local temp copy, opens it in its default app,
    /// and re-uploads it whenever it's saved. See `RemoteFileEditor`.
    func edit(_ file: RemoteFile, using app: URL? = nil, size: Int? = nil) {
        RemoteFileEditor.shared.open(
            name: file.name, remotePath: join(file.name), on: entry,
            using: app, size: size ?? file.size
        )
    }

    func downloadToDownloads(_ file: RemoteFile) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var target = downloads.appendingPathComponent(file.name)
        var counter = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let base = (file.name as NSString).deletingPathExtension
            let ext = (file.name as NSString).pathExtension
            let suffixed = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            target = downloads.appendingPathComponent(suffixed)
            counter += 1
        }
        await download(file, to: target, removePartialOnCancel: true)
    }

    /// Download to a location the user picks. The save panel already handles
    /// "replace existing?", so unlike `downloadToDownloads` this writes exactly
    /// where it's told rather than uniquing the name.
    func save(_ file: RemoteFile, to target: URL) async {
        await download(file, to: target, removePartialOnCancel: true)
    }

    /// Downloads with live progress. `sftp -q` prints none, but the listing
    /// already gave us the size, so watching the partial file grow yields a
    /// real percentage — the same trick the edit checkout uses.
    private func download(_ file: RemoteFile, to target: URL, removePartialOnCancel: Bool) async {
        let remotePath = join(file.name)
        let id = TransferCenter.shared.begin(
            entryID: entry.id, remotePath: remotePath,
            label: "Downloading \(file.name)", total: file.size,
            cancel: { [weak self] in self?.cancelTransfer() }
        )
        let poll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: target.path)[.size] as? Int) ?? nil
                if let size { TransferCenter.shared.update(id, transferred: size) }
            }
        }
        defer {
            poll.cancel()
            TransferCenter.shared.finish(id)
        }

        await withBusy {
            do {
                try await self.client.download(remotePath: self.join(file.name), to: target)
            } catch {
                // Don't leave a truncated file sitting where the user asked for
                // a real one — a half-written download that looks complete is
                // worse than no download.
                if removePartialOnCancel, Task.isCancelled || error is CancellationError {
                    try? FileManager.default.removeItem(at: target)
                }
                throw error
            }
        }
    }

    private func join(_ name: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }

    private func load(_ newPath: String) async throws {
        files = try await client.list(newPath)
        path = newPath
    }

    private func withBusy(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await work()
        } catch {
            // A user-cancelled transfer isn't an error to report at them.
            if !(Task.isCancelled || error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
        isBusy = false
    }

    /// Runs a pane operation as a cancellable unit. Listing a directory is
    /// instant, but a download of a multi-gigabyte file is not — without a
    /// handle on the task there'd be no way to call it off once started.
    func startTransfer(_ work: @escaping () async -> Void) {
        transferTask?.cancel()
        transferTask = Task { await work() }
    }

    func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
        isBusy = false
    }
}

struct SFTPPaneView: View {
    @ObservedObject var model: SFTPBrowserModel
    @ObservedObject var session: TerminalSession
    @ObservedObject private var editor = RemoteFileEditor.shared
    @ObservedObject private var transfers = TransferCenter.shared
    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var confirmingDelete: RemoteFile?
    /// Editing writes back to the host on every save, so a protected host asks
    /// once before the file is checked out — same guardrail shape as MultiExec.
    @State private var confirmingEdit: (file: RemoteFile, app: URL?)?
    /// Left-click highlight. Purely local to the pane — there's no multi-select
    /// or keyboard model here, just "show me which row I'm about to act on".
    @State private var selection: RemoteFile.ID?
    /// The editing notice shrinks to a chip once it's been quiet for a while,
    /// so a long-running edit doesn't permanently eat the pane's height.
    @State private var noticeExpanded = true
    @State private var collapseTask: Task<Void, Never>?
    /// Shown once the pane's had a moment to see whether the shell reports
    /// its directory (OSC 7) at all — offers the opt-in snippet if not.
    @State private var showFollowHint = false
    @State private var installing: ShellIntegrationSnippet?
    @State private var installed: (snippet: ShellIntegrationSnippet, sourced: Bool)?
    @State private var detectedShell: ShellIntegrationSnippet?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showFollowHint {
                followHintBanner
            }
            if let installed {
                installedBanner(installed)
            }
            if let error = model.errorMessage {
                errorBanner(error)
            }
            ForEach(transfers.transfers(for: model.entry.id)) { transfer in
                transferBanner(transfer)
            }
            if !activeEdits.isEmpty {
                editsBanner
            }
            fileList
            Divider()
            hintBar
        }
        .background(.background)
        // `.task` without an `id:` only runs once for this view's lifetime —
        // switching to a different host's (different model instance's) SFTP
        // pane doesn't recreate this view (same position in the tree), so
        // without keying on the model's identity it never re-fires and the
        // new host's listing just sits empty until a manual refresh.
        .task(id: model.entry.id) { await model.loadIfNeeded() }
        .task(id: model.entry.id) {
            // A couple of seconds is enough for the shell to have reached its
            // first prompt if it's going to report a directory at all — avoids
            // flashing the hint before OSC 7 has had any real chance to fire.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if session.currentDirectory == nil { showFollowHint = true }
        }
        .task(id: model.entry.id) {
            detectedShell = await ShellIntegrationSnippet.detect(on: model.entry)
        }
        .onChange(of: session.currentDirectory) { _, new in
            if new != nil { showFollowHint = false }
        }
        .confirmationDialog(
            "Delete \"\(confirmingDelete?.name ?? "")\"?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let file = confirmingDelete {
                    Task { await model.delete(file) }
                }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog(
            "Edit \"\(confirmingEdit?.file.name ?? "")\" on \(model.entry.name)?",
            isPresented: Binding(get: { confirmingEdit != nil }, set: { if !$0 { confirmingEdit = nil } }),
            titleVisibility: .visible
        ) {
            Button("Edit") {
                if let pending = confirmingEdit {
                    model.edit(pending.file, using: pending.app, size: pending.file.size)
                }
                confirmingEdit = nil
            }
            Button("Cancel", role: .cancel) { confirmingEdit = nil }
        } message: {
            Text(editConfirmationMessage)
        }
        // Any change to an edit (opened, saved, failed) re-expands the notice
        // and restarts the quiet timer.
        .onChange(of: latestActivity) { _, _ in
            noticeExpanded = true
            collapseTask?.cancel()
            collapseTask = Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                noticeExpanded = false
            }
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { await model.makeDirectory(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.navigateUp() }
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(model.path == "/" || model.isBusy)
            .help("Parent directory")

            Text(model.path.isEmpty ? "…" : model.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(model.path)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                Button {
                    model.cancelTransfer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel the transfer in progress")
            }

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")

            Menu {
                Button("New Folder…") { showingNewFolder = true }
                Toggle("Show Hidden Files", isOn: $model.showHidden)
                Divider()
                installMenuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(8)
    }

    /// The detected shell (if any) sorts first, so the likely-right choice is
    /// what the user sees without scrolling past the other one.
    private var orderedSnippets: [ShellIntegrationSnippet] {
        guard let detectedShell else { return ShellIntegrationSnippet.allCases }
        return [detectedShell] + ShellIntegrationSnippet.allCases.filter { $0 != detectedShell }
    }

    /// Short and stable — this is also used as the label of a plain inline
    /// `Menu` control in the follow-hint banner, which is squeezed to the
    /// SFTP pane's own (sometimes narrow) width and truncates long text
    /// before you ever get to open it. The "detected" indicator lives on the
    /// menu's *items* instead (see `installMenuItems`), which aren't width
    /// constrained once the dropdown is actually open.
    private var installMenuTitle: String { installing == nil ? "Install…" : "Installing…" }

    /// One flat menu (rather than a submenu per shell) so it stays compact:
    /// four leaf actions, grouped by shell with a divider, the detected
    /// shell's pair marked and sorted first.
    @ViewBuilder
    private var installMenuItems: some View {
        Menu(installMenuTitle) {
            ForEach(orderedSnippets) { snippet in
                let detected = snippet == detectedShell
                Button {
                    install(snippet, sourceNow: false)
                } label: {
                    if detected {
                        Label("\(snippet.label) (Detected)", systemImage: "checkmark")
                    } else {
                        Text(snippet.label)
                    }
                }
                Button("\(snippet.label) (and source now)") { install(snippet, sourceNow: true) }
                if snippet != orderedSnippets.last { Divider() }
            }
        }
        .disabled(installing != nil)
    }

    /// Appends the snippet to the host's rc file over ssh. "Source now" also
    /// sends `source <rcfile>` into this live terminal so it takes effect
    /// immediately, rather than only on the next new shell.
    private func install(_ snippet: ShellIntegrationSnippet, sourceNow: Bool) {
        installing = snippet
        Task {
            do {
                try await snippet.install(on: model.entry)
                installing = nil
                if sourceNow {
                    session.sendText("source \(snippet.rcFile)\r")
                }
                showFollowHint = false
                installed = (snippet, sourceNow)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                installed = nil
            } catch {
                installing = nil
                model.errorMessage = error.localizedDescription
            }
        }
    }

    /// A horizontal banner (text on its own wrapped line, action below) —
    /// putting the action beside the text in one row squeezed it down to a
    /// near-zero width and made it wrap character-by-character.
    private var followHintBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .foregroundStyle(.secondary)
                Text("Can't follow cd here — shell integration not detected.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    showFollowHint = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            installMenuItems
                .font(.caption)
        }
        .padding(8)
        .background(Color.blue.opacity(0.1))
    }

    private func installedBanner(_ result: (snippet: ShellIntegrationSnippet, sourced: Bool)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(result.sourced
                 ? "\(result.snippet.label) integration installed and applied to this session."
                 : "\(result.snippet.label) integration installed — takes effect in new shells.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1))
    }

    /// Inline rather than a modal transfer window: a sheet would block the
    /// browser you're transferring from, and this pane already reports the
    /// edit workflow the same way.
    private func transferBanner(_ transfer: TransferCenter.Transfer) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.label)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                    Text("\(Self.bytes(transfer.transferred)) of \(Self.bytes(transfer.total))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 4)
            Button("Cancel") { transfers.cancel(transfer.id) }
                .buttonStyle(.borderless)
                .font(.caption2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
    }

    private var activeEdits: [RemoteEdit] { editor.edits(for: model.entry.id) }

    private var latestActivity: Date? { activeEdits.map(\.lastActivity).max() }

    /// A failed upload never collapses — the whole point of the notice is that
    /// you find out when a save didn't reach the host. Nor does a transfer in
    /// flight: that's where the progress and the Cancel button live.
    private var mustStayExpanded: Bool {
        activeEdits.contains {
            switch $0.status {
            case .failed, .downloading, .uploading: return true
            case .watching: return false
            }
        }
    }

    /// Files currently checked out for editing, with what's happening to each.
    /// Auto-uploading to a remote host shouldn't be invisible — this is the
    /// only signal that a save just wrote to a live server. After a quiet spell
    /// it collapses to a chip rather than vanishing, so an armed watcher is
    /// never completely hidden.
    @ViewBuilder
    private var editsBanner: some View {
        if noticeExpanded || mustStayExpanded {
            expandedEdits
        } else {
            collapsedEditsChip
        }
    }

    private var collapsedEditsChip: some View {
        Button {
            noticeExpanded = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "pencil.circle.fill")
                    .foregroundStyle(.green)
                Text(activeEdits.count == 1
                     ? "1 file open for editing"
                     : "\(activeEdits.count) files open for editing")
                    .font(.caption)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
        .help("Still watching for saves — click for details")
    }

    private var expandedEdits: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(activeEdits) { edit in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon(for: edit.status))
                        .foregroundStyle(tint(for: edit.status))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(edit.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(statusText(for: edit))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .downloading = edit.status, let fraction = edit.fractionComplete {
                            ProgressView(value: fraction)
                                .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(isTransferring(edit) ? "Cancel" : "Stop") { editor.stop(edit.id) }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .help(isTransferring(edit)
                              ? "Stop the transfer and discard the partial file"
                              : "Stop watching this file and delete the local copy")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1))
    }

    private func icon(for status: RemoteEdit.Status) -> String {
        switch status {
        case .downloading: return "arrow.down.circle"
        case .watching: return "pencil.circle.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(for status: RemoteEdit.Status) -> Color {
        switch status {
        case .downloading, .uploading: return .accentColor
        case .watching: return .green
        case .failed: return .yellow
        }
    }

    private func isTransferring(_ edit: RemoteEdit) -> Bool {
        switch edit.status {
        case .downloading, .uploading: return true
        case .watching, .failed: return false
        }
    }

    private static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func statusText(for edit: RemoteEdit) -> String {
        switch edit.status {
        case .downloading:
            guard edit.totalBytes > 0 else { return "Opening…" }
            return "Downloading \(Self.bytes(edit.transferredBytes)) of \(Self.bytes(edit.totalBytes))"
        case .uploading:
            return "Saving to \(model.entry.name)…"
        case .failed(let message):
            return "Upload failed: \(message)"
        case .watching:
            guard let last = edit.lastUploaded else {
                return "Editing — saves upload automatically"
            }
            let time = last.formatted(date: .omitted, time: .standard)
            let count = edit.uploadCount == 1 ? "Saved once" : "Saved \(edit.uploadCount)×"
            return "\(count) — last at \(time)"
        }
    }

    /// Always visible (not hover-dependent, and not just an empty-directory
    /// placeholder) so drag/drop stays discoverable once a folder has content.
    private var hintBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.arrow.down.circle")
            Text("Double-click a file to edit it · drag to upload or download")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .lineLimit(3)
            Spacer()
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
        .background(Color.yellow.opacity(0.12))
    }

    private var fileList: some View {
        // Selection is tracked by hand rather than with `List(selection:)`:
        // under a selectable List, row-content gestures (the drag-out promise,
        // the double-click) intercept mouse-down before the List sees it, which
        // is the same conflict that produced the host sidebar's long-running
        // click/drag jank before it was rebuilt on NSOutlineView.
        List(model.visibleFiles) { file in
            row(for: file)
                .listRowBackground(
                    selection == file.id
                        ? Color(nsColor: .selectedContentBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        : nil
                )
                .contextMenu {
                    if file.isDirectory || file.isSymlink {
                        Button("Open") {
                            Task { await model.navigate(to: file) }
                        }
                    }
                    if !file.isDirectory {
                        Button("Edit") { edit(file) }
                        editWithMenu(for: file)
                        Divider()
                        Button("Save To…") { saveAs(file) }
                        Button("Download to ~/Downloads") {
                            model.startTransfer { await model.downloadToDownloads(file) }
                        }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        confirmingDelete = file
                    }
                }
        }
        .listStyle(.inset)
        .dropDestination(for: URL.self) { urls, _ in
            // Via startTransfer, not a bare Task, so a dropped 40GB file can be
            // called off the same way a double-clicked one can.
            model.startTransfer { await model.upload(urls) }
            return true
        }
        .overlay {
            if model.visibleFiles.isEmpty && !model.isBusy && model.errorMessage == nil {
                // A directory with only dotfiles in it is not empty, and saying
                // so sends people hunting for a transfer that worked fine.
                if model.hasHiddenFilesOnly {
                    EmptyStateView(
                        icon: "eye.slash",
                        title: "Only hidden files here",
                        detail: "This directory contains nothing but dotfiles. Turn on Show Hidden Files to see them.",
                        compact: true
                    )
                } else {
                    EmptyStateView(
                        icon: "folder",
                        title: "Empty directory",
                        detail: "Drop files here to upload them to this host.",
                        compact: true
                    )
                }
            }
        }
    }

    /// Double-click: descend into directories, edit files. Files used to fall
    /// through `navigate`'s directory guard and do nothing at all.
    private func activate(_ file: RemoteFile) {
        selection = file.id
        if file.isDirectory || file.isSymlink {
            Task { await model.navigate(to: file) }
        } else {
            edit(file)
        }
    }

    /// The apps that can open this file, so switching editors for a one-off is
    /// a menu rather than a trip through /Applications. Built when the menu is
    /// opened, not per redraw — LaunchServices lookups aren't free.
    @ViewBuilder
    private func editWithMenu(for file: RemoteFile) -> some View {
        Menu("Edit With") {
            ForEach(EditorApps.candidates(for: file.name), id: \.path) { app in
                Button {
                    edit(file, using: app)
                } label: {
                    Label {
                        Text(EditorApps.displayName(of: app))
                    } icon: {
                        Image(nsImage: EditorApps.icon(of: app))
                    }
                }
            }
            Divider()
            Button("Other…") { chooseAppThenEdit(file) }
        }
    }

    /// Download to a chosen location. The save panel handles overwrite
    /// confirmation and folder creation, so there's nothing to re-ask here.
    private func saveAs(_ file: RemoteFile) {
        selection = file.id
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        model.startTransfer { await model.save(file, to: target) }
    }

    private func chooseAppThenEdit(_ file: RemoteFile) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        edit(file, using: app)
    }

    /// Editing means downloading the whole file, so a mis-click on something
    /// huge (a model file, a tarball, a VM image) gets caught before any bytes
    /// move — the listing already told us the size for free.
    private func edit(_ file: RemoteFile, using app: URL? = nil) {
        selection = file.id
        let isLarge = file.size > RemoteFileEditor.largeFileThreshold
        if model.entry.isProtected || isLarge {
            confirmingEdit = (file, app)
        } else {
            model.edit(file, using: app)
        }
    }

    private var editConfirmationMessage: String {
        guard let pending = confirmingEdit else { return "" }
        var parts: [String] = []
        if pending.file.size > RemoteFileEditor.largeFileThreshold {
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(pending.file.size), countStyle: .file
            )
            parts.append("This file is \(size). Editing downloads all of it to your Mac first, then uploads it back every time you save. You can cancel the transfer once it starts.")
        }
        if model.entry.isProtected {
            parts.append("This host is protected. Every save in your editor uploads straight back to it.")
        }
        return parts.joined(separator: "\n\n")
    }

    /// A remote row. All mouse handling — select, activate, and the drag-out
    /// file promise — belongs to one AppKit overlay rather than being split
    /// between SwiftUI gestures and a drag source, which is what made the host
    /// sidebar's clicks and drags fight each other for months. Directories get
    /// the same overlay minus the drag.
    private func row(for file: RemoteFile) -> some View {
        RemoteFileRow(file: file, isSelected: selection == file.id)
            .overlay {
                RemoteFileDragSource(
                    file: file,
                    spec: file.isDirectory ? nil : model.dragSpec(for: file),
                    onClick: { selection = file.id },
                    onDoubleClick: { activate(file) }
                )
            }
    }

}

struct RemoteFileRow: View {
    let file: RemoteFile
    var isSelected = false

    private var icon: String {
        if file.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        return file.isDirectory ? "folder.fill" : "doc"
    }

    /// The selected row sits on the system's full-strength selection blue, so
    /// the muted greys that read well against the list background become
    /// nearly illegible on it.
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(
                    isSelected ? Color.white
                        : (file.isDirectory ? Color.accentColor : Color.secondary)
                )
                .frame(width: 16)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 8)
            if !file.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .help("\(file.permissions)  \(file.dateText)")
    }
}
