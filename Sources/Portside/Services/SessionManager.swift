import AppKit
import Foundation
import SwiftTerm

/// A terminal view that tees the child process's output to a session log
/// before feeding it to the terminal.
final class LoggingTerminalView: LocalProcessTerminalView {
    var logger: SessionLogger?
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    /// When set, input bytes go here instead of the child pty. Sits below the
    /// mirror hook, so MultiExec broadcast works for direct transports too.
    var transportWriter: ((ArraySlice<UInt8>) -> Void)?
    private var suppressInputMirror = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        logger?.append(slice)
        super.dataReceived(slice: slice)
    }

    /// Everything written to the pty funnels through this delegate method:
    /// keyboard/paste/IME input, but also programmatic sends (`send(txt:)`)
    /// and the terminal's own query responses. Only genuine user input may
    /// mirror to MultiExec peers — the other paths suppress themselves,
    /// otherwise a broadcast command re-mirrors from every target (running
    /// N× per host) and DA/DSR auto-replies get typed into peers as garbage.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !suppressInputMirror {
            onUserInput?(data)
        }
        if let transportWriter {
            transportWriter(data)
        } else {
            super.send(source: source, data: data)
        }
    }

    /// Auto-replies the terminal emits when the host queries it (device
    /// attributes, cursor position) are not user input.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        withMirrorSuppressed { super.send(source: source, data: data) }
    }

    /// App-generated text (broadcast bar, macros, post-connect commands).
    /// Callers that fan out to several sessions do so themselves.
    func sendProgrammatic(_ txt: String) {
        withMirrorSuppressed { send(txt: txt) }
    }

    /// Input arriving from a MultiExec peer; must not mirror back out.
    func sendMirroredInput(_ data: ArraySlice<UInt8>) {
        withMirrorSuppressed { super.send(source: self, data: data) }
    }

    private func withMirrorSuppressed(_ body: () -> Void) {
        suppressInputMirror = true
        body()
        suppressInputMirror = false
    }

    /// SwiftUI re-parents the persistent terminal view on every tab switch and
    /// hands it a transient zero frame before the real size arrives. Letting
    /// that through resizes the terminal to 2×1 — reflowing the whole buffer
    /// and SIGWINCHing the pty — and immediately back. Shells that don't
    /// repaint their prompt on SIGWINCH (bash, many remote hosts) are left
    /// showing the last line as a 1–2 character fragment (issue #9). Dropping
    /// the degenerate frame makes tab switches side-effect-free: the real
    /// size lands in the next call, and a same-size re-attach never touches
    /// the terminal at all.
    override func setFrameSize(_ newSize: NSSize) {
        if newSize.width < 1 || newSize.height < 1 { return }
        super.setFrameSize(newSize)
    }

    // MARK: Selection auto-scroll (issue #7)
    //
    // SwiftTerm computes an autoScrollDelta during selection drags but never
    // schedules the timer that would consume it, so dragging past the top or
    // bottom edge doesn't scroll. Its mouseDragged/mouseUp are public but not
    // open, so instead of overriding we watch the app's own mouse events with
    // a local monitor: while a drag on a focused terminal sits outside the
    // vertical bounds, a timer scrolls the viewport and re-delivers the last
    // drag event (mouseDragged is callable) so the selection extends to the
    // newly revealed rows.

    private var selectionAutoScroll: Timer?
    private var lastDragEvent: NSEvent?

    private static let selectionAutoScrollMonitor: Void = {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { event in
            guard let view = event.window?.firstResponder as? LoggingTerminalView else { return event }
            if event.type == .leftMouseUp {
                view.stopSelectionAutoScroll()
                view.lastDragEvent = nil
            } else {
                view.lastDragEvent = event
                view.updateSelectionAutoScroll(for: event)
            }
            return event
        }
    }()

    static func installSelectionAutoScrollMonitor() {
        _ = selectionAutoScrollMonitor
    }

    private func updateSelectionAutoScroll(for event: NSEvent) {
        // When the remote app owns the mouse (vim etc.), SwiftTerm reports the
        // drag to it instead of selecting; don't fight over the viewport.
        if allowMouseReporting && getTerminal().mouseMode != .off {
            stopSelectionAutoScroll()
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        if loc.y < 0 || loc.y > bounds.height {
            startSelectionAutoScroll()
        } else {
            stopSelectionAutoScroll()
        }
    }

    private func startSelectionAutoScroll() {
        guard selectionAutoScroll == nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.selectionAutoScrollTick()
        }
        // Fire during both normal dispatch and mouse-tracking runloop modes.
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.add(timer, forMode: .eventTracking)
        selectionAutoScroll = timer
    }

    private func stopSelectionAutoScroll() {
        selectionAutoScroll?.invalidate()
        selectionAutoScroll = nil
    }

    private func selectionAutoScrollTick() {
        guard let event = lastDragEvent, window != nil else {
            stopSelectionAutoScroll()
            return
        }
        let loc = convert(event.locationInWindow, from: nil)
        // Unflipped coordinates: y grows upward, so above the view means
        // y > height (scroll back into history) and below means y < 0.
        if loc.y > bounds.height {
            scrollUp(lines: min(10, 1 + Int((loc.y - bounds.height) / 20)))
        } else if loc.y < 0 {
            scrollDown(lines: min(10, 1 + Int(-loc.y / 20)))
        } else {
            stopSelectionAutoScroll()
            return
        }
        // Same pointer position now maps to a different buffer row.
        mouseDragged(with: event)
    }
}

/// One live terminal tab: owns the SwiftTerm view and the child process
/// (either `ssh` or a local login shell) running inside it.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let terminalView: LoggingTerminalView
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

    /// Shreds the on-disk askpass password once ssh has had its chance —
    /// the helper script stays alive for late interactive prompts (slow MFA,
    /// ProxyJump hops), which `cleanup` removes when the process exits.
    private var expireSecret: (() -> Void)?
    private var cleanup: (() -> Void)?
    private let logger: SessionLogger?
    private var serialPort: SerialPort?
    private var telnetPort: TelnetPort?

    init(title: String, executable: String, args: [String], entry: SessionEntry? = nil,
         appearance: TerminalAppearance = .default,
         environment: [String]? = nil,
         expireSecret: (() -> Void)? = nil, cleanup: (() -> Void)? = nil,
         logger: SessionLogger? = nil) {
        self.title = title
        self.entry = entry
        self.expireSecret = expireSecret
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
        // Bound how long the password lives on disk even if auth stalls.
        if expireSecret != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.expireSecret?()
                self?.expireSecret = nil
            }
        }
    }

    /// A serial session: no child process — the terminal view talks to the
    /// device fd through SerialPort. Output still tees through the logger
    /// (dataReceived) and input through the MultiExec mirror (send), because
    /// both hooks live on the view, not the process.
    init(title: String, serial target: SerialTarget, entry: SessionEntry? = nil,
         appearance: TerminalAppearance = .default,
         logger: SessionLogger? = nil) {
        self.title = title
        self.entry = entry
        self.logger = logger
        self.includedInMultiExec = !(entry?.isProtected ?? false)
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.logger = logger
        self.terminalView = view
        super.init()
        terminalView.processDelegate = self
        apply(appearance: appearance)

        do {
            let port = try SerialPort(target: target)
            serialPort = port
            terminalView.transportWriter = { [weak port] data in port?.write(data) }
            port.onData = { [weak self] bytes in
                let copy = Array(bytes)[...]
                DispatchQueue.main.async { self?.terminalView.dataReceived(slice: copy) }
            }
            port.onClosed = { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.isRunning else { return }
                    if let message {
                        self.terminalView.feed(text: "\r\n[portside: \(message)]\r\n")
                    }
                    self.logger?.close()
                    self.isRunning = false
                }
            }
            terminalView.feed(text: "[connected to \(target.deviceName) at \(target.summary)]\r\n")
        } catch {
            terminalView.feed(text: "portside: \(error.localizedDescription)\r\n")
            isRunning = false
        }
    }

    /// A telnet session: the terminal view writes to a TCP connection and the
    /// transport filters IAC negotiation before output reaches SwiftTerm.
    init(title: String, telnet target: TelnetTarget, entry: SessionEntry? = nil,
         appearance: TerminalAppearance = .default,
         logger: SessionLogger? = nil) {
        self.title = title
        self.entry = entry
        self.logger = logger
        self.includedInMultiExec = !(entry?.isProtected ?? false)
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.logger = logger
        self.terminalView = view
        super.init()
        terminalView.processDelegate = self
        apply(appearance: appearance)

        let port = TelnetPort(target: target)
        telnetPort = port
        terminalView.transportWriter = { [weak port] data in port?.write(data) }
        port.onData = { [weak self] bytes in
            let copy = Array(bytes)[...]
            DispatchQueue.main.async { self?.terminalView.dataReceived(slice: copy) }
        }
        port.onConnected = { [weak self] in
            DispatchQueue.main.async {
                self?.terminalView.feed(text: "[connected to \(target.host):\(target.port) via telnet]\r\n")
            }
        }
        port.onClosed = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                if let message {
                    self.terminalView.feed(text: "\r\n[portside: \(message)]\r\n")
                }
                self.logger?.close()
                self.isRunning = false
            }
        }
        port.start()
    }

    /// Releases the transport (closes the device fd so the port frees up
    /// immediately) and the log. Called when the tab closes.
    func shutdown() {
        serialPort?.close()
        serialPort = nil
        telnetPort?.close()
        telnetPort = nil
        closeLog()
    }

    private func runCleanup() {
        expireSecret?()
        expireSecret = nil
        cleanup?()
        cleanup = nil
    }

    /// Flushes and closes the session log (idempotent).
    func closeLog() {
        logger?.close()
    }

    func sendText(_ text: String) {
        terminalView.sendProgrammatic(text)
    }

    func sendMirroredInput(_ data: ArraySlice<UInt8>) {
        terminalView.sendMirroredInput(data)
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

    /// Sets this terminal's scrollback (history) depth. The view is built with
    /// SwiftTerm's default (500), so we resize the live buffer after the fact.
    func apply(scrollback lines: Int) {
        terminalView.getTerminal().changeScrollback(lines)
    }

    /// Whether this session should render via Metal. Applied lazily once the
    /// view is in a window (see `applyMetalIfNeeded`), since SwiftTerm requires
    /// the view to be on-screen before switching renderers.
    var prefersMetal = false
    /// Last value we actually pushed to SwiftTerm, so a failed switch (Metal
    /// unavailable) isn't retried and re-logged on every layout pass.
    private var metalAppliedFor: Bool?

    /// SwiftTerm's Metal renderer resolves its shaders through the SwiftPM-
    /// generated Bundle.module accessor, which traps (fatalError → SIGTRAP)
    /// instead of returning nil when SwiftTerm_SwiftTerm.bundle can't be
    /// found — and in a packaged .app it looks for the bundle at the .app
    /// root, where we can't ship it without breaking code signing. Only hand
    /// SwiftTerm `useMetal = true` when its lookup will succeed (true for
    /// `swift run`/dev builds, where the bundle sits next to the executable).
    /// Packaged builds stay on CoreGraphics until SwiftTerm's lookup is fixed
    /// upstream.
    private static let metalShadersLocatable = FileManager.default.fileExists(
        atPath: Bundle.main.bundleURL.appendingPathComponent("SwiftTerm_SwiftTerm.bundle").path)

    /// Switches the SwiftTerm renderer to match `prefersMetal`, but only when
    /// the view is on-screen. No-op until then and idempotent afterward. Called
    /// from `TerminalHostingView.updateNSView` and the live settings path.
    private var warnedMetalUnavailable = false

    func applyMetalIfNeeded() {
        guard terminalView.window != nil else { return }
        if prefersMetal && !Self.metalShadersLocatable && !warnedMetalUnavailable {
            warnedMetalUnavailable = true
            NSLog("Portside: Metal renderer unavailable in this build (shader bundle not found), staying on CoreGraphics")
        }
        let wantMetal = prefersMetal && Self.metalShadersLocatable
        guard metalAppliedFor != wantMetal else { return }
        metalAppliedFor = wantMetal
        do {
            try terminalView.setUseMetal(wantMetal)
        } catch {
            NSLog("Portside: Metal renderer unavailable, staying on CoreGraphics: \(error)")
        }
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
    var terminalSettings = TerminalSettings()
    /// Fires on every host connection (all paths — single, group, MultiExec);
    /// the app wires it to the store's recent-connections history.
    var onConnect: ((SessionEntry) -> Void)?

    private var keyMonitor: Any?

    init() {
        LoggingTerminalView.installSelectionAutoScrollMonitor()
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

        if entry.kind == .serial {
            // Straight to the device — no child process, no ssh machinery.
            session = TerminalSession(title: entry.name, serial: entry.serial ?? SerialTarget(),
                                      entry: entry, appearance: appearance, logger: logger)
        } else if entry.kind == .telnet {
            session = TerminalSession(title: entry.name, telnet: entry.telnet ?? TelnetTarget(),
                                      entry: entry, appearance: appearance, logger: logger)
        } else if entry.usesLocalTransport {
            // A container/pod that runs on this Mac: a local login shell we
            // then drive into the container. The login shell (-l) gives
            // docker/kubectl/gcloud their usual PATH.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            session = TerminalSession(title: entry.name, executable: shell, args: ["-l"],
                                      entry: entry, appearance: appearance, logger: logger)
        } else {
            // ControlMaster options so this interactive session becomes the
            // multiplexing master the SFTP pane piggybacks on. mosh (when
            // asked for and installed) runs its own ssh bootstrap and skips
            // ControlMaster — the file pane is disabled for mosh sessions.
            let executable: String
            let args: [String]
            if entry.preferMosh, let mosh = MoshLocator.find() {
                executable = mosh
                args = entry.moshArgs
            } else {
                if entry.preferMosh {
                    NSLog("Portside: mosh requested for \(entry.name) but not installed; using ssh")
                }
                executable = "/usr/bin/ssh"
                args = SSHControl.options + entry.sshArgs
            }

            // If the host has a saved password, set up the askpass helper so ssh
            // auto-authenticates; otherwise it just prompts in the terminal.
            // (mosh's bootstrap ssh inherits the same environment, so saved
            // passwords work there too.)
            var environment = SwiftTerm.Terminal.getEnvironmentVariables()
            var expireSecret: (() -> Void)?
            var cleanup: (() -> Void)?
            if entry.savePassword, let password = CredentialStore.password(for: entry.id),
               let injected = AskpassInjector.environment(for: password) {
                environment += injected.env
                expireSecret = injected.expireSecret
                cleanup = injected.cleanup
            }
            session = TerminalSession(title: entry.name, executable: executable, args: args,
                                      entry: entry, appearance: appearance,
                                      environment: environment, expireSecret: expireSecret,
                                      cleanup: cleanup, logger: logger)
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

    /// Re-applies terminal behavior (scrollback, renderer) to every open terminal.
    func applyTerminalSettings(_ terminal: TerminalSettings) {
        self.terminalSettings = terminal
        for session in sessions {
            session.apply(scrollback: terminal.resolvedScrollback)
            session.prefersMetal = terminal.useMetalRenderer
            session.applyMetalIfNeeded()
        }
    }

    // MARK: - Zoom (current session)

    func zoomIn() { selected?.zoom(by: 1) }
    func zoomOut() { selected?.zoom(by: -1) }
    func resetZoom() { selected?.resetZoom(appearance: appearance) }

    func close(_ session: TerminalSession) {
        session.shutdown()
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
        session.terminalView.onUserInput = { [weak self, weak session] data in
            guard let self, let session else { return }
            self.mirrorUserInput(data, from: session)
        }
        session.apply(scrollback: terminalSettings.resolvedScrollback)
        session.prefersMetal = terminalSettings.useMetalRenderer
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
