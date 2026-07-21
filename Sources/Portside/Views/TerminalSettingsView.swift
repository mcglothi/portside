import SwiftUI

/// Terminal behavior settings (scrollback today; more terminal-foundation
/// controls to come). Look/colors/fonts live in Appearance.
struct TerminalSettingsView: View {
    @EnvironmentObject var store: SessionStore

    private func lineLabel(_ lines: Int) -> String {
        lines >= 1_000 ? "\(lines / 1_000),000 lines" : "\(lines) lines"
    }

    var body: some View {
        Form {
            Section("Scrollback") {
                Picker("History buffer", selection: Binding(
                    get: { store.terminal.scrollbackLines },
                    set: { var t = store.terminal; t.scrollbackLines = $0; store.updateTerminal(t) })) {
                    ForEach(TerminalSettings.scrollbackOptions, id: \.self) { lines in
                        Text(lineLabel(lines)).tag(lines)
                    }
                }
                Text("How many lines of output each terminal keeps for scrolling and ⌘F search. Applies to open terminals immediately and to every new session. Larger buffers use more memory per tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rendering") {
                Toggle("Use GPU (Metal) rendering", isOn: Binding(
                    get: { store.terminal.useMetalRenderer },
                    set: { var t = store.terminal; t.useMetalRenderer = $0; store.updateTerminal(t) }))
                Text("Experimental. Renders the terminal on the GPU, which can lower CPU use with fast-updating output. If Metal isn't available, Portside stays on the standard renderer. New terminals pick this up; already-open tabs switch when toggled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("On Launch") {
                Picker("Previous sessions", selection: Binding(
                    get: { store.terminal.restoreMode },
                    set: { var t = store.terminal; t.restoreMode = $0; store.updateTerminal(t) })) {
                    ForEach(RestoreMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("Reopen the tabs you had open when you last quit. Hosts reconnect, local shells start fresh; MultiExec reopens as a group but stays disarmed until you turn it on. Deleted hosts are skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 240)
    }
}
