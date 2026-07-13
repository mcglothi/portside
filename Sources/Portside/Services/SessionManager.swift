import AppKit
import Foundation
import SwiftTerm

/// A terminal view that tees the child process's output to a session log
/// before feeding it to the terminal.
final class LoggingTerminalView: LocalProcessTerminalView {
    var logger: SessionLogger?
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    private var suppressInputMirror = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        logger?.append(slice)
        super.dataReceived(slice: slice)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !suppressInputMirror {
            onUserInput?(data)
        }
        super.send(source: source, data: data)
    }

    func sendMirroredInput(_ data: ArraySlice<UInt8>) {
        suppressInputMirror = true
        super.send(source: self, data: data)
        suppressInputMirror = false
    }
}

/// One live terminal tab: owns the SwiftTerm view and the child process
/// (either `ssh` or a local login shell) running inside it.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let terminalView: LocalProcessTerminalView
    let entry: SessionEntry?
    @Published var title: String
    @Published var isRunning = true
    @Published var includedInMultiExec: Bool
    // Per-terminal find bar (⌘F); drives SwiftTerm's scrollback search.
    @Published var findVisible = false
    @Published var findTerm = ""
    @Published var findCaseSensitive = false

    var environment: HostEnvironment { entry?.environment ?? .none }
    var isProtected: Bool { entry?.isProtected ?? false }

    private var _sftp: SFTPBrowserModel?
    /// Lazy per-session file browser; only for plain SSH hosts (not local
    /// shells or container/pod sessions).
    @MainActor var sftp: SFTPBrowserModel? {
        guard let entry, entry.supportsFileBrowser else { return nil }
        if _sftp == nil {
            _sftp = SFTPBrowserModel(entry: entry)
        }
        return _sftp
    }

    /// Removes any on-disk askpass secret once ssh no longer needs it.
    private var cleanup: (() -> Void)?
    private let logger: SessionLogger?

    init(title: String, executable: String, args: [String], entry: SessionEntry? = nil,
         appearance: TerminalAppearance = .default,
         environment: [String]? = nil, cleanup: (() -> Void)? = nil,
         logger: SessionLogger? = nil) {
        self.title = title
        self.entry = entry
        self.cleanup = cleanup
        self.logger = logger
        // Protected hosts must be opted in to MultiExec explicitly.
        self.includedInMultiExec = !(entry?.isProtected ?? false)
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.logger = logger
        self.terminalView = view
        super.init()
        terminalView.processDelegate = self
        apply(appearance: appearance)
        terminalView.startProcess(executable: executable, args: args, environment: environment)
        // Bound how long the secret lives on disk even if auth stalls.
        if cleanup != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.runCleanup() }
        }
    }

    private func runCleanup() {
        cleanup?()
        cleanup = nil
    }

    /// Flushes and closes the session log (idempotent).
    func closeLog() {
        logger?.close()
    }

    func sendText(_ text: String) {
        terminalView.send(txt: text)
    }

    func sendMirroredInput(_ data: ArraySlice<UInt8>) {
        if let view = terminalView as? LoggingTerminalView {
            view.sendMirroredInput(data)
        } else {
            terminalView.send(txt: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Find (⌘F)

    func showFind() {
        findVisible = true
    }

    func hideFind() {
        findVisible = false
        terminalView.clearSearch()
    }

    func toggleFind() {
        if findVisible { hideFind() } else { showFind() }
    }

    /// Searches forward from the current match; returns whether one was found.
    @discardableResult
    func findNext() -> Bool {
        guard !findTerm.isEmpty else { terminalView.clearSearch(); return false }
        return terminalView.findNext(findTerm, options: searchOptions)
    }

    @discardableResult
    func findPrevious() -> Bool {
        guard !findTerm.isEmpty else { terminalView.clearSearch(); return false }
        return terminalView.findPrevious(findTerm, options: searchOptions)
    }

    private var searchOptions: SearchOptions {
        SearchOptions(caseSensitive: findCaseSensitive)
    }

    /// Applies the global look to this terminal's view.
    func apply(appearance: TerminalAppearance) {
        terminalView.font = appearance.nsFont
        terminalView.installColors(appearance.palette)
        terminalView.nativeForegroundColor = appearance.foreground
        terminalView.nativeBackgroundColor = appearance.background
        terminalView.caretColor = appearance.cursor
    }

    /// Per-session text zoom (⌘+/⌘-); clamped to a sane range.
    func zoom(by delta: CGFloat) {
        let current = terminalView.font
        let newSize = min(72, max(6, current.pointSize + delta))
        terminalView.font = NSFont(descriptor: current.fontDescriptor, size: newSize)
            ?? .monospacedSystemFont(ofSize: newSize, weight: .regular)
    }

    /// Restores the global appearance's font size (⌘0).
    func resetZoom(appearance: TerminalAppearance) {
        terminalView.font = appearance.nsFont
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        runCleanup()
        logger?.close()
        DispatchQueue.main.async { self.isRunning = false }
    }
}

final class SessionManager: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published var multiExecActive = false
    @Published var filesPaneVisible = false
    @Published var showQuickConnect = false
    var appearance: TerminalAppearance = .default
    var loggingSettings = LoggingSettings()
    /// Fires on every host connection (all paths — single, group, MultiExec);
    /// the app wires it to the store's recent-connections history.
    var onConnect: ((SessionEntry) -> Void)?

    private var keyMonitor: Any?

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // A terminal whose process has exited closes on Return (keyCode 36)
            // or Enter (76), matching the "press Enter to close" affordance.
            if event.keyCode == 36 || event.keyCode == 76,
               let focused = event.window?.firstResponder as? LocalProcessTerminalView,
               let dead = self.sessions.first(where: { $0.terminalView === focused && !$0.isRunning }) {
                DispatchQueue.main.async { self.close(dead) }
                return nil
            }
            return event
        }
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    var multiExecTargets: [TerminalSession] {
        sessions.filter { $0.includedInMultiExec && $0.isRunning }
    }

    func connect(to entry: SessionEntry) {
        let logger = LogManager.makeLogger(for: entry, settings: loggingSettings)
        let session: TerminalSession

        if entry.usesLocalTransport {
            // A container/pod that runs on this Mac: a local login shell we
            // then drive into the container. The login shell (-l) gives
            // docker/kubectl/gcloud their usual PATH.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            session = TerminalSession(title: entry.name, executable: shell, args: ["-l"],
                                      entry: entry, appearance: appearance, logger: logger)
        } else {
            // ControlMaster options so this interactive session becomes the
            // multiplexing master the SFTP pane piggybacks on.
            let args = SSHControl.options + entry.sshArgs

            // If the host has a saved password, set up the askpass helper so ssh
            // auto-authenticates; otherwise it just prompts in the terminal.
            var environment = SwiftTerm.Terminal.getEnvironmentVariables()
            var cleanup: (() -> Void)?
            if entry.savePassword, let password = CredentialStore.password(for: entry.id),
               let injected = AskpassInjector.environment(for: password) {
                environment += injected.env
                cleanup = injected.cleanup
            }
            session = TerminalSession(title: entry.name, executable: "/usr/bin/ssh", args: args,
                                      entry: entry, appearance: appearance,
                                      environment: environment, cleanup: cleanup, logger: logger)
        }
        add(session)

        // Post-connect command: the container/pod exec for those kinds, or a
        // host's run-on-connect. Fired once the shell has had a moment to come
        // up — shells buffer stdin, so a slightly early send still runs at the
        // first prompt; only an interactive password prompt (no saved
        // credential) would swallow it, hence the editor's note.
        if let command = entry.postConnectCommand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak session] in
                session?.sendText(command + "\r")
            }
        }
        onConnect?(entry)
    }

    func openLocalShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let logger = LogManager.makeLogger(hostKey: "local", title: "Local Shell",
                                           subtitle: shell, settings: loggingSettings)
        add(TerminalSession(title: "local", executable: shell, args: ["-l"],
                            appearance: appearance, logger: logger))
    }

    /// Opens several hosts at once, optionally arming MultiExec so keystrokes
    /// broadcast to the whole group — the "launch a group and drive them
    /// together" workflow. Entries should already be resolved (defaults applied).
    func connectAll(_ entries: [SessionEntry], multiExec: Bool) {
        guard !entries.isEmpty else { return }
        for entry in entries { connect(to: entry) }
        if multiExec { multiExecActive = true }
    }

    /// Re-applies the global look to every open terminal (live settings edits).
    func applyAppearance(_ appearance: TerminalAppearance) {
        self.appearance = appearance
        for session in sessions {
            session.apply(appearance: appearance)
        }
    }

    // MARK: - Zoom (current session)

    func zoomIn() { selected?.zoom(by: 1) }
    func zoomOut() { selected?.zoom(by: -1) }
    func resetZoom() { selected?.resetZoom(appearance: appearance) }

    func close(_ session: TerminalSession) {
        session.closeLog()
        sessions.removeAll { $0.id == session.id }
        if selectedID == session.id {
            selectedID = sessions.last?.id
        }
        if sessions.isEmpty {
            multiExecActive = false
        }
    }

    /// Sends a full command line to every included session (command-bar path).
    func broadcast(_ command: String) {
        guard !command.isEmpty else { return }
        for session in multiExecTargets {
            session.sendText(command + "\r")
        }
    }

    func run(_ macro: Macro) {
        let payload = macro.text.replacingOccurrences(of: "\n", with: "\r")
            + (macro.sendReturn ? "\r" : "")
        if multiExecActive {
            for session in multiExecTargets {
                session.sendText(payload)
            }
        } else {
            selected?.sendText(payload)
        }
    }

    private func add(_ session: TerminalSession) {
        if let view = session.terminalView as? LoggingTerminalView {
            view.onUserInput = { [weak self, weak session] data in
                guard let self, let session else { return }
                self.mirrorUserInput(data, from: session)
            }
        }
        sessions.append(session)
        selectedID = session.id
    }

    /// Mirrors the exact bytes SwiftTerm is about to write to the focused pty.
    /// This catches paste and composed text paths that NSEvent-only mirroring
    /// misses, while `sendMirroredInput` prevents feedback loops in peers.
    private func mirrorUserInput(_ data: ArraySlice<UInt8>, from focused: TerminalSession) {
        guard multiExecActive, focused.includedInMultiExec else { return }
        for peer in multiExecTargets where peer !== focused {
            peer.sendMirroredInput(data)
        }
    }
}
