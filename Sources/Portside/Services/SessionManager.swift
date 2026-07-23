import AppKit
import Combine
import Foundation
import SwiftTerm

/// A terminal view that tees the child process's output to a session log
/// before feeding it to the terminal.
final class LoggingTerminalView: LocalProcessTerminalView {
    var logger: SessionLogger?
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    /// Fires when output arrives, so a background tab can flag new activity.
    var onOutput: (() -> Void)?
    /// When set, input bytes go here instead of the child pty. Sits below the
    /// mirror hook, so MultiExec broadcast works for direct transports too.
    var transportWriter: ((ArraySlice<UInt8>) -> Void)?
    private var suppressInputMirror = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        logger?.append(slice)
        onOutput?()
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
    //
    // `event.window?.firstResponder` stays the terminal even while the user
    // drags the window by its titlebar (first responder doesn't change just
    // because the next click lands on window chrome), so a titlebar drag was
    // being treated as a runaway selection: the window moving out from under
    // a roughly-fixed cursor makes `locationInWindow` swing far outside the
    // view, which started the auto-scroll timer (scrolling to the top) and
    // re-fed the drag into `mouseDragged` (a phantom selection highlight) —
    // reported as the terminal "fighting" scroll while moving the window.
    // Gating on a mouseDown that actually landed inside the view's own bounds
    // limits this to genuine in-terminal selection drags.

    private var selectionAutoScroll: Timer?
    private var lastDragEvent: NSEvent?
    private var isSelectionDrag = false

    private static let selectionAutoScrollMonitor: Void = {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            guard let view = event.window?.firstResponder as? LoggingTerminalView else { return event }
            switch event.type {
            case .leftMouseDown:
                view.isSelectionDrag = view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            case .leftMouseUp:
                view.isSelectionDrag = false
                view.stopSelectionAutoScroll()
                view.lastDragEvent = nil
            default:
                guard view.isSelectionDrag else { break }
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

    // MARK: Right-click Copy/Paste

    /// SwiftTerm implements the standard `copy(_:)`/`paste(_:)` responder
    /// actions (the same code ⌘C/⌘V already dispatch to) but never sets a
    /// context menu, so right-click does nothing today. Building a fresh menu
    /// per click keeps "Copy"'s enabled state honest as the selection changes.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = ClosureMenuItem(title: "Copy") { [weak self] in
            guard let self else { return }
            self.copy(self)
        }
        copyItem.isEnabled = selectionActive
        menu.addItem(copyItem)
        let pasteItem = ClosureMenuItem(title: "Paste") { [weak self] in
            guard let self else { return }
            self.paste(self)
        }
        pasteItem.isEnabled = NSPasteboard.general.string(forType: .string) != nil
        menu.addItem(pasteItem)
        return menu
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
    /// New output arrived while this session's tab wasn't the visible one.
    @Published var hasActivity = false
    // Per-terminal find bar (⌘F); drives SwiftTerm's scrollback search.
    @Published var findVisible = false
    @Published var findTerm = ""
    @Published var findCaseSensitive = false

    var environment: HostEnvironment { entry?.environment ?? .none }
    var isProtected: Bool { entry?.isProtected ?? false }
    /// The shell's live working directory, if it reports one (OSC 7) — used
    /// to keep the SFTP pane following `cd` in the terminal.
    @Published var currentDirectory: String?

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

    /// Releases the transport and the log. Called when the tab closes.
    ///
    /// For local-shell/ssh sessions, closing a tab must guarantee the child
    /// actually goes away, and `terminalView.terminate()` alone doesn't:
    /// - It only sends SIGTERM, relying on the shell's own graceful-exit path.
    ///   Reproduced with a plain local shell here: zsh frameworks (oh-my-zsh /
    ///   powerlevel10k) run async zshexit/EXIT-trap cleanup on SIGTERM that
    ///   can hang indefinitely — `ps` shows the process stuck in "trying to
    ///   exit" (STAT `E`) forever, while the exact same pid dies immediately
    ///   from a bare SIGHUP or SIGKILL. Not something Portside can fix in the
    ///   user's shell config, so it needs a forceful fallback.
    /// - Even when the process does eventually exit, SwiftTerm's own reaper
    ///   (a DispatchSourceProcess watching for `.exit`) is torn down by
    ///   `LocalProcess.deinit` the moment we drop our last reference — right
    ///   after this call returns, via `sessions.removeAll`. A delayed exit is
    ///   then never waited on, so the process sits as a permanent zombie.
    ///
    /// So: ask nicely first (terminate(), which also promptly closes the pty
    /// master), then independently of SwiftTerm's own lifecycle, escalate to
    /// SIGKILL-ing the whole process group (covers any children the shell
    /// itself spawned, e.g. a foreground ssh) and reap it ourselves if it's
    /// still around after a short grace period. The closure only captures the
    /// plain pid, not self/terminalView, so it doesn't matter that the
    /// session is gone from `sessions` by the time it runs.
    func shutdown() {
        let pid = terminalView.process.shellPid
        terminalView.terminate()
        serialPort?.close()
        serialPort = nil
        telnetPort?.close()
        telnetPort = nil
        closeLog()
        guard pid != 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
            if kill(pid, 0) == 0 {
                kill(-pid, SIGKILL)
            }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
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

    /// Wipes the terminal's buffer/scrollback (⌘⌫). SwiftTerm's only public
    /// reset primitive is a full VT reset rather than a surgical scrollback
    /// trim, so this also resets modes/colors set by escape sequences — the
    /// same tradeoff a shell's own `reset` command makes.
    func clearBuffer() {
        terminalView.getTerminal().resetToInitialState()
    }

    /// Applies the global look to this terminal's view.
    func apply(appearance: TerminalAppearance) {
        terminalView.font = appearance.nsFont
        terminalView.installColors(appearance.palette)
        terminalView.nativeForegroundColor = appearance.foreground
        terminalView.nativeBackgroundColor = appearance.background
        terminalView.caretColor = appearance.cursor
        terminalView.getTerminal().setCursorStyle(appearance.swiftTermCursorStyle)
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

    /// Switches the SwiftTerm renderer to match `prefersMetal`, but only when
    /// the view is on-screen. No-op until then and idempotent afterward. Called
    /// from `TerminalHostingView.updateNSView` and the live settings path.
    func applyMetalIfNeeded() {
        guard terminalView.window != nil else { return }
        guard metalAppliedFor != prefersMetal else { return }
        metalAppliedFor = prefersMetal
        do {
            try terminalView.setUseMetal(prefersMetal)
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

    /// Makes this terminal the keyboard focus (used after a split or on
    /// pane-navigation, so keystrokes land where the ring is).
    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    /// The remote shell reported its working directory via OSC 7 (most shell
    /// configs with "shell integration" prompts emit this on every `cd`).
    /// Portside had this delegate hook wired but unused; now it also nudges
    /// the SFTP pane to follow along, if it's open for this session.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let path = Self.parseOSC7Path(directory) else { return }
        DispatchQueue.main.async {
            self.currentDirectory = path
            if let sftp = self._sftp {
                Task { await sftp.followShellDirectory(path) }
            }
        }
    }

    /// OSC 7's payload is a `file://host/url-encoded/path` URI per the
    /// xterm/iTerm2 convention; falls back to treating it as a bare absolute
    /// path for shells that emit it without the `file://` wrapper.
    private static func parseOSC7Path(_ raw: String) -> String? {
        if let url = URL(string: raw), url.isFileURL { return url.path }
        return raw.hasPrefix("/") ? raw : nil
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        runCleanup()
        logger?.close()
        DispatchQueue.main.async { self.isRunning = false }
    }
}

final class SessionManager: ObservableObject {
    /// Source of truth: each open tab owns a pane tree of live sessions. Today
    /// every tab is a single leaf; splitting (0.9) grows the trees.
    @Published var tabs: [Tab] = []
    @Published var selectedTabID: UUID? {
        didSet { clearActivityForSelectedTab(); notifyWorkspaceChanged() }
    }
    @Published var filesPaneVisible = false
    @Published var showQuickConnect = false
    /// A restore plan awaiting the user's yes/no (restoreMode == .ask). The UI
    /// presents a prompt while this is non-nil.
    @Published var pendingRestore: RestorePlan?
    var appearance: TerminalAppearance = .default
    var loggingSettings = LoggingSettings()
    var terminalSettings = TerminalSettings()
    var connectionDefaults = ConnectionDefaults()
    /// The implicit-fallback credential profile (Settings ▸ Profiles) — see
    /// `makeSession`'s password precedence.
    var defaultProfileID: UUID?
    /// Fires on every host connection (all paths — single, group, MultiExec);
    /// the app wires it to the store's recent-connections history.
    var onConnect: ((SessionEntry) -> Void)?
    /// Fires whenever the open session layout changes (open/close/select/
    /// MultiExec membership), so the app can persist a restore snapshot. Held
    /// off during `restore` so replay persists once, at the correct final state.
    var onWorkspaceChange: ((WorkspaceSnapshot) -> Void)?

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// Suppresses workspace-change notifications while replaying a snapshot.
    private var isRestoring = false
    /// Per-session subscriptions to MultiExec-membership changes.
    private var membershipObservers: [UUID: AnyCancellable] = [:]

    init() {
        LoggingTerminalView.installSelectionAutoScrollMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // A terminal whose process has exited closes on Return (keyCode 36 /
            // keypad Enter 76) or a second Ctrl-D — matching the "press ⏎ to
            // close" affordance and the common muscle memory of ⌃D to log out,
            // ⌃D again to close. A live ⌃D is left alone so it still sends EOF.
            // Plain 'r' reconnects instead — checked by character rather than a
            // hardcoded key code so it's layout-independent, matching the
            // shortcut recorder's own approach.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let isCtrlD = event.keyCode == 2 && mods == .control   // keyCode 2 == "d"
            let isPlainR = mods.isEmpty && event.charactersIgnoringModifiers?.lowercased() == "r"
            if let focused = event.window?.firstResponder as? LocalProcessTerminalView,
               let dead = self.sessions.first(where: { $0.terminalView === focused && !$0.isRunning }) {
                if isReturn || isCtrlD {
                    DispatchQueue.main.async { self.close(dead) }
                    return nil
                }
                if isPlainR {
                    DispatchQueue.main.async { self.reconnect(dead) }
                    return nil
                }
            }

            // ⌘←/⌘→ also cycles tabs, alongside the (remappable) ⇧⌘[/⇧⌘] in the
            // menu — a fixed convenience alias, like iTerm2 offers both forms.
            // Not a readline/shell binding, so there's nothing to steal focus
            // from at a live prompt. Handled here rather than as a second
            // `.keyboardShortcut` so it doesn't need its own settings row.
            if mods == .command, event.keyCode == 123 || event.keyCode == 124 {
                DispatchQueue.main.async {
                    event.keyCode == 123 ? self.selectPreviousTab() : self.selectNextTab()
                }
                return nil
            }
            return event
        }
        // Click-to-focus: SwiftTerm's becomeFirstResponder isn't `open`, so we
        // detect focus by hit-testing mouse-downs to the terminal under the
        // cursor and marking its pane active (same NSEvent-monitor pattern as
        // the selection auto-scroll and Enter-to-close workarounds).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window,
                  let hit = window.contentView?.hitTest(event.locationInWindow),
                  let terminal = Self.enclosingTerminalView(of: hit),
                  let session = self.sessions.first(where: { $0.terminalView === terminal }),
                  session.id != self.selectedTab?.activePaneID else { return event }
            self.focusPane(session.id)
            return event
        }
    }

    /// Walks up from a hit-tested subview to the enclosing terminal view.
    private static func enclosingTerminalView(of view: NSView) -> LoggingTerminalView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let terminal = current as? LoggingTerminalView { return terminal }
            candidate = current.superview
        }
        return nil
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    /// Flat view of every live session (all leaves across all tabs), in tab and
    /// left-to-right pane order. The lifecycle/broadcast/restore machinery still
    /// works on this set; the tree only governs layout.
    var sessions: [TerminalSession] { tabs.flatMap(\.leaves) }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    /// The focused terminal — the active leaf of the selected tab. Drives find,
    /// zoom, the SFTP pane, and single-session close.
    var selected: TerminalSession? { selectedTab?.activeLeaf }

    /// Compatibility accessor: read/select the focused session by id. Setting it
    /// focuses that leaf's pane and selects its tab.
    var selectedID: UUID? {
        get { selected?.id }
        set {
            guard let newValue, let tab = tabs.first(where: { $0.contains(newValue) }) else { return }
            tab.activePaneID = newValue
            if selectedTabID != tab.id { selectedTabID = tab.id } else { notifyWorkspaceChanged() }
        }
    }

    func connect(to entry: SessionEntry) {
        let session = makeSession(for: entry)
        add(session)
        postConnect(session, entry: entry)
    }

    /// Connects a host into an existing (start-page) tab instead of opening a
    /// new one — used by the welcome screen's search so picking a host morphs
    /// that tab in place rather than leaving a blank tab behind.
    func connect(to entry: SessionEntry, replacing tab: Tab) {
        let session = makeSession(for: entry)
        activate(session, in: tab)
        postConnect(session, entry: entry)
    }

    /// Builds a session for an entry (transport, logging, saved-password
    /// askpass) without placing it in a tab — so a group can be assembled into
    /// a single split tab.
    private func makeSession(for entry: SessionEntry) -> TerminalSession {
        let logger = LogManager.makeLogger(for: entry, settings: loggingSettings)

        if entry.kind == .serial {
            // Straight to the device — no child process, no ssh machinery.
            return TerminalSession(title: entry.name, serial: entry.serial ?? SerialTarget(),
                                   entry: entry, appearance: appearance, logger: logger)
        } else if entry.kind == .telnet {
            return TerminalSession(title: entry.name, telnet: entry.telnet ?? TelnetTarget(),
                                   entry: entry, appearance: appearance, logger: logger)
        } else if entry.usesLocalTransport {
            // A container/pod that runs on this Mac: a local login shell we
            // then drive into the container. The login shell (-l) gives
            // docker/kubectl/gcloud their usual PATH.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return TerminalSession(title: entry.name, executable: shell, args: ["-l"],
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
                var hostKeyOptions: [String] = []
                if connectionDefaults.autoAcceptNewHostKeys ?? false {
                    // Trusts an unknown host's key on first connect without
                    // prompting, but ssh still hard-fails if an *already
                    // known* host's key later changes — that's the actual
                    // MITM protection, and it stays intact.
                    hostKeyOptions = ["-o", "StrictHostKeyChecking=accept-new"]
                }
                args = SSHControl.options + hostKeyOptions + entry.sshArgs
            }

            // If the host has a saved password, set up the askpass helper so ssh
            // auto-authenticates; otherwise it just prompts in the terminal.
            // (mosh's bootstrap ssh inherits the same environment, so saved
            // passwords work there too.) Precedence: an explicitly assigned
            // credential profile's password wins (that's the point — rotating
            // a profile should override whatever a host had before), then the
            // host's own saved password, then the implicit default profile
            // (Settings ▸ Profiles) for hosts that opted into saving a
            // password but never assigned or set one of their own — the
            // common case for a batch of imported hosts sharing one login.
            var environment = SwiftTerm.Terminal.getEnvironmentVariables()
            var expireSecret: (() -> Void)?
            var cleanup: (() -> Void)?
            let profilePassword = entry.credentialProfileID.flatMap(CredentialStore.profilePassword)
            let defaultProfilePassword = defaultProfileID.flatMap(CredentialStore.profilePassword)
            if entry.savePassword,
               let password = profilePassword
                   ?? CredentialStore.password(for: entry.id)
                   ?? defaultProfilePassword
                   ?? CredentialStore.defaultPassword(),
               let injected = AskpassInjector.environment(for: password) {
                environment += injected.env
                expireSecret = injected.expireSecret
                cleanup = injected.cleanup
            }
            return TerminalSession(title: entry.name, executable: executable, args: args,
                                   entry: entry, appearance: appearance,
                                   environment: environment, expireSecret: expireSecret,
                                   cleanup: cleanup, logger: logger)
        }
    }

    /// Sends the post-connect command (container/pod exec, or a host's
    /// run-on-connect) once the shell has had a moment to come up, and records
    /// the connection. Shells buffer stdin, so a slightly early send still runs
    /// at the first prompt; only an interactive password prompt (no saved
    /// credential) would swallow it, hence the editor's note.
    private func postConnect(_ session: TerminalSession, entry: SessionEntry) {
        if let command = entry.postConnectCommand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak session] in
                session?.sendText(command + "\r")
            }
        }
        onConnect?(entry)
    }

    func openLocalShell() {
        add(makeLocalShellSession())
    }

    /// Opens a local shell into an existing (start-page) tab instead of
    /// opening a new one — the welcome screen's "New Local Shell" button.
    func openLocalShell(replacing tab: Tab) {
        activate(makeLocalShellSession(), in: tab)
    }

    /// Opens a blank "welcome aboard" tab (the tab bar's + button).
    func openStartTab() {
        let tab = Tab.startPage()
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Wires up and installs `session` as the sole content of a start-page tab.
    private func activate(_ session: TerminalSession, in tab: Tab) {
        prepare(session)
        // `tab` publishes through its own ObservableObject, not through
        // SessionManager — SessionArea only observes the manager, so without
        // this it keeps showing the start page's content view (stale
        // `tab.isStartPage`) until some unrelated manager-level change (like
        // switching tabs and back) forces a re-render.
        objectWillChange.send()
        tab.root = .leaf(session)
        tab.activePaneID = session.id
        if selectedTabID != tab.id { selectedTabID = tab.id } else { notifyWorkspaceChanged() }
    }

    private func makeLocalShellSession() -> TerminalSession {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let logger = LogManager.makeLogger(hostKey: "local", title: "Local Shell",
                                           subtitle: shell, settings: loggingSettings)
        return TerminalSession(title: "local", executable: shell, args: ["-l"],
                               appearance: appearance, logger: logger)
    }

    // MARK: - Split panes

    /// Splits the focused pane and opens a local shell in the new one.
    /// `.horizontal` places it to the right, `.vertical` below.
    func splitActivePane(_ orientation: PaneOrientation) {
        guard let tab = selectedTab, let root = tab.root, let activeID = tab.activeLeaf?.id else { return }
        let session = makeLocalShellSession()
        prepare(session)
        tab.root = root.splitting(leafID: activeID, with: .leaf(session), orientation: orientation)
        tab.activePaneID = session.id
        objectWillChange.send()
        notifyWorkspaceChanged()
        // Focus the new pane once it's in the view hierarchy.
        DispatchQueue.main.async { [weak session] in session?.focus() }
    }

    /// Focuses the pane holding `sessionID`, selecting its tab. Called when a
    /// terminal gains first-responder and by pane navigation — never calls back
    /// into the responder chain, so there's no focus loop.
    func focusPane(_ sessionID: UUID) {
        guard let tab = tabs.first(where: { $0.contains(sessionID) }) else { return }
        if tab.activePaneID != sessionID {
            objectWillChange.send()   // active leaf drives find/zoom/SFTP, read via the manager
            tab.activePaneID = sessionID
        }
        if selectedTabID != tab.id { selectedTabID = tab.id }
    }

    /// Cycles focus to the next/previous pane within the active tab (⌘⌥→ / ⌘⌥←).
    func focusAdjacentPane(next: Bool) {
        guard let tab = selectedTab else { return }
        let leaves = tab.leaves
        guard leaves.count > 1,
              let idx = leaves.firstIndex(where: { $0.id == tab.activePaneID }) else { return }
        let newIdx = next ? (idx + 1) % leaves.count : (idx - 1 + leaves.count) % leaves.count
        let target = leaves[newIdx]
        focusPane(target.id)
        target.focus()
    }

    /// Closes the focused pane (⌘⇧W); closes the tab when it's the last pane.
    func closeActivePane() {
        guard let session = selected else { return }
        close(session)
    }

    /// Maximizes the active pane to fill its tab, or restores the split (⌘⇧↵).
    /// A single-pane tab has nothing to zoom.
    func toggleZoom() {
        guard let tab = selectedTab else { return }
        objectWillChange.send()
        if tab.zoomedPaneID != nil {
            tab.zoomedPaneID = nil
        } else if tab.leaves.count > 1 {
            tab.zoomedPaneID = tab.activePaneID
        }
    }

    /// Relaunches a session that has exited, in the same pane — reconnecting a
    /// dropped host or reopening a local shell without disturbing the layout.
    func reconnect(_ session: TerminalSession) {
        guard let tab = tabs.first(where: { $0.contains(session.id) }), let root = tab.root else { return }
        let replacement = session.entry.map { makeSession(for: $0) } ?? makeLocalShellSession()
        prepare(replacement)
        replacement.includedInMultiExec = session.includedInMultiExec
        membershipObservers[session.id] = nil
        tab.root = root.replacingLeaf(session.id, with: replacement)
        if tab.activePaneID == session.id { tab.activePaneID = replacement.id }
        if tab.zoomedPaneID == session.id { tab.zoomedPaneID = replacement.id }
        if let entry = session.entry { postConnect(replacement, entry: entry) }
        DispatchQueue.main.async { [weak replacement] in replacement?.focus() }
    }

    /// Opens several hosts at once. With `multiExec`, they open as one tab split
    /// into a grid and armed for broadcast — the "launch a group and drive them
    /// together" workflow; otherwise each opens as its own tab. Entries should
    /// already be resolved (defaults applied).
    func connectAll(_ entries: [SessionEntry], multiExec: Bool) {
        guard !entries.isEmpty else { return }
        if multiExec {
            openGroupTab(entries)
        } else {
            for entry in entries { connect(to: entry) }
        }
    }

    /// Opens a group of hosts as a single tab, arranged in a grid and armed for
    /// broadcast.
    private func openGroupTab(_ entries: [SessionEntry]) {
        let created = entries.map { makeSession(for: $0) }
        created.forEach(prepare)
        let tab = Tab(root: gridTree(of: created), activePaneID: created[0].id)
        tab.broadcastArmed = true
        tabs.append(tab)
        selectedTabID = tab.id
        for (session, entry) in zip(created, entries) { postConnect(session, entry: entry) }
    }

    /// Arranges sessions into a roughly-square grid: rows of columns, so many
    /// hosts stay readable instead of one very wide row.
    private func gridTree(of sessions: [TerminalSession]) -> PaneNode<TerminalSession> {
        guard sessions.count > 1 else { return .leaf(sessions[0]) }
        let cols = Int(ceil(Double(sessions.count).squareRoot()))
        let rows = stride(from: 0, to: sessions.count, by: cols).map { start in
            Array(sessions[start..<min(start + cols, sessions.count)])
        }
        let rowNodes = rows.map { row -> PaneNode<TerminalSession> in
            row.count == 1
                ? .leaf(row[0])
                : .split(id: UUID(), orientation: .horizontal,
                         children: row.map { .leaf($0) },
                         fractions: equalFractions(row.count))
        }
        return rowNodes.count == 1
            ? rowNodes[0]
            : .split(id: UUID(), orientation: .vertical, children: rowNodes,
                     fractions: equalFractions(rowNodes.count))
    }

    private func equalFractions(_ count: Int) -> [CGFloat] {
        Array(repeating: 1 / CGFloat(count), count: count)
    }

    // MARK: - Broadcast (MultiExec)

    /// Arms/disarms broadcast for the selected tab.
    func setBroadcastArmed(_ armed: Bool) {
        guard let tab = selectedTab else { return }
        objectWillChange.send()
        tab.broadcastArmed = armed
    }

    /// Arms/disarms MultiExec, gathering every open tab into Grid View first
    /// when arming and the active tab doesn't already have several panes to
    /// broadcast across — so with a few separate single-host tabs open,
    /// turning MultiExec on is one step instead of Grid View then MultiExec.
    func setMultiExecArmed(_ armed: Bool) {
        if armed, (selectedTab?.leaves.count ?? 0) < 2, tabs.count > 1 {
            setGridView(true)
        }
        setBroadcastArmed(armed)
    }

    /// Keyboard equivalent of the MultiExec toolbar toggle (⇧⌘M).
    func toggleMultiExec() {
        setMultiExecArmed(!(selectedTab?.broadcastArmed ?? false))
    }

    /// Keyboard equivalent of the Grid View toolbar toggle (⇧⌘G).
    func toggleGridView() {
        setGridView(!isGridView)
    }

    // MARK: - Tab navigation

    /// Selects the next tab, wrapping around (⌘⇧]).
    func selectNextTab() { cycleTab(by: 1) }

    /// Selects the previous tab, wrapping around (⌘⇧[).
    func selectPreviousTab() { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(idx + delta + tabs.count) % tabs.count].id
    }

    /// Selects the tab at a 0-based index (⌘1–⌘9); no-op if out of range.
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }

    // MARK: - Grid view

    /// The tab, if any, that Grid View consolidated all tabs into.
    private var gridViewTabID: UUID?

    /// True while all sessions are tiled into a single Grid View tab.
    var isGridView: Bool {
        gridViewTabID != nil && tabs.contains { $0.id == gridViewTabID }
    }

    /// Grid View is available whenever there's more than one tab to tile (or to
    /// toggle back off).
    var canGridView: Bool { tabs.count > 1 || isGridView }

    /// Tiles every open tab's panes into one grid tab (to watch several at
    /// once), or splits that grid back into individual tabs. Broadcast is not
    /// armed here — that's the separate MultiExec control.
    func setGridView(_ on: Bool) {
        if on {
            guard tabs.count > 1 else { return }
            let leaves = tabs.flatMap(\.leaves)
            let active = selectedTab?.activeLeaf?.id ?? leaves.first?.id ?? UUID()
            let grid = Tab(root: gridTree(of: leaves), activePaneID: active)
            tabs = [grid]
            gridViewTabID = grid.id
            selectedTabID = grid.id   // didSet persists the layout
        } else {
            guard let id = gridViewTabID,
                  let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            let grid = tabs[index]
            let previouslyActive = grid.activePaneID
            let restored = grid.leaves.map { Tab(session: $0) }
            tabs.replaceSubrange(index...index, with: restored)
            gridViewTabID = nil
            selectedTabID = restored.first { previouslyActive.map($0.contains) ?? false }?.id ?? restored.first?.id
        }
    }

    // MARK: - Workspace restore

    /// The current open layout, for persistence. Broadcast-armed state is
    /// intentionally omitted — restore always relaunches disarmed. Start-page
    /// tabs are transient and never persisted, so relaunching never restores a
    /// pile of blank tabs.
    var currentWorkspace: WorkspaceSnapshot {
        let persistable = tabs.compactMap { tab in tab.root.map { (tab, $0) } }
        let tabSnapshots = persistable.map { WorkspaceSnapshot.TabSnapshot(root: snapshot(of: $0.1)) }
        let selectedIndex = persistable.firstIndex { $0.0.id == selectedTabID }
        return WorkspaceSnapshot(tabs: tabSnapshots, selectedTabIndex: selectedIndex, wasGridView: isGridView)
    }

    private func snapshot(of node: PaneNode<TerminalSession>) -> WorkspaceSnapshot.PaneSnapshot {
        switch node {
        case .leaf(let session):
            let leaf = WorkspaceSnapshot.Leaf(
                kind: session.entry.map { .host($0.id) } ?? .localShell,
                includedInMultiExec: session.includedInMultiExec)
            return .leaf(leaf)
        case .split(_, let orientation, let children, let fractions):
            return .split(orientation: orientation, children: children.map(snapshot(of:)),
                          fractions: fractions)
        }
    }

    /// Decides what to do with the last session's snapshot at launch: nothing
    /// (off/empty), restore immediately (auto), or stash a plan for the UI to
    /// confirm (ask). Call once, after appearance/logging/terminal are wired.
    func bootstrapRestore(snapshot: WorkspaceSnapshot, mode: RestoreMode,
                          entryForID: (UUID) -> SessionEntry?) {
        guard mode != .off, !snapshot.isEmpty else { return }
        let plan = snapshot.plan(entryForID: entryForID)
        guard !plan.tabs.isEmpty else { return }
        switch mode {
        case .auto: restore(plan)
        case .ask: pendingRestore = plan
        case .off: break
        }
    }

    /// Replays a planned restore: rebuilds each tab's pane tree, restores the
    /// selected tab, and leaves every tab disarmed.
    func restore(_ plan: RestorePlan) {
        guard !plan.tabs.isEmpty else { return }
        isRestoring = true
        var built: [Tab] = []
        for tabPlan in plan.tabs {
            guard let tab = buildTab(tabPlan) else { continue }
            tabs.append(tab)
            built.append(tab)
        }
        isRestoring = false
        // Grid View collapses everything into one tab with a big split tree —
        // indistinguishable from an ordinary multi-pane tab unless we restore
        // the flag too, else the toggle gets stuck (see WorkspaceSnapshot.wasGridView).
        if plan.wasGridView, built.count == 1, built[0].leaves.count > 1 {
            gridViewTabID = built[0].id
        }
        let selected = plan.selectedTabIndex.flatMap { $0 < built.count ? built[$0] : nil } ?? tabs.last
        selectedTabID = selected?.id   // fires one persist at the final state
    }

    private func buildTab(_ tabPlan: RestorePlan.TabPlan) -> Tab? {
        guard let root = buildNode(tabPlan.root) else { return nil }
        return Tab(root: root, activePaneID: root.leaves.first?.id ?? UUID())
    }

    private func buildNode(_ plan: RestorePlan.PanePlan) -> PaneNode<TerminalSession>? {
        switch plan {
        case .leaf(let action):
            return .leaf(makeRestoredSession(action))
        case .split(let orientation, let children, let fractions):
            var kept: [PaneNode<TerminalSession>] = []
            var keptFractions: [CGFloat] = []
            for (child, fraction) in zip(children, fractions) {
                if let node = buildNode(child) {
                    kept.append(node)
                    keptFractions.append(fraction)
                }
            }
            switch kept.count {
            case 0: return nil
            case 1: return kept[0]
            default: return .split(id: UUID(), orientation: orientation, children: kept,
                                   fractions: normalizedFractions(keptFractions))
            }
        }
    }

    /// Creates and prepares a session for a restore action, without placing it
    /// in a tab (the tree builder assembles it).
    private func makeRestoredSession(_ action: RestoreAction) -> TerminalSession {
        switch action {
        case .connect(let entry, let included):
            let session = makeSession(for: entry)
            prepare(session)
            session.includedInMultiExec = included
            postConnect(session, entry: entry)
            return session
        case .localShell(let included):
            let session = makeLocalShellSession()
            prepare(session)
            session.includedInMultiExec = included
            return session
        }
    }

    private func notifyWorkspaceChanged() {
        guard !isRestoring else { return }
        onWorkspaceChange?(currentWorkspace)
    }

    /// Flags a background tab's session as having new output (drives the tab
    /// activity dot). Ignored for the visible tab and once already flagged.
    private func markActivity(for session: TerminalSession) {
        guard !session.hasActivity,
              let tab = tabs.first(where: { $0.contains(session.id) }),
              tab.id != selectedTabID else { return }
        DispatchQueue.main.async {
            session.hasActivity = true
            self.objectWillChange.send()   // refresh the tab bar's dots
        }
    }

    /// Clears the activity flag on the newly-visible tab's sessions.
    private func clearActivityForSelectedTab() {
        for session in selectedTab?.leaves ?? [] where session.hasActivity {
            session.hasActivity = false
        }
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

    /// Closes a single pane. Removes its leaf from the containing tab's tree,
    /// collapsing splits; when it was the tab's last pane, the tab closes too.
    func close(_ session: TerminalSession) {
        session.shutdown()
        membershipObservers[session.id] = nil
        guard let tab = tabs.first(where: { $0.contains(session.id) }), let root = tab.root else { return }

        if tab.zoomedPaneID == session.id { tab.zoomedPaneID = nil }
        if let newRoot = root.removingLeaf(session.id) {
            tab.root = newRoot
            if tab.activePaneID == session.id {
                tab.activePaneID = tab.leaves.first?.id ?? tab.activePaneID
            }
            notifyWorkspaceChanged()
        } else {
            tabs.removeAll { $0.id == tab.id }
            if selectedTabID == tab.id {
                selectedTabID = tabs.last?.id   // didSet persists the new layout
            } else {
                notifyWorkspaceChanged()
            }
        }
    }

    /// Closes every pane in a tab (the tab-bar close button / menu). A
    /// start-page tab has no panes for the loop to close, so drop it directly.
    func closeTab(_ tab: Tab) {
        if tab.isStartPage {
            tabs.removeAll { $0.id == tab.id }
            if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
            return
        }
        rememberForReopen(tab)
        for session in tab.leaves { close(session) }
    }

    /// Recently-closed tabs (most recent last), so ⇧⌘T can bring one back
    /// with its same host(s)/split layout. Snapshotting only here (once, up
    /// front) — not inside `close(_:)`'s per-leaf teardown — avoids recording
    /// a degenerate single-pane remnant when a multi-pane tab's leaves close
    /// one at a time as part of closing the whole tab.
    private var closedTabHistory: [RestorePlan.TabPlan] = []
    private static let closedTabHistoryLimit = 10

    private func rememberForReopen(_ tab: Tab) {
        guard let root = tab.root, let plan = planNode(for: root) else { return }
        closedTabHistory.append(RestorePlan.TabPlan(root: plan))
        if closedTabHistory.count > Self.closedTabHistoryLimit {
            closedTabHistory.removeFirst()
        }
    }

    /// Reopens the most recently closed tab (⇧⌘T), same as a browser's
    /// "reopen closed tab" — reuses the same restore-plan builder as launch
    /// restore and Duplicate Tab.
    func reopenLastClosedTab() {
        guard let plan = closedTabHistory.popLast(), let tab = buildTab(plan) else { return }
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Closes every tab except the given one (tab menu ▸ Close Others).
    func closeOtherTabs(_ keep: Tab) {
        for tab in tabs where tab.id != keep.id {
            closeTab(tab)
        }
    }

    /// Sets or clears a tab's custom name (tab menu ▸ Rename).
    func renameTab(_ tab: Tab, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        objectWillChange.send()
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
    }

    /// Reopens a tab's layout (same hosts/local shells, same split structure)
    /// as a new tab with fresh sessions (tab menu ▸ Duplicate Tab). Reuses the
    /// restore machinery: describe the live tab as a `RestorePlan`, then build
    /// it exactly like a workspace restore would.
    func duplicateTab(_ tab: Tab) {
        guard let root = tab.root, let plan = planNode(for: root),
              let newTab = buildTab(RestorePlan.TabPlan(root: plan)) else { return }
        newTab.broadcastArmed = tab.broadcastArmed
        tabs.append(newTab)
        selectedTabID = newTab.id
    }

    private func planNode(for node: PaneNode<TerminalSession>) -> RestorePlan.PanePlan? {
        switch node {
        case .leaf(let session):
            let action: RestoreAction = session.entry.map {
                .connect($0, includedInMultiExec: session.includedInMultiExec)
            } ?? .localShell(includedInMultiExec: session.includedInMultiExec)
            return .leaf(action)
        case .split(_, let orientation, let children, let fractions):
            let kids = children.compactMap { planNode(for: $0) }
            guard kids.count == children.count else { return nil }
            return .split(orientation: orientation, children: kids, fractions: fractions)
        }
    }

    /// The included, running panes of a tab — the broadcast targets.
    private func broadcastTargets(in tab: Tab) -> [TerminalSession] {
        tab.leaves.filter { $0.includedInMultiExec && $0.isRunning }
    }

    /// Sends a full command line to the armed tab's included panes (command bar).
    func broadcast(_ command: String) {
        guard !command.isEmpty, let tab = selectedTab, tab.broadcastArmed else { return }
        for session in broadcastTargets(in: tab) {
            session.sendText(command + "\r")
        }
    }

    /// Runs a macro across the armed tab's included panes, or in the focused
    /// pane when no tab is armed.
    func run(_ macro: Macro) {
        let payload = macro.text.replacingOccurrences(of: "\n", with: "\r")
            + (macro.sendReturn ? "\r" : "")
        if let tab = selectedTab, tab.broadcastArmed {
            for session in broadcastTargets(in: tab) {
                session.sendText(payload)
            }
        } else {
            selected?.sendText(payload)
        }
    }

    /// Wires a freshly created session into the manager: input mirroring, focus
    /// tracking, live terminal settings, and MultiExec-membership persistence.
    /// Call before placing the session in a tab or an existing pane tree.
    private func prepare(_ session: TerminalSession) {
        session.terminalView.onUserInput = { [weak self, weak session] data in
            guard let self, let session else { return }
            self.mirrorUserInput(data, from: session)
        }
        session.terminalView.onOutput = { [weak self, weak session] in
            guard let self, let session else { return }
            self.markActivity(for: session)
        }
        session.apply(scrollback: terminalSettings.resolvedScrollback)
        session.prefersMetal = terminalSettings.useMetalRenderer
        // Persist the workspace when this session's MultiExec membership is
        // toggled (the checkbox sets the property directly on the session).
        membershipObservers[session.id] = session.$includedInMultiExec
            .dropFirst()
            .sink { [weak self] _ in self?.notifyWorkspaceChanged() }
    }

    private func add(_ session: TerminalSession) {
        prepare(session)
        // Each new session opens as its own single-leaf tab; splitting inserts
        // into an existing tab's tree instead.
        let tab = Tab(session: session)
        tabs.append(tab)
        selectedTabID = tab.id   // didSet fires the open-tab persist
    }

    /// Mirrors the exact bytes SwiftTerm is about to write to the focused pty to
    /// the other included panes of the *same* tab. Catches paste and composed
    /// text paths that NSEvent-only mirroring misses, while `sendMirroredInput`
    /// prevents feedback loops in peers.
    private func mirrorUserInput(_ data: ArraySlice<UInt8>, from focused: TerminalSession) {
        guard let tab = tabs.first(where: { $0.contains(focused.id) }),
              tab.broadcastArmed, focused.includedInMultiExec else { return }
        for peer in broadcastTargets(in: tab) where peer !== focused {
            peer.sendMirroredInput(data)
        }
    }
}
