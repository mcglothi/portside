import AppKit
import Foundation
import SwiftTerm

/// One live terminal tab: owns the SwiftTerm view and the child process
/// (either `ssh` or a local login shell) running inside it.
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let terminalView: LocalProcessTerminalView
    let entry: SessionEntry?
    @Published var title: String
    @Published var isRunning = true
    @Published var includedInMultiExec: Bool

    var environment: HostEnvironment { entry?.environment ?? .none }
    var isProtected: Bool { entry?.isProtected ?? false }

    init(title: String, executable: String, args: [String], entry: SessionEntry? = nil) {
        self.title = title
        self.entry = entry
        // Protected hosts must be opted in to MultiExec explicitly.
        self.includedInMultiExec = !(entry?.isProtected ?? false)
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
        terminalView.startProcess(executable: executable, args: args)
    }

    func sendText(_ text: String) {
        terminalView.send(txt: text)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { self.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { self.isRunning = false }
    }
}

final class SessionManager: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?
    @Published var multiExecActive = false

    private var keyMonitor: Any?

    init() {
        // MobaXterm-style MultiExec: while armed, a keystroke typed into any
        // included terminal is mirrored to every other included terminal.
        // Peers get the translated byte sequence written to their ptys —
        // forwarding the NSEvent itself doesn't work because text input
        // routes through the focused view's input context.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.multiExecActive,
                  !event.modifierFlags.contains(.command),
                  let focused = event.window?.firstResponder as? LocalProcessTerminalView,
                  let focusedSession = self.sessions.first(where: { $0.terminalView === focused }),
                  focusedSession.includedInMultiExec,
                  let bytes = Self.terminalSequence(for: event)
            else { return event }

            for peer in self.multiExecTargets where peer.terminalView !== focused {
                peer.sendText(bytes)
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
        add(TerminalSession(title: entry.name, executable: "/usr/bin/ssh", args: entry.sshArgs, entry: entry))
    }

    func openLocalShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        add(TerminalSession(title: "local", executable: shell, args: ["-l"]))
    }

    func close(_ session: TerminalSession) {
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
        sessions.append(session)
        selectedID = session.id
    }

    /// Translates a key event into the byte sequence a terminal would send.
    /// Plain characters and control combos come through in `characters`
    /// already encoded (⌃C is \u{03}); function keys arrive as private-use
    /// scalars and need mapping to their escape sequences.
    private static func terminalSequence(for event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty,
              let scalar = chars.unicodeScalars.first
        else { return nil }

        guard (0xF700...0xF8FF).contains(scalar.value) else { return chars }

        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return "\u{1B}[A"
        case NSDownArrowFunctionKey: return "\u{1B}[B"
        case NSRightArrowFunctionKey: return "\u{1B}[C"
        case NSLeftArrowFunctionKey: return "\u{1B}[D"
        case NSHomeFunctionKey: return "\u{1B}[H"
        case NSEndFunctionKey: return "\u{1B}[F"
        case NSPageUpFunctionKey: return "\u{1B}[5~"
        case NSPageDownFunctionKey: return "\u{1B}[6~"
        case NSDeleteFunctionKey: return "\u{1B}[3~"
        case NSF1FunctionKey: return "\u{1B}OP"
        case NSF2FunctionKey: return "\u{1B}OQ"
        case NSF3FunctionKey: return "\u{1B}OR"
        case NSF4FunctionKey: return "\u{1B}OS"
        default: return nil
        }
    }
}
