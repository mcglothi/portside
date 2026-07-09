import AppKit
import SwiftUI

/// App-wide default credentials, applied to sessions that leave user/key blank.
struct ConnectionSettingsView: View {
    @EnvironmentObject var store: SessionStore

    private var userBinding: Binding<String> {
        Binding(
            get: { store.defaults.user ?? "" },
            set: { var d = store.defaults; d.user = $0.isEmpty ? nil : $0; store.updateDefaults(d) }
        )
    }

    private var identityBinding: Binding<String> {
        Binding(
            get: { store.defaults.identityFile ?? "" },
            set: { var d = store.defaults; d.identityFile = $0.isEmpty ? nil : $0; store.updateDefaults(d) }
        )
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSString(string: "~/.ssh").expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            var d = store.defaults
            d.identityFile = url.path
            store.updateDefaults(d)
        }
    }

    var body: some View {
        Form {
            Section("Defaults for new connections") {
                TextField("Default user", text: userBinding, prompt: Text("optional"))
                HStack {
                    TextField("Default identity file", text: identityBinding,
                              prompt: Text("optional — e.g. ~/.ssh/id_ed25519"))
                    Button("Browse…") { browseForKey() }
                }
            }
            Section {
                Text("These apply only when a session doesn't set its own user or key. Passwords are stored per session in the macOS Keychain and never here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 240)
    }
}
