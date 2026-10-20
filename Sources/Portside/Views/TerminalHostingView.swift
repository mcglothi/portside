import SwiftTerm
import SwiftUI

struct TerminalHostingView: NSViewRepresentable {
    let session: TerminalSession
    /// Whether this is the pane keystrokes should reach — the active pane of
    /// the selected tab. Only that pane takes the keyboard: every pane in a
    /// grid is updated together, and when each asked for focus, whichever
    /// updated last won, regardless of which one you'd clicked (#76).
    var isActive: Bool

    func makeNSView(context: Context) -> ProcessTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: ProcessTerminalView, context: Context) {
        // The view is in the hierarchy here, so the window is available — the
        // one moment SwiftTerm needs to switch to the Metal renderer.
        session.applyMetalIfNeeded()
        guard isActive else { return }
        DispatchQueue.main.async {
            guard nsView.window?.firstResponder !== nsView else { return }
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
