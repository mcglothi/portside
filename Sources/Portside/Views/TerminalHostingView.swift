import SwiftTerm
import SwiftUI

struct TerminalHostingView: NSViewRepresentable {
    let session: TerminalSession
    var autoFocus = true

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        guard autoFocus else { return }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}
