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

    private var transferConcurrencyBinding: Binding<Double> {
        Binding(
            get: { Double(store.defaults.resolvedTransferConcurrency) },
            set: {
                var d = store.defaults
                d.transferConcurrency = Int($0)
                store.updateDefaults(d)
            }
        )
    }

    private var autoAcceptNewHostKeysBinding: Binding<Bool> {
        Binding(
            get: { store.defaults.autoAcceptNewHostKeys ?? false },
            set: { var d = store.defaults; d.autoAcceptNewHostKeys = $0; store.updateDefaults(d) }
        )
    }

    /// Apps that can open plain text — the realistic candidates for editing a
    /// config file — so picking an editor is a list, not a trip through
    /// /Applications. Computed once per view rather than per redraw:
    /// LaunchServices lookups are not free.
    private let textEditors = EditorApps.plainTextEditors()

    private var remoteEditorBinding: Binding<String> {
        Binding(
            get: { store.defaults.remoteEditorPath ?? "" },
            set: {
                var d = store.defaults
                d.remoteEditorPath = $0.isEmpty ? nil : $0
                store.updateDefaults(d)
            }
        )
    }

    private func browseForEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            var d = store.defaults
            d.remoteEditorPath = url.path
            store.updateDefaults(d)
        }
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
            Section("Remote File Editing") {
                Picker("Open remote files in", selection: remoteEditorBinding) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(textEditors, id: \.path) { app in
                        Label {
                            Text(EditorApps.displayName(of: app))
                        } icon: {
                            Image(nsImage: EditorApps.icon(of: app))
                        }
                        .tag(app.path)
                    }
                    // The chosen app may live outside the plain-text handler
                    // list (or have been picked via Other…), so keep its row
                    // present or the picker would silently reset to Default.
                    if let current = store.defaults.remoteEditorURL,
                       !textEditors.contains(current) {
                        Divider()
                        Text(EditorApps.displayName(of: current)).tag(current.path)
                    }
                }
                Button("Choose Another App…") { browseForEditor() }
                Text("Used when you double-click a file in the SFTP browser. Right-click a file and use \"Edit With\" to override it for a single file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("File Transfers") {
                let cap = store.defaults.resolvedTransferConcurrency
                Slider(value: transferConcurrencyBinding, in: 1...8, step: 1) {
                    Text("Copy to \(cap) host\(cap == 1 ? "" : "s") at once")
                } minimumValueLabel: {
                    Text("1").font(.caption)
                } maximumValueLabel: {
                    Text("8").font(.caption)
                }
                Text(cap == 1
                    ? "Hosts are copied to one at a time, so the first finishes soonest — but one unresponsive host holds up every host behind it."
                    : "How many hosts a MultiExec file copy uploads to simultaneously. They share one uplink, so raising this mostly stops a slow host from holding up the group rather than making the whole copy faster.")
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
        .settingsPageSizing()
    }
}
