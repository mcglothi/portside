import SwiftTerm
import SwiftUI

struct TerminalHostingView: NSViewRepresentable {
    let session: TerminalSession
    var autoFocus = true

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // The view is in the hierarchy here, so the window is available — the
        // one moment SwiftTerm needs to switch to the Metal renderer.
        session.applyMetalIfNeeded()
        guard autoFocus else { return }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
