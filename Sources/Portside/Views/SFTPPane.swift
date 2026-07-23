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
            # Portside: report the working directory so its SFTP pane can follow `cd` (https://github.com/mcglothi/portside)
            case "$PROMPT_COMMAND" in
              *__portside_osc7*) ;;
              *) PROMPT_COMMAND='printf "\033]7;file://%s%s\033\\" "${HOSTNAME:-$(hostname)}" "$PWD"'"${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
            esac
            """#
        case .zsh:
            return #"""
            # Portside: report the working directory so its SFTP pane can follow `cd` (https://github.com/mcglothi/portside)
            autoload -Uz add-zsh-hook 2>/dev/null
            __portside_osc7() { printf '\033]7;file://%s%s\033\\' "${HOST:-$(hostname)}" "$PWD" }
            add-zsh-hook precmd __portside_osc7 2>/dev/null
            """#
        }
    }

    var rcFile: String { "~/.\(rawValue)rc" }

    /// Appends the snippet to the host's rc file over ssh — idempotent (a
    /// second install is a no-op, detected via the marker already baked into
    /// the snippet text) and reuses the interactive session's ControlMaster
    /// socket, so there's no extra auth prompt.
    func install(on entry: SessionEntry) async throws {
        let remoteCommand = """
        f=\(rcFile); grep -qF '__portside_osc7' "$f" 2>/dev/null || cat >> "$f" <<'PORTSIDE_EOF'
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

    init(entry: SessionEntry) {
        self.entry = entry
        self.client = SFTPClient(entry: entry)
    }

    var visibleFiles: [RemoteFile] {
        showHidden ? files : files.filter { !$0.name.hasPrefix(".") }
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
        await withBusy {
            // A drop before the first listing lands leaves `path` empty, which
            // would send the file to sftp's default dir and list the wrong one.
            let target = self.path.isEmpty ? try await self.client.pwd() : self.path
            for url in urls {
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

    func downloadToDownloads(_ file: RemoteFile) async {
        await withBusy {
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
            try await self.client.download(remotePath: self.join(file.name), to: target)
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
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }
}

struct SFTPPaneView: View {
    @ObservedObject var model: SFTPBrowserModel
    @ObservedObject var session: TerminalSession
    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var confirmingDelete: RemoteFile?
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

    /// Always visible (not hover-dependent, and not just an empty-directory
    /// placeholder) so drag/drop stays discoverable once a folder has content.
    private var hintBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.arrow.down.circle")
            Text("Drag files here to upload, or drag a file out to download")
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
        List(model.visibleFiles) { file in
            row(for: file)
                .gesture(
                    TapGesture(count: 2).onEnded {
                        Task { await model.navigate(to: file) }
                    }
                )
                .contextMenu {
                    if file.isDirectory || file.isSymlink {
                        Button("Open") {
                            Task { await model.navigate(to: file) }
                        }
                    }
                    if !file.isDirectory {
                        Button("Download to ~/Downloads") {
                            Task { await model.downloadToDownloads(file) }
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
            Task { await model.upload(urls) }
            return true
        }
        .overlay {
            if model.visibleFiles.isEmpty && !model.isBusy && model.errorMessage == nil {
                Text("Empty directory\nDrop files here to upload")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
        }
    }

    /// A remote row. Files are draggable out to Finder/Desktop via a file
    /// promise (downloaded on drop); directories aren't draggable.
    @ViewBuilder
    private func row(for file: RemoteFile) -> some View {
        if file.isDirectory {
            RemoteFileRow(file: file)
        } else {
            RemoteFileRow(file: file)
                .onDrag { dragProvider(for: file) }
        }
    }

    /// An item provider backed by a lazy file promise: the file is downloaded
    /// only when the drop target (Finder) asks for it. The download runs on a
    /// detached task with a fresh SFTPClient (reusing the ControlMaster socket)
    /// so it never touches the main actor the drag's run loop is holding.
    private func dragProvider(for file: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        let spec = model.dragSpec(for: file)
        // Register as generic data so Finder uses the exact suggested filename.
        // Using the file's specific UTI makes Finder re-append the type's
        // preferred extension (index.html -> index.html.html) and can even
        // rewrite it (.htm -> .html), so we preserve the name verbatim instead.
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all
        ) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task.detached {
                do {
                    let client = SFTPClient(entry: spec.entry)
                    let dir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("portside-drag-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let local = dir.appendingPathComponent(spec.name)
                    try await client.download(remotePath: spec.remotePath, to: local)
                    progress.completedUnitCount = 1
                    completion(local, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }
}

struct RemoteFileRow: View {
    let file: RemoteFile

    private var icon: String {
        if file.isSymlink { return "arrow.triangle.turn.up.right.circle" }
        return file.isDirectory ? "folder.fill" : "doc"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if !file.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .help("\(file.permissions)  \(file.dateText)")
    }
}
