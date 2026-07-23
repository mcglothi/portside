import AppKit
import SwiftUI

/// App-wide default credentials, applied to sessions that leave user/key blank.
/// The default *password* lives in Settings ▸ Profiles now (the "Default"
/// credential profile) — see `CredentialProfilesView`.
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

    private var defaultSavePasswordBinding: Binding<Bool> {
        Binding(
            get: { store.defaults.defaultSavePassword ?? false },
            set: { var d = store.defaults; d.defaultSavePassword = $0; store.updateDefaults(d) }
        )
    }

    private var autoAcceptNewHostKeysBinding: Binding<Bool> {
        Binding(
            get: { store.defaults.autoAcceptNewHostKeys ?? false },
            set: { var d = store.defaults; d.autoAcceptNewHostKeys = $0; store.updateDefaults(d) }
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
                Toggle("Save new session passwords in Keychain by default", isOn: defaultSavePasswordBinding)
            }
            Section {
                Text("User/key apply only when a session doesn't set its own. Default passwords are managed as credential profiles now — see Settings ▸ Profiles. Passwords are always stored in the macOS Keychain, never in the session library file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Host Key Verification") {
                Toggle("Automatically accept new host keys", isOn: autoAcceptNewHostKeysBinding)
                Text("Skips the \"yes/no\" prompt the first time you connect to a host. A host you've already connected to before is unaffected — if its key ever changes afterward, ssh still refuses to connect and warns you, exactly as it does today. Applies to plain SSH connections only, not mosh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 360)
    }
}
