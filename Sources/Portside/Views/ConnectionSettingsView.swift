import AppKit
import SwiftUI

/// App-wide default credentials, applied to sessions that leave user/key blank.
struct ConnectionSettingsView: View {
    @EnvironmentObject var store: SessionStore
    /// Draft text for the default password field. Deliberately not preloaded
    /// with the actual saved secret (unlike `userBinding`/`identityBinding`,
    /// which round-trip plain strings) — mirrors the per-host editor's
    /// "(saved — leave blank to keep)" convention, and an explicit Save
    /// button rather than a live per-keystroke write avoids hammering the
    /// Keychain while typing.
    @State private var defaultPasswordDraft = ""
    @State private var hasDefaultPassword = false
    @State private var credentialError: String?

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

    private func saveDefaultPassword() {
        guard !defaultPasswordDraft.isEmpty else { return }
        if CredentialStore.setDefaultPassword(defaultPasswordDraft) {
            hasDefaultPassword = true
            defaultPasswordDraft = ""
        } else {
            credentialError = "Couldn't save the default password to the Keychain."
        }
    }

    private func clearDefaultPassword() {
        CredentialStore.deleteDefaultPassword()
        hasDefaultPassword = false
        defaultPasswordDraft = ""
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
                HStack {
                    SecureField("Default password", text: $defaultPasswordDraft,
                                prompt: Text(hasDefaultPassword
                                    ? "•••••••• (saved — leave blank to keep)"
                                    : "optional — used when a host has no password of its own"))
                        .onSubmit(saveDefaultPassword)
                    Button("Save") { saveDefaultPassword() }
                        .disabled(defaultPasswordDraft.isEmpty)
                    if hasDefaultPassword {
                        Button("Clear") { clearDefaultPassword() }
                    }
                }
                Toggle("Save new session passwords in Keychain by default", isOn: defaultSavePasswordBinding)
            }
            Section {
                Text("User/key apply only when a session doesn't set its own. A host only uses the default password when its own \"Save password in Keychain\" is checked but it has no password saved for itself — handy for a batch of hosts that share one login (pair with the sidebar's bulk \"Save Password in Keychain\" action). Passwords are always stored in the macOS Keychain, never in the session library file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 280)
        .onAppear { hasDefaultPassword = CredentialStore.defaultPassword() != nil }
        .alert("Password Not Saved", isPresented: Binding(
            get: { credentialError != nil }, set: { if !$0 { credentialError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(credentialError ?? "")
        }
    }
}
