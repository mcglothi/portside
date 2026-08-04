import AppKit
import Combine
import Foundation
import Network
import SwiftTerm

/// A terminal view that tees the child process's output to a session log
/// before feeding it to the terminal.
final class LoggingTerminalView: LocalProcessTerminalView {
    var logger: SessionLogger?
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?
    /// Fires when output arrives, so a background tab can flag new activity.
    var onOutput: (() -> Void)?
    /// Whether the transport has produced any bytes. An ssh that is still
    /// dialling a host that will never answer stays alive but silent, so
    /// "still running" alone can't distinguish connecting from connected.
    private(set) var sawOutput = false
    /// Fires when the shell reports a completed command via OSC 133. Sits on
    /// the raw byte tap because SwiftTerm doesn't parse OSC 133 -- it sees the
    /// markers, ignores them, and we read them here on the way past.
    var onCommand: ((CommandEvent) -> Void)?
    var commandTimeline: CommandTimeline?
    /// When set, input bytes go here instead of the child pty. Sits below the
    /// mirror hook, so MultiExec broadcast works for direct transports too.
    var transportWriter: ((ArraySlice<UInt8>) -> Void)?
    private var suppressInputMirror = false
    /// Repairs unterminated sixel payloads on the way past, which would
    /// otherwise crash SwiftTerm's decoder. Temporary; see `SixelStreamGuard`.
    private var sixelGuard = SixelStreamGuard()
    /// Test seam: the bytes actually handed to the terminal, after repair.
    ///
    /// Exists because the ordering below is a contract, not an implementation
    /// detail, and there is no way to observe what reached `super` from outside.
    /// Raised by Codex CLI in the 0.17 pre-release review.
    var onTerminalBytes: ((ArraySlice<UInt8>) -> Void)?

    // MARK: - Host-to-host drop target

    /// A remote file was dropped on this terminal.
    var onRemoteFileDrop: ((RemoteFileDragPayload) -> Void)?
    /// Local files (from Finder, or anywhere else) were dropped here.
    var onLocalFilesDrop: (([URL]) -> Void)?
    /// A droppable remote file entered or left this terminal's bounds.
    var onDropTargetChanged: ((Bool) -> Void)?

    /// Drops are handled here, in AppKit, rather than with a SwiftUI
    /// `onDrop`/`dropDestination` on the pane.
    ///
    /// The drag is an `NSFilePromiseProvider`, which writes its types lazily:
    /// the pasteboard reports them (`NSPasteboard.types` lists ours) but the
    /// `NSPasteboardItem`/`NSItemProvider` bridge that both SwiftUI drop APIs
    /// match through exposes none of them. `dropDestination` therefore never
    /// fired while the drag still *looked* accepted — the promise is what
    /// draws the copy badge — and `onDrop`, registered for a type the bridge
    /// could not see, rejected the drag outright. Reading the pasteboard
    /// directly is the only path that sees the payload.
    ///
    /// This view is already the hit-test target over the terminal, so it
    /// needs no overlay and cannot steal mouse handling from one.
    func enableRemoteFileDrops() {
        // `.fileURL` as well as our own type: a Finder drag onto a pane used
        // to do nothing at all, so sending a local file to a broadcast group
        // meant dropping it into the file browser (which uploaded it to that
        // one host) and dragging it back out to the group.
        registerForDraggedTypes([.portsideRemoteFile, .fileURL])
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.data(forType: .portsideRemoteFile) != nil
            || !localFileURLs(from: sender).isEmpty
    }

    private func localFileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL] ?? []
        // Directories would need recursive upload; sftp `put` of one is not a
        // thing here. Left out rather than half-working.
        return urls.filter { url in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return exists && !isDir.boolValue
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(sender) else { return [] }
        onDropTargetChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargetChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDropTargetChanged?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargetChanged?(false)
        guard let data = sender.draggingPasteboard.data(forType: .portsideRemoteFile) else {
            let urls = localFileURLs(from: sender)
            guard !urls.isEmpty else { return false }
            onLocalFilesDrop?(urls)
            return true
        }
        guard let payload = try? JSONDecoder().decode(
            RemoteFileDragPayload.self, from: data
        ) else {
            return false
        }
        onRemoteFileDrop?(payload)
        return true
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        sawOutput = true
        // The log and the command timeline get the bytes as they actually
        // arrived. Only the terminal sees the repaired stream -- the guard can
        // change the byte count, and transcript offsets have to keep matching
        // what is on disk.
        logger?.append(slice)
        onOutput?()
        if onCommand != nil, commandTimeline != nil {
            for var event in commandTimeline!.consume(slice) {
                // Anchor the command in the transcript. settledOffset() waits
                // for the queued write, so the offset reflects this chunk --
                // reading the counter directly raced the writer and pointed at
                // output from before the command. Only runs at a command
                // boundary, so the synchronisation is rare.
                if let logger {
                    event.logPath = logger.fileURL.path
                    event.logOffset = logger.settledOffset()
                }
                onCommand?(event)
            }
        }
        let repaired = sixelGuard.filter(slice)
        onTerminalBytes?(repaired)
        super.dataReceived(slice: repaired)
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

    /// Consulted before a paste reaches the pty; returning false drops it.
    /// Set by `SessionManager` for panes that can broadcast.
    var shouldAllowPaste: ((String) -> Bool)?

    /// The one input path where confirmation is worth the friction.
    ///
    /// Overriding here rather than filtering bytes in `send` catches ⌘V and
    /// the context-menu item together (both dispatch to this responder
    /// action), and — the reason it has to be here — intercepts *before* the
    /// local pane receives anything. Vetoing further down would already have
    /// written to the focused pty, leaving the confirmation deciding only
    /// whether the other eleven hosts join in.
    /// Signature matches SwiftTerm's `open func paste(_ sender: Any)` exactly,
    /// not `NSResponder`'s `Any?`. Both carry the `paste:` selector, so the
    /// looser one compiles and looks like it works while overriding the wrong
    /// method — leaving ⌘V dispatching straight to SwiftTerm's implementation
    /// with the gate never consulted.
    override func paste(_ sender: Any) {
        if let shouldAllowPaste,
           let text = NSPasteboard.general.string(forType: .string),
           !text.isEmpty,
           !shouldAllowPaste(text) {
            return
        }
        super.paste(sender)
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
    /// Guards against the connection attempt being resolved twice.
    var resolvedConnectionOutcome = false

    /// Whether something on the other end is currently reading a secret.
    ///
    /// Password prompts, key passphrases, `sudo`, and MFA challenges all work
    /// the same way: turn off terminal echo, read a line, turn it back on. The
    /// pty master reports the slave's termios, so a clear `ECHO` bit is a
    /// direct reading of "a secret is being typed right now" rather than a
    /// guess from output text — which would have to keep up with every prompt
    /// wording, in every language, from ssh, sudo, and every PAM module.
    ///
    /// False for transports with no child process (serial, telnet) and for a
    /// session that has already exited: nothing to read, nothing to protect.
    var isReadingSecret: Bool {
        guard isRunning, let process = terminalView.process, process.running else { return false }
        var settings = termios()
        guard tcgetattr(process.childfd, &settings) == 0 else { return false }
        return settings.c_lflag & tcflag_t(ECHO) == 0
    }

    /// Positive evidence the session actually came up.
    ///
    /// For ssh and mosh, being alive isn't enough — a connection to a host that
    /// never answers sits there silently until its timeout, and would otherwise
    /// be counted as a success. Any output means something on the far end
    /// replied. Direct transports are judged on liveness alone: a serial
    /// console can legitimately sit silent until you press a key, so requiring
    /// output would mark real connections as failures.
    var didConnect: Bool {
        guard isRunning else { return false }
        switch entry?.kind {
        case .host, .none: return terminalView.sawOutput
        default: return true
        }
    }
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

    /// Why a file dropped on this pane could not be copied here. Surfaced on
    /// the pane itself rather than in the file browser, because the drop
    /// target is what the user was looking at.
    @Published var relayError: String?

    /// A remote file is hovering over this pane and could land here.
    @Published var dropTargeted = false
    /// Local files dropped on this pane, awaiting the view's routing.
    @Published var pendingLocalDrop: [URL]?
    /// Set by the terminal view when a remote file is dropped; the pane view
    /// picks it up, resolves the hosts against the store, and starts the
    /// relay. Routed through here rather than handled in AppKit so the store
    /// lookup and error presentation stay in SwiftUI where they belong.
    @Published var pendingRemoteDrop: RemoteFileDragPayload?

    /// True briefly after a copy lands on this host, so the pane can flash.
    @Published var relayLanded = false

    /// Flashes this pane to show a copy arrived. The only signal a fan-out
    /// gets: the drag icon drops on one pane, but the file reaches many.
    func flashRelayLanded() {
        relayLanded = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self.relayLanded = false
        }
    }

    private var _sftp: SFTPBrowserModel?
    /// Lazy per-session file browser; only for plain SSH hosts (not local
    /// shells or container/pod sessions).
    @MainActor var sftp: SFTPBrowserModel? {
        guard let entry, entry.supportsFileBrowser else { return nil }
        if _sftp == nil {
            // Seeded with what OSC 7 has already told us, so a browser opened
            // after the shell moved opens where the shell actually is.
            _sftp = SFTPBrowserModel(entry: entry, startingPath: currentDirectory)
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
        wireRemoteFileDrops()
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
        wireRemoteFileDrops()
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
        wireRemoteFileDrops()
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

    /// Lets a remote file dragged from the SFTP browser land on this pane.
    private func wireRemoteFileDrops() {
        terminalView.enableRemoteFileDrops()
        terminalView.onDropTargetChanged = { [weak self] targeted in
            Task { @MainActor in self?.dropTargeted = targeted }
        }
        terminalView.onRemoteFileDrop = { [weak self] payload in
            Task { @MainActor in self?.pendingRemoteDrop = payload }
        }
        terminalView.onLocalFilesDrop = { [weak self] urls in
            Task { @MainActor in self?.pendingLocalDrop = urls }
        }
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

@MainActor
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
    /// Fires whenever the open session layout changes (open/close/select/
    /// MultiExec membership), so the app can persist a restore snapshot. Held
    /// off during `restore` so replay persists once, at the correct final state.
    var onWorkspaceChange: ((WorkspaceSnapshot) -> Void)?
    /// Set when command history is enabled; receives each completed command.
    var onCommand: ((CommandEvent) -> Void)?
    /// Reports an attempt and, once resolved, whether it actually connected.
    var onConnectionAttempt: ((SessionEntry, ConnectionOutcome) -> Void)?
    var recordsCommands = false
    /// Mirrors the recording privacy setting so logging honours it too, not
    /// just connection and command history.
    var excludesProtectedFromRecording = false

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// Suppresses workspace-change notifications while replaying a snapshot.
    private var isRestoring = false
    /// Per-session subscriptions to MultiExec-membership changes.
    private var membershipObservers: [UUID: AnyCancellable] = [:]
    private var wakeObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var networkMonitor: NWPathMonitor?
    /// Interfaces seen on the last network path; nil until the first callback.
    private var lastNetworkInterfaces: Set<String>?

    init() {
        observeSystemWake()
        observeNetworkChanges()
        observeTerminationForGroups()
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
        // The wake observer was never torn down here. Harmless for the app's
        // single long-lived manager, but a test that builds several leaves one
        // live observer per instance, each holding a closure that fires on the
        // next wake.
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        networkMonitor?.cancel()
    }

    /// Flat view of every live session (all leaves across all tabs), in tab and
    /// left-to-right pane order. The lifecycle/broadcast/restore machinery still
    /// works on this set; the tree only governs layout.
    var sessions: [TerminalSession] { tabs.flatMap(\.leaves) }

    /// The active tab, falling back to the last one when `selectedTabID` names
    /// a tab that is no longer here.
    ///
    /// The fallback is not decoration. Every tab-scoped command — arm
    /// MultiExec, broadcast, split, close, zoom — reads through this and does
    /// nothing at all when it's nil, so a stale id turns the whole app into a
    /// window that ignores input while looking perfectly normal. `SessionArea`
    /// had the matching hole: it drew `WelcomeView` for no sessions and a tab
    /// for a selected one, and *nothing* in between, which leaves the previous
    /// frame's AppKit views on screen with no owner.
    ///
    /// Removal paths do reassign the id, so this should be unreachable; it is
    /// here because "should be" is doing a lot of work in a teardown sequence,
    /// and the cost of being wrong is a window that has to be force-quit.
    /// Deliberately pure — healing `selectedTabID` from a getter would mutate
    /// during a view update.
    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } ?? tabs.last }

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
        let logger = LogManager.makeLogger(
            for: entry, settings: loggingSettings, excludeProtected: excludesProtectedFromRecording
        )

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
            if let password = CredentialResolver.password(for: entry, defaultProfileID: defaultProfileID),
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
    /// How long a transport must survive before we call it connected.
    ///
    /// There's no portable "authenticated" callback: ssh, mosh, telnet and
    /// serial all just run a child or open a socket. But a failed connection
    /// dies fast and loudly — bad credentials, refused, no route, unknown host
    /// all exit in well under a second — while a live session sits there. So
    /// survival past this window is the positive evidence, and it costs
    /// nothing to observe.
    private static let connectionGracePeriod: TimeInterval = 4

    /// How long to keep waiting for an authentication prompt to finish before
    /// giving up on the post-connect command. Generous on purpose: it has to
    /// cover a push notification being approved on a phone, or a hardware key
    /// being touched.
    private static let postConnectAuthTimeout: TimeInterval = 90
    private static let postConnectPollInterval: TimeInterval = 0.15

    private func postConnect(_ session: TerminalSession, entry: SessionEntry) {
        if let command = entry.postConnectCommand {
            sendWhenNotPrompting(command, to: session, deadline: .now() + Self.postConnectAuthTimeout)
        }
        // Logged immediately so a failure leaves a trace, but deliberately not
        // counted: only a confirmed connection updates the totals that drive
        // Quick Connect's ranking and stale-host detection.
        onConnectionAttempt?(entry, .attempted)
        confirmConnection(session, entry: entry)
    }

    /// Sends a post-connect command once nothing is reading a secret.
    ///
    /// This used to fire on a flat 1.2-second timer, which is long enough for a
    /// fast local shell and nowhere near long enough for a password prompt, a
    /// slow `ProxyJump` chain, or MFA. When it lost that race the command was
    /// typed *into the prompt*: echo is off, so nothing appears, the newline
    /// submits it as the password, and the command — which may be anything —
    /// goes to the server as a failed credential and into its auth log.
    ///
    /// The signal is exact rather than heuristic. Anything reading a secret —
    /// ssh, sudo, an MFA prompt — turns off `ECHO` on the tty, and the pty
    /// master reports the slave's termios, so "echo is off" *is* "someone is
    /// asking for a secret right now". Waiting for it to come back is precisely
    /// the condition that was missing.
    ///
    /// No settle delay once it does: shells buffer stdin, so a command arriving
    /// a moment before the prompt is drawn still runs at it. The old comment
    /// here was right about that, and wrong only about the prompt it might land
    /// in instead.
    ///
    /// Transports with no child process (serial, telnet) have no termios to
    /// read and send immediately, exactly as before.
    private func sendWhenNotPrompting(_ command: String, to session: TerminalSession,
                                      deadline: DispatchTime) {
        guard session.isRunning else { return }   // died during auth; nothing to send to
        guard session.isReadingSecret, DispatchTime.now() < deadline else {
            session.sendText(command + "\r")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postConnectPollInterval) {
            [weak self, weak session] in
            guard let self, let session else { return }
            self.sendWhenNotPrompting(command, to: session, deadline: deadline)
        }
    }

    /// Resolves the attempt once the grace period has passed, or as soon as the
    /// session ends — whichever happens first.
    private func confirmConnection(_ session: TerminalSession, entry: SessionEntry) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectionGracePeriod) {
            [weak self, weak session] in
            guard let self else { return }
            guard let session else { return }        // torn down; nothing to claim
            guard !session.resolvedConnectionOutcome else { return }
            session.resolvedConnectionOutcome = true
            self.onConnectionAttempt?(entry, session.didConnect ? .connected : .failed)
        }
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
        // A pane coming back is not the pane that was armed. The replacement is
        // a fresh shell — possibly at a login prompt, in a different directory,
        // or on a different machine if DNS or a jump host moved. Membership
        // carries over so the group is intact when the user re-arms, but the
        // arming itself does not.
        //
        // This took two goes. Disarming here corrupted the window every time a
        // reconnect happened while armed, and the cause was not the disarm but
        // the *notice*: as a child of the pane container it was inserted at the
        // exact moment the pane tree was being restructured, re-parenting the
        // persistent terminal views. It's an overlay now, so it no longer joins
        // that layout — see `TabContentView.disarmNotice`.
        disarm(tab, reason: .paneReconnected(host: session.entry?.name))

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
                         children: row.map { .leaf($0) })
        }
        return rowNodes.count == 1
            ? rowNodes[0]
            : .split(id: UUID(), orientation: .vertical, children: rowNodes)
    }

    // MARK: - Broadcast (MultiExec)

    /// Arms/disarms broadcast for the selected tab.
    func setBroadcastArmed(_ armed: Bool) {
        guard let tab = selectedTab else { return }
        objectWillChange.send()
        tab.broadcastArmed = armed
        // Re-arming answers the notice: you've seen why it went down and put it
        // back. Leaving it up would have the tab explaining a state it is no
        // longer in.
        if armed { tab.disarmNotice = nil }
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

    /// Takes an armed broadcast down because the world changed underneath it,
    /// and records why so the UI can say so.
    ///
    /// Arming asserts "these panes are in a state I've checked, and I want one
    /// command to reach all of them". Anything that invalidates the *checked*
    /// half invalidates the arming — and the safe direction is unmistakable,
    /// since re-arming costs one keystroke and a mistaken broadcast can't be
    /// taken back.
    private func disarm(_ tab: Tab, reason: MultiExecDisarmReason) {
        guard tab.broadcastArmed else { return }
        objectWillChange.send()
        tab.broadcastArmed = false
        tab.disarmNotice = reason
        notifyWorkspaceChanged()
    }

    /// Every armed tab, for events that invalidate all of them at once.
    func disarmAll(reason: MultiExecDisarmReason) {
        for tab in tabs where tab.broadcastArmed { disarm(tab, reason: reason) }
    }

    /// Sleep is the one event that invalidates every assumption at once: the
    /// connections may have dropped and silently come back, the hosts may have
    /// been rebooted, and an arbitrary amount of time passed with nobody
    /// watching. Waking to a still-armed grid, with no memory of arming it in
    /// this sitting, is the shape of the accident MultiExec's guardrails exist
    /// to prevent.
    /// Group tabs write their arrangement back at quit as well as at close.
    /// Without this the silent-update rule quietly didn't apply to the most
    /// common way of finishing with a tab: leaving it open and quitting.
    private func observeTerminationForGroups() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureAllGroupLayouts() }
        }
    }

    private func observeSystemWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarmAll(reason: .systemWoke) }
        }
    }

    /// Disarms when the machine changes network.
    ///
    /// The hazard is a jump host or a `ProxyJump` chain resolving somewhere
    /// else than it did when the group was armed. Coming off a VPN, or moving
    /// between office and home Wi-Fi, can leave `prod-db` pointing at a
    /// different machine — or at nothing — while the panes look untouched,
    /// because an established SSH connection survives the change and only
    /// *new* ones follow the new route.
    ///
    /// Deliberately keyed on the interface actually carrying traffic rather
    /// than on reachability. `NWPathMonitor` fires for a great deal that isn't
    /// interesting — every transition through `.unsatisfied` and back, every
    /// change in expensive/constrained flags — and a guardrail that fires
    /// constantly during ordinary work is one people learn to route around.
    /// The first path is the baseline, not a change.
    private func observeNetworkChanges() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = Set(path.availableInterfaces.map(\.name))
            let satisfied = path.status == .satisfied
            MainActor.assumeIsolated {
                self?.networkPathChanged(interfaces: interfaces, satisfied: satisfied)
            }
        }
        // Started on the main queue rather than a private one so the handler is
        // already where the state it touches lives. The work is a set
        // comparison; hopping to main from a background queue would only add a
        // second closure — and a second capture of `self` — for nothing.
        monitor.start(queue: .main)
    }

    /// Set PORTSIDE_NETWORK_DEBUG=1 to log every path update and the decision
    /// it produced to Console.app.
    ///
    /// This rule fires unprompted and takes a broadcast down, so "did that do
    /// the right thing?" deserves a better answer than watching for a banner to
    /// vanish. A machine with a VPN and half a dozen `utun` interfaces has
    /// plenty of churn that isn't a network *move*, and the way this rule fails
    /// is by crying wolf until people stop trusting it — which is invisible
    /// unless you can see what it saw.
    private static let networkDebugLogging =
        ProcessInfo.processInfo.environment["PORTSIDE_NETWORK_DEBUG"] != nil

    @MainActor
    func networkPathChanged(interfaces: Set<String>, satisfied: Bool) {
        defer { lastNetworkInterfaces = interfaces }
        let disarming = NetworkChangeDecision.shouldDisarm(
            previous: lastNetworkInterfaces, current: interfaces, satisfied: satisfied
        )
        if Self.networkDebugLogging {
            let was = lastNetworkInterfaces.map { $0.sorted().joined(separator: ",") }
                ?? "(first path — baseline)"
            NSLog("Portside network: [%@] -> [%@] satisfied=%@ decision=%@ armedTabs=%d",
                  was,
                  interfaces.sorted().joined(separator: ","),
                  satisfied ? "yes" : "no",
                  disarming ? "DISARM" : "ignore",
                  tabs.filter(\.broadcastArmed).count)
        }
        guard disarming else { return }
        disarmAll(reason: .networkChanged)
    }

    /// Keyboard equivalent of the Grid View toolbar toggle (⇧⌘G).
    func toggleGridView() {
        setGridView(!isGridView)
    }

    // MARK: - Per-pane MultiExec membership

    /// Set while a protected host is waiting on the "include it anyway?"
    /// confirmation, so the dialog can be presented over that specific pane
    /// whether the toggle came from the pane's chip or from ⌥⌘M.
    @Published var pendingProtectedInclusionID: UUID?

    /// Flips one pane in or out of the broadcast. Excluding is immediate;
    /// including a protected host raises the confirmation instead — the caller
    /// commits it via `confirmProtectedInclusion`.
    ///
    /// This is the "run this one command everywhere but those two boxes" move:
    /// drop the panes, run the command, put them back — without disarming.
    func setIncludedInMultiExec(_ session: TerminalSession, included: Bool) {
        if included, session.isProtected {
            pendingProtectedInclusionID = session.id
        } else {
            session.includedInMultiExec = included
            if !included { moveFocusOffExcludedPane() }
        }
    }

    func toggleIncludedInMultiExec(_ session: TerminalSession) {
        setIncludedInMultiExec(session, included: !session.includedInMultiExec)
    }

    /// ⌥⌘M: toggles the focused pane. No-op unless the tab is armed — outside
    /// MultiExec there is nothing to be included in, and silently flipping
    /// invisible state would surprise you the next time you armed it.
    func toggleActivePaneInMultiExec() {
        guard let tab = selectedTab, tab.broadcastArmed, let session = tab.activeLeaf else { return }
        toggleIncludedInMultiExec(session)
    }

    /// Commits the pending protected-host inclusion the confirmation was raised for.
    func confirmProtectedInclusion() {
        guard let id = pendingProtectedInclusionID,
              let session = selectedTab?.leaves.first(where: { $0.id == id }) else { return }
        session.includedInMultiExec = true
        pendingProtectedInclusionID = nil
    }

    /// Include All / Exclude All / Invert across the armed tab's panes.
    ///
    /// Moves focus off a pane the action just excluded. Without this, Invert
    /// Selection could take the broadcast out from under the caret: you keep
    /// typing expecting the group and every keystroke goes to that one host,
    /// because `mirrorUserInput` won't mirror *from* an excluded pane.
    func applyBulkInclusion(_ action: MultiExecBulkAction) {
        guard let tab = selectedTab else { return }
        for session in tab.leaves {
            session.includedInMultiExec = action.applied(included: session.includedInMultiExec,
                                                         isProtected: session.isProtected)
        }
        moveFocusOffExcludedPane()
    }

    /// Moves focus onto the first broadcasting pane when the focused one has
    /// just been excluded, so the next thing typed reaches the group.
    ///
    /// Only ever runs on an *exclusion* — including a pane makes it a
    /// broadcast target, so staying put is already right. Typing into an
    /// excluded pane deliberately (click into it first) still works and is
    /// still useful; what this prevents is landing there without asking.
    private func moveFocusOffExcludedPane() {
        guard let tab = selectedTab, tab.broadcastArmed else { return }
        let panes = tab.leaves.map { (id: $0.id, included: $0.includedInMultiExec) }
        guard let refocused = MultiExecFocus.refocused(from: tab.activePaneID, panes: panes) else { return }
        focusPane(refocused)
        // The ring alone isn't enough: `focusPane` sets `activePaneID`, but the
        // keystrokes follow the AppKit first responder, which is the whole
        // point here. Same pairing pane navigation uses.
        tab.leaves.first { $0.id == refocused }?.focus()
    }

    /// Included / total pane counts for the armed tab's banner.
    var multiExecInclusionCounts: (included: Int, total: Int) {
        let leaves = selectedTab?.leaves ?? []
        return (leaves.filter(\.includedInMultiExec).count, leaves.count)
    }

    /// Whether a bulk action would actually change anything, so the banner and
    /// menu can grey out the ones that wouldn't.
    ///
    /// Include All is not simply `included < total`: it deliberately skips
    /// protected hosts, so on a tab holding one that test leaves the button
    /// live and inert. Asking the action itself keeps the two rules in step.
    func wouldChangeAnything(_ action: MultiExecBulkAction) -> Bool {
        (selectedTab?.leaves ?? []).contains { session in
            action.applied(included: session.includedInMultiExec,
                           isProtected: session.isProtected) != session.includedInMultiExec
        }
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

    // MARK: - Reordering

    /// Moves `tabID` so it sits where `targetID` currently is.
    ///
    /// Order is the user's, and it persists: `currentWorkspace` already stores
    /// tabs in order, so a rearranged bar comes back rearranged. Everything that
    /// tracks a *particular* tab keys off its id, so nothing here disturbs the
    /// selection or the grid link. The things that are index-based — ⌘1–⌘9 and
    /// ⌘⇧[ / ⌘⇧] — follow the new order, which is what you want: after moving a
    /// tab to the front, ⌘1 should select it.
    ///
    /// Insert semantics here, unlike the grid's swap. A tab bar reads as a list,
    /// where dragging something to a position and having the rest close up is
    /// exactly the expectation; a grid reads as a seating chart, where it isn't.
    func moveTab(_ tabID: UUID, before targetID: UUID) {
        guard tabID != targetID,
              let from = tabs.firstIndex(where: { $0.id == tabID }),
              let to = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        objectWillChange.send()
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        notifyWorkspaceChanged()
    }

    /// Moves `tabID` to the end of the bar — a drop past the last tab.
    func moveTabToEnd(_ tabID: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }), from != tabs.count - 1
        else { return }
        objectWillChange.send()
        let tab = tabs.remove(at: from)
        tabs.append(tab)
        notifyWorkspaceChanged()
    }

    /// Exchanges two panes within the selected tab.
    ///
    /// In Grid View this is also how you reorder the *tabs* underneath, without
    /// any write-back: leaving the grid maps `tab.leaves` — which is tree order —
    /// back onto tabs one for one, so a pane that moved has already moved its
    /// tab. Rearranging the grid and toggling out of it leaves the bar in the
    /// order you arranged.
    func swapPanes(_ a: UUID, _ b: UUID) {
        guard a != b, let tab = selectedTab, let root = tab.root else { return }
        let swapped = root.swappingLeaves(a, b)
        guard swapped.leaves.map(\.id) != root.leaves.map(\.id) else { return }
        objectWillChange.send()
        tab.root = swapped
        notifyWorkspaceChanged()
    }

    /// Swaps the focused pane with the one after (or before) it in the grid.
    ///
    /// The same operation the drag performs, reachable from the keyboard —
    /// which also makes it testable, since a drag isn't. Stops at the ends
    /// rather than wrapping: rearranging is a placing motion, and a pane
    /// leaping from one corner to the other is rarely what you meant.
    func moveActivePane(forward: Bool) {
        guard let tab = selectedTab else { return }
        let ids = tab.leaves.map(\.id)
        guard let active = tab.activePaneID, let index = ids.firstIndex(of: active) else { return }
        let target = index + (forward ? 1 : -1)
        guard ids.indices.contains(target) else { return }
        swapPanes(active, ids[target])
    }

    /// Whether there's anywhere for the focused pane to move, for the menu.
    func canMoveActivePane(forward: Bool) -> Bool {
        guard let tab = selectedTab, let active = tab.activePaneID else { return false }
        let ids = tab.leaves.map(\.id)
        guard let index = ids.firstIndex(of: active) else { return false }
        return ids.indices.contains(index + (forward ? 1 : -1))
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
            // Carry a rename across the merge. Gathering tabs into a grid built
            // a fresh Tab and dropped `customTitle`, so renaming a tab and then
            // arming MultiExec silently reverted the name — which reads as the
            // rename not having worked.
            //
            // Only when exactly one source tab has one: with several there is
            // no non-arbitrary answer, and picking would be worse than not.
            // `groupID` is deliberately *not* carried — a grid merging several
            // tabs is not the group any one of them came from, and inheriting
            // the link would have closing it write this merged layout back over
            // the saved group.
            let renamed = tabs.compactMap(\.customTitle)
            if renamed.count == 1 { grid.customTitle = renamed[0] }
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
        let tabSnapshots = persistable.map {
            WorkspaceSnapshot.TabSnapshot(root: snapshot(of: $0.1), groupID: $0.0.groupID)
        }
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
        case .split(_, let orientation, let children):
            return .split(orientation: orientation, children: children.map(snapshot(of:)))
        }
    }

    // MARK: - Groups

    /// What a group launch actually managed to open.
    struct GroupLaunchResult: Equatable {
        var opened: Int
        var missing: [UUID]
        /// The group already had a tab, which was brought forward instead.
        var wasAlreadyOpen = false
        var isComplete: Bool { missing.isEmpty }

        /// What to tell the user, or nil when the group opened whole.
        ///
        /// Shared by every launch site — the sidebar, the welcome screen —
        /// because a group that opened six of eight panes has to say so
        /// wherever it was opened from. Silently opening most of a group is how
        /// you run a command believing it reached the whole platform.
        func notice(for group: SessionGroup, nameForID: (UUID) -> String?) -> String? {
            guard !isComplete else { return nil }
            let names = missing
                .map { nameForID($0) ?? "a deleted host" }
                .joined(separator: ", ")
            return opened == 0
                ? "“\(group.name)” couldn't open — none of its hosts are in the library any more."
                : "Opened \(opened) of \(group.paneCount) in “\(group.name)”. "
                  + "No longer in the library: \(names)."
        }
    }

    /// Captures the selected tab's arrangement as a named group.
    ///
    /// Returns nil for a start page — there's no layout to save, and a group
    /// that opens nothing is worse than no group.
    func groupFromSelectedTab(named name: String, folder: String = "") -> SessionGroup? {
        guard let tab = selectedTab, let root = tab.root else { return nil }
        return SessionGroup(
            name: name, folder: folder,
            layout: WorkspaceSnapshot.TabSnapshot(root: snapshot(of: root)),
            wasGridView: isGridView
        )
    }

    /// Opens a group as one tab, in the arrangement it was saved in.
    ///
    /// Reuses the workspace-restore path rather than a second replay: a group
    /// *is* a saved tab, and that machinery already rebuilds pane trees,
    /// restores split fractions and membership, and leaves everything
    /// disarmed. A group inherits that last part deliberately — the grid comes
    /// back assembled and ready, and arming stays a deliberate act.
    ///
    /// A member that's no longer in the library is skipped rather than failing
    /// the launch: eight hosts where one was deleted should open seven and say
    /// so, not refuse.
    @discardableResult
    func launch(_ group: SessionGroup, entryForID: (UUID) -> SessionEntry?) -> GroupLaunchResult {
        // Already open: bring it forward rather than opening it twice.
        //
        // Two tabs carrying the same groupID is not just clutter — closing a
        // group tab writes its arrangement back, so duplicates compete and
        // whichever is closed last silently overwrites the other. Selecting the
        // existing one is also what you meant: double-clicking a group you are
        // already looking at should take you to it.
        if let open = tabs.first(where: { $0.groupID == group.id }) {
            selectedTabID = open.id
            return GroupLaunchResult(opened: open.leaves.count, missing: [], wasAlreadyOpen: true)
        }

        let missing = group.memberEntryIDs.filter { entryForID($0) == nil }
        let snapshot = WorkspaceSnapshot(
            tabs: [group.layout], selectedTabIndex: 0, wasGridView: group.wasGridView
        )
        let plan = snapshot.plan(entryForID: entryForID)
        guard !plan.tabs.isEmpty else { return GroupLaunchResult(opened: 0, missing: missing) }
        restore(plan)
        selectedTab?.groupID = group.id
        return GroupLaunchResult(opened: selectedTab?.leaves.count ?? 0, missing: missing)
    }

    /// Writes a group's arrangement back when its tab closes.
    ///
    /// Silent, with undo, rather than an explicit "Update Group" step — chosen
    /// to be lived with for a few days rather than argued about. A tab that
    /// didn't come from a group writes nothing.
    private func captureGroupLayout(from tab: Tab) {
        guard let groupID = tab.groupID, let root = tab.root else { return }
        onGroupLayoutChange?(
            groupID,
            WorkspaceSnapshot.TabSnapshot(root: snapshot(of: root), groupID: groupID),
            isGridView
        )
    }

    /// Wired to the store so a closing group tab persists its arrangement.
    var onGroupLayoutChange: ((UUID, WorkspaceSnapshot.TabSnapshot, Bool) -> Void)?

    /// Writes a group tab's arrangement back now rather than at close.
    ///
    /// The silent-on-close rule covers the ordinary path, but it only fires on
    /// `closeTab` — quitting with the tab still open never wrote anything back,
    /// so a rearranged grid was silently discarded by the one action people take
    /// most. This is both the explicit "Update" command and what termination
    /// calls.
    func captureGroupLayoutIfLinked(_ tab: Tab) {
        captureGroupLayout(from: tab)
    }

    /// Every open group tab, at quit.
    private func captureAllGroupLayouts() {
        for tab in tabs where tab.groupID != nil { captureGroupLayout(from: tab) }
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
        let tab = Tab(root: root, activePaneID: root.leaves.first?.id ?? UUID())
        tab.groupID = tabPlan.groupID
        return tab
    }

    private func buildNode(_ plan: RestorePlan.PanePlan) -> PaneNode<TerminalSession>? {
        switch plan {
        case .leaf(let action):
            return .leaf(makeRestoredSession(action))
        case .split(let orientation, let children):
            let kept = children.compactMap { buildNode($0) }
            switch kept.count {
            case 0: return nil
            case 1: return kept[0]
            default: return .split(id: UUID(), orientation: orientation, children: kept)
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
            // Where the closed pane sat, before the tree loses it.
            let closedIndex = tab.leaves.firstIndex { $0.id == session.id }
            tab.root = newRoot
            if tab.activePaneID == session.id {
                // The pane that slid into its place, or the last one if it was
                // at the end — not `leaves.first`, which threw focus back to
                // the far side of the grid on every close.
                let survivors = tab.leaves
                let successor = closedIndex.flatMap {
                    survivors.indices.contains($0) ? survivors[$0] : survivors.last
                } ?? survivors.first
                tab.activePaneID = successor?.id
                // And the responder has to follow the model. It didn't, so
                // closing a pane left first responder on a detached view — and
                // ⌃D, which only closes a dead pane when that pane *is* first
                // responder, silently stopped working partway through clearing
                // a grid. The muscle memory is to hold ⌃D down; it has to keep
                // landing on whatever is in front of you.
                DispatchQueue.main.async { [weak successor] in successor?.focus() }
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
        // Before the panes go: a group tab remembers the arrangement you're
        // leaving, not the one you first saved.
        captureGroupLayout(from: tab)
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
    ///
    /// See `ClosedTabRing` for why this is in-memory only.
    @Published private(set) var closedTabRing = ClosedTabRing()

    var closedTabs: [ClosedTab] { closedTabRing.entries }

    private func rememberForReopen(_ tab: Tab) {
        guard let root = tab.root, let plan = planNode(for: root) else { return }
        let tabPlan = RestorePlan.TabPlan(root: plan)
        closedTabRing.record(ClosedTab(plan: tabPlan,
                                       title: tab.customTitle ?? tab.activeLeaf?.title ?? "shell",
                                       customTitle: tab.customTitle,
                                       paneCount: tabPlan.root.leafCount,
                                       closedAt: Date()))
    }

    /// Reopens the most recently closed tab (⇧⌘T), same as a browser's
    /// "reopen closed tab" — reuses the same restore-plan builder as launch
    /// restore and Duplicate Tab.
    func reopenLastClosedTab() {
        guard let closed = closedTabRing.takeMostRecent() else { return }
        restore(closed)
    }

    /// Reopens a specific closed tab chosen from the menu, rather than only the
    /// most recent one.
    func reopenClosedTab(id: ClosedTab.ID) {
        guard let closed = closedTabRing.take(id: id) else { return }
        restore(closed)
    }

    private func restore(_ closed: ClosedTab) {
        guard let tab = buildTab(closed.plan) else { return }
        tab.customTitle = closed.customTitle
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Forgets every closed tab without reopening any (File ▸ Recently Closed ▸
    /// Clear). The ring is a record of what you had open, so it needs a way to
    /// be dropped on purpose, same as the connection log.
    func clearClosedTabs() {
        closedTabRing.clear()
    }

    /// Closes the current tab (File ▸ Close Tab).
    ///
    /// Until this existed, closing a whole tab was reachable only from the tab
    /// strip's × button — so "Reopen Closed Tab" could undo something you had
    /// no keyboard way to do.
    ///
    /// Bound to ⌘W, the terminal-app convention. Taking it costs the stock
    /// File ▸ Close its own shortcut: SwiftUI yields ⌘W to this item and strips
    /// its own, re-applying that on every menu-bar open. ⇧⌘W stays Close Pane.
    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(tab)
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
        case .split(_, let orientation, let children):
            let kids = children.compactMap { planNode(for: $0) }
            guard kids.count == children.count else { return nil }
            return .split(orientation: orientation, children: kids)
        }
    }

    /// The included, running panes of a tab — the broadcast targets.
    private func broadcastTargets(in tab: Tab) -> [TerminalSession] {
        tab.leaves.filter { $0.includedInMultiExec && $0.isRunning }
    }

    /// Gate for a paste about to fan out across an armed broadcast.
    ///
    /// Returns true for anything that isn't broadcasting, and for the ordinary
    /// single-command paste — see `BroadcastPasteReview` for why nagging on
    /// those would cost more than it saves.
    private func confirmPasteIfNeeded(_ text: String, from focused: TerminalSession) -> Bool {
        guard let tab = tabs.first(where: { $0.contains(focused.id) }),
              tab.broadcastArmed, focused.includedInMultiExec else { return true }
        let targets = broadcastTargets(in: tab)
        switch BroadcastPasteReview.review(text: text, targetCount: targets.count) {
        case .send:
            return true
        case .confirm(let lineCount, let characterCount):
            return presentPasteConfirmation(
                text: text, lineCount: lineCount, characterCount: characterCount, targets: targets
            )
        }
    }

    /// Names every host that would receive the paste, because "12 panes" is
    /// not something anyone can check and a host list is.
    private func presentPasteConfirmation(
        text: String, lineCount: Int, characterCount: Int, targets: [TerminalSession]
    ) -> Bool {
        // `paste(_:)` is a responder action, so this is genuinely the main
        // thread — the same assertion PortsideApp makes for its termination
        // work, and the reason NSAlert can be driven synchronously here.
        MainActor.assumeIsolated {
            Self.presentPasteConfirmationOnMain(
                text: text, lineCount: lineCount, characterCount: characterCount, targets: targets
            )
        }
    }

    @MainActor
    private static func presentPasteConfirmationOnMain(
        text: String, lineCount: Int, characterCount: Int, targets: [TerminalSession]
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = lineCount > 1
            ? "Run \(lineCount) commands on \(targets.count) panes?"
            : "Paste \(characterCount) characters to \(targets.count) panes?"

        alert.informativeText = "This runs on: \(targetList(targets)).\n\n\(previewLines(of: text))"

        alert.addButton(withTitle: "Run on \(targets.count) Pane\(targets.count == 1 ? "" : "s")")
        alert.addButton(withTitle: "Cancel")
        // Enter is the first button by default; a confirmation for something
        // irreversible should not be dismissible by the reflex that got here.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Names the panes a broadcast will reach, collapsing repeats.
    ///
    /// Naming every pane individually is the point — "12 panes" is not
    /// something anyone can check and a host list is. But a grid of local
    /// shells produced the same string a dozen times over, which reads as
    /// noise and hides the one entry that might be different. Repeats collapse
    /// to `name ×N`, in first-seen order so the list still tracks the grid.
    ///
    /// A pane with no library entry is described, not named: its title is
    /// whatever the shell last reported through OSC, so a grid of local shells
    /// was listing itself as three copies of the last command that ran.
    static func targetList(_ targets: [TerminalSession], limit: Int = 12) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for target in targets {
            let name = target.entry?.name ?? "local shell"
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        let labels = order.map { name -> String in
            let n = counts[name] ?? 0
            return n > 1 ? "\(name) ×\(n)" : name
        }
        // A long grid would push the alert's buttons off-screen; the count
        // carries the rest, and the panes are on screen behind the alert.
        var detail = labels.prefix(limit).joined(separator: ", ")
        if labels.count > limit { detail += " and \(labels.count - limit) more" }
        return detail
    }

    /// The first few lines of what's about to run, so the confirmation shows
    /// the actual commands rather than asking the user to trust their memory
    /// of what they copied.
    private static func previewLines(of text: String, limit: Int = 6) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(limit).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
        }
        var preview = shown.joined(separator: "\n")
        if lines.count > limit { preview += "\n… and \(lines.count - limit) more lines" }
        return preview
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
        session.terminalView.shouldAllowPaste = { [weak self, weak session] text in
            guard let self, let session else { return true }
            return self.confirmPasteIfNeeded(text, from: session)
        }
        // Command capture only runs when it's switched on, so an unopted user
        // pays nothing -- the timeline is never even allocated.
        if recordsCommands {
            session.terminalView.commandTimeline = CommandTimeline(entryID: session.entry?.id)
            session.terminalView.onCommand = { [weak self] event in
                self?.onCommand?(event)
            }
        }
        session.apply(scrollback: terminalSettings.resolvedScrollback)
        session.prefersMetal = terminalSettings.useMetalRenderer
        // Persist the workspace when this session's MultiExec membership is
        // toggled (the checkbox sets the property directly on the session).
        // Republish too: the armed banner's "N of M included" count reads
        // across leaves, which no single @ObservedObject would refresh.
        membershipObservers[session.id] = session.$includedInMultiExec
            .dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.notifyWorkspaceChanged()
            }
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
