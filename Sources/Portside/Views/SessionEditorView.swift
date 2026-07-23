import SwiftUI

enum EditorResult<T> {
    case save(T)
    case delete
}

struct SessionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SessionEntry
    @State private var portText: String
    @State private var password = ""
    @State private var hasSavedPassword: Bool
    @State private var credentialError: String?
    // Working copies so the editor can bind to fields even when the draft's
    // optional target is nil; only the active kind's copy is saved back.
    @State private var container: ContainerTarget
    @State private var kubernetes: KubernetesTarget
    @State private var serial: SerialTarget
    @State private var telnet: TelnetTarget
    @State private var availableDevices: [String] = []
    @State private var showingPicker = false
    private let isNew: Bool
    private let folders: [String]
    private let onComplete: (EditorResult<SessionEntry>) -> Void

    init(entry: SessionEntry, folders: [String], onComplete: @escaping (EditorResult<SessionEntry>) -> Void) {
        _draft = State(initialValue: entry)
        _portText = State(initialValue: entry.port.map(String.init) ?? "")
        _hasSavedPassword = State(initialValue: CredentialStore.password(for: entry.id) != nil)
        _container = State(initialValue: entry.container ?? ContainerTarget())
        _kubernetes = State(initialValue: entry.kubernetes ?? KubernetesTarget())
        _serial = State(initialValue: entry.serial ?? SerialTarget())
        _telnet = State(initialValue: entry.telnet ?? TelnetTarget())
        isNew = entry.name.isEmpty
        self.folders = folders
        self.onComplete = onComplete
    }

    private var identityBinding: Binding<String> {
        Binding(
            get: { draft.identityFile ?? "" },
            set: { draft.identityFile = $0.isEmpty ? nil : $0 }
        )
    }

    private func browseForKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: (NSString(string: "~/.ssh").expandingTildeInPath))
        if panel.runModal() == .OK, let url = panel.url {
            draft.identityFile = url.path
        }
    }

    /// Returns whether the password ended up actually persisted (or there was
    /// nothing to persist) — surfaced to the user rather than assumed, since
    /// a Keychain write can fail silently (locked keychain, a stale ACL from
    /// an earlier code signature, etc.).
    private func persistCredentials() -> Bool {
        if draft.savePassword {
            guard !password.isEmpty else { return true }   // unchanged — keeping the existing saved password
            return CredentialStore.setPassword(password, for: draft.id)
        } else {
            CredentialStore.deletePassword(for: draft.id)
            return true
        }
    }

    private var userBinding: Binding<String> {
        Binding(
            get: { draft.user ?? "" },
            set: { draft.user = $0.isEmpty ? nil : $0 }
        )
    }

    private var runOnConnectBinding: Binding<String> {
        Binding(
            get: { draft.runOnConnect ?? "" },
            set: { draft.runOnConnect = $0.isEmpty ? nil : $0 }
        )
    }

    private var aliasBinding: Binding<String> {
        Binding(
            get: { draft.sshAlias ?? "" },
            set: { draft.sshAlias = $0.isEmpty ? nil : $0 }
        )
    }

    private var canSave: Bool {
        guard !draft.name.isEmpty else { return false }
        switch draft.kind {
        case .host:
            return !draft.hostname.isEmpty || !(draft.sshAlias ?? "").isEmpty
        case .container:
            return !container.name.trimmingCharacters(in: .whitespaces).isEmpty
        case .kubernetes:
            return !kubernetes.pod.trimmingCharacters(in: .whitespaces).isEmpty
        case .serial:
            return !serial.devicePath.isEmpty
        case .telnet:
            return !telnet.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Field groups

    @ViewBuilder private var folderRow: some View {
        HStack {
            TextField("Folder", text: $draft.folder, prompt: Text("e.g. prod/web — empty for top level"))
            if !folders.isEmpty {
                Menu {
                    ForEach(folders, id: \.self) { folder in
                        Button(folder) { draft.folder = folder }
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    @ViewBuilder private var transportHeader: some View {
        Text(draft.kind == .container
             ? "Connect via — the SSH host the container runs on. Leave Host blank to run on this Mac."
             : "Connect via — an SSH host with cluster access. Leave Host blank to use this Mac.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var sshFields: some View {
        TextField(draft.kind == .host ? "Host" : "Host (via)", text: $draft.hostname,
                  prompt: Text(draft.kind == .host ? "hostname or IP" : "blank = this Mac"))
        TextField("User", text: userBinding, prompt: Text("optional"))
        TextField("Port", text: $portText, prompt: Text("22"))
        TextField("~/.ssh/config alias", text: aliasBinding, prompt: Text("optional — connects via ssh <alias>"))
        HStack {
            TextField("Identity file (key)", text: identityBinding,
                      prompt: Text("optional — e.g. ~/.ssh/id_ed25519"))
            Button("Browse…") { browseForKey() }
        }
    }

    @ViewBuilder private var passwordFields: some View {
        Toggle("Save password in Keychain", isOn: $draft.savePassword)
        if draft.savePassword {
            SecureField("Password", text: $password,
                        prompt: Text(hasSavedPassword ? "•••••••• (saved — leave blank to keep)" : "required"))
            Text("Stored in the macOS Keychain and supplied to ssh automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var moshToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Connect with mosh", isOn: $draft.preferMosh)
            if draft.preferMosh {
                if MoshLocator.isAvailable {
                    Text("Roams across networks and survives sleep. Needs mosh-server on the host. The file browser and tunnels need plain ssh, so they're unavailable on mosh sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("mosh isn't installed — falling back to ssh. Install with: brew install mosh")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var runOnConnectField: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Run on connect", text: runOnConnectBinding,
                      prompt: Text("optional — e.g. tmux attach || tmux new"))
            Text("Sent to the shell a moment after connecting. Works with key, agent, or saved-password auth; skip it for hosts that prompt for a password interactively.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var containerFields: some View {
        Picker("Engine", selection: $container.engine) {
            ForEach(ContainerTarget.Engine.allCases) { engine in
                Text(engine.label).tag(engine)
            }
        }
        HStack {
            TextField("Container", text: $container.name, prompt: Text("name or id — e.g. web"))
            Button("Browse…") { showingPicker = true }
        }
        TextField("Shell", text: $container.shell, prompt: Text("sh"))
        TextField("Exec as user", text: $container.user, prompt: Text("optional — e.g. root"))
        commandPreview(container.execCommand)
    }

    @ViewBuilder private var kubernetesFields: some View {
        TextField("Context", text: $kubernetes.context,
                  prompt: Text("optional — e.g. nkp-prod or gke_proj_zone_cluster"))
        TextField("Namespace", text: $kubernetes.namespace, prompt: Text("optional — default"))
        HStack {
            TextField("Pod", text: $kubernetes.pod, prompt: Text("e.g. api-7d9f8"))
            Button("Browse…") { showingPicker = true }
        }
        TextField("Container", text: $kubernetes.container,
                  prompt: Text("optional — for multi-container pods"))
        TextField("Shell", text: $kubernetes.shell, prompt: Text("sh"))
        commandPreview(kubernetes.execCommand)
    }

    @ViewBuilder private var serialFields: some View {
        Picker("Device", selection: $serial.devicePath) {
            if serial.devicePath.isEmpty {
                Text("None").tag("")
            } else if !availableDevices.contains(serial.devicePath) {
                // Saved sessions should still show their device even when the
                // adapter is unplugged right now, rather than silently blank.
                Text("\(serial.deviceName) (not connected)").tag(serial.devicePath)
            }
            ForEach(availableDevices, id: \.self) { path in
                Text((path as NSString).lastPathComponent).tag(path)
            }
        }
        .onAppear { refreshDevices() }
        HStack {
            Text("No devices found — check the cable, or")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(availableDevices.isEmpty ? 1 : 0)
            Button("Refresh") { refreshDevices() }
                .font(.caption)
        }
        Picker("Baud", selection: $serial.baudRate) {
            ForEach(SerialTarget.baudRates, id: \.self) { rate in
                Text(String(rate)).tag(rate)
            }
        }
        Picker("Data bits", selection: $serial.dataBits) {
            Text("8").tag(8)
            Text("7").tag(7)
        }
        Picker("Parity", selection: $serial.parity) {
            ForEach(SerialTarget.Parity.allCases) { p in
                Text(p.label).tag(p)
            }
        }
        Picker("Stop bits", selection: $serial.stopBits) {
            Text("1").tag(1)
            Text("2").tag(2)
        }
        Picker("Flow control", selection: $serial.flowControl) {
            ForEach(SerialTarget.FlowControl.allCases) { f in
                Text(f.label).tag(f)
            }
        }
        Text("\(serial.summary) — the classic console shorthand (baud, data bits, parity, stop bits).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var telnetFields: some View {
        TextField("Host", text: $telnet.host, prompt: Text("hostname or IP"))
        TextField("Port", value: $telnet.port, format: .number)
        Text("Telnet is unencrypted. Use it only on trusted networks or for legacy console servers.")
            .font(.caption)
            .foregroundStyle(.red)
    }

    private func refreshDevices() {
        availableDevices = SerialPortLocator.list()
        if serial.devicePath.isEmpty, let first = availableDevices.first {
            serial.devicePath = first
        }
    }

    /// The current editor state as an entry, so the picker can list against the
    /// transport and engine/context the user has typed but not yet saved.
    private var draftForPicker: SessionEntry {
        var entry = draft
        entry.port = Int(portText)
        entry.container = container
        entry.kubernetes = kubernetes
        return entry
    }

    /// Live preview of the exec command the session will run.
    @ViewBuilder private func commandPreview(_ command: String?) -> some View {
        if let command {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "New Session" : "Edit Session")
                .font(.headline)
            Form {
                TextField("Name", text: $draft.name)
                folderRow
                Picker("Type", selection: $draft.kind) {
                    ForEach(SessionKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }

                switch draft.kind {
                case .host:
                    sshFields
                    moshToggle
                    passwordFields
                    runOnConnectField
                case .container:
                    transportHeader
                    sshFields
                    passwordFields
                    containerFields
                case .kubernetes:
                    transportHeader
                    sshFields
                    passwordFields
                    kubernetesFields
                case .serial:
                    serialFields
                case .telnet:
                    telnetFields
                }

                Picker("Environment", selection: $draft.environment) {
                    ForEach(HostEnvironment.allCases) { env in
                        Text(env.label).tag(env)
                    }
                }
                Toggle("Protected host — excluded from MultiExec unless confirmed", isOn: $draft.isProtected)
            }
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        CredentialStore.deletePassword(for: draft.id)
                        onComplete(.delete)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.port = Int(portText)
                    draft.folder = draft.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    // Persist only the active kind's target.
                    draft.container = draft.kind == .container ? container : nil
                    draft.kubernetes = draft.kind == .kubernetes ? kubernetes : nil
                    draft.serial = draft.kind == .serial ? serial : nil
                    draft.telnet = draft.kind == .telnet ? telnet : nil
                    let credentialsSaved = persistCredentials()
                    onComplete(.save(draft))
                    if credentialsSaved {
                        dismiss()
                    } else {
                        credentialError = "The host was saved, but its password couldn't be written to the Keychain. Try Edit… again to retry."
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .sheet(isPresented: $showingPicker) {
            ContainerPickerView(entry: draftForPicker) { picked in
                if draft.kind == .kubernetes {
                    kubernetes.pod = picked
                } else {
                    container.name = picked
                }
            }
        }
        .alert("Password Not Saved", isPresented: Binding(
            get: { credentialError != nil }, set: { if !$0 { credentialError = nil } }
        )) {
            Button("OK") { dismiss() }
        } message: {
            Text(credentialError ?? "")
        }
    }
}

struct MacroEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Macro
    private let isNew: Bool
    private let onComplete: (EditorResult<Macro>) -> Void

    init(macro: Macro, onComplete: @escaping (EditorResult<Macro>) -> Void) {
        _draft = State(initialValue: macro)
        isNew = macro.name.isEmpty
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Macro" : "Edit Macro")
                .font(.headline)
            TextField("Name", text: $draft.name)
            Text("Text sent to the terminal (multi-line runs line by line):")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft.text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Toggle("Press Return after sending", isOn: $draft.sendReturn)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        onComplete(.delete)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onComplete(.save(draft))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.isEmpty || draft.text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
