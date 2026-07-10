import SwiftUI

/// The tunnel manager: saved forwards with live status, start/stop, and CRUD.
/// Presented as a sheet from the sidebar's Tools section; tunnels keep
/// running after it closes.
struct PortForwardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var tunnels: TunnelManager
    @State private var editingForward: PortForward?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Port Forwarding", systemImage: "arrow.left.arrow.right")
                    .font(.headline)
                Spacer()
                Button {
                    editingForward = PortForward()
                } label: {
                    Label("New Tunnel", systemImage: "plus")
                }
            }
            .padding(12)

            Divider()

            if store.forwards.isEmpty {
                ContentUnavailableView(
                    "No tunnels yet",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("Forward a local port through any host in your library — ssh -L, -R, and SOCKS proxies.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.forwards) { forward in
                        ForwardRow(
                            forward: forward,
                            host: store.entry(id: forward.hostID),
                            status: tunnels.status(of: forward),
                            toggle: { toggle(forward) },
                            edit: { editingForward = forward },
                            delete: { delete(forward) }
                        )
                    }
                }
            }

            Divider()

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 420)
        .sheet(item: $editingForward) { forward in
            PortForwardEditorView(
                forward: forward,
                hosts: store.entries,
                isNew: !store.forwards.contains { $0.id == forward.id }
            ) { result in
                switch result {
                case .save(let updated):
                    // A running process would keep serving the old spec.
                    tunnels.stopIfRunning(id: updated.id)
                    store.upsert(updated)
                case .delete:
                    delete(forward)
                }
            }
        }
    }

    private var footerText: String {
        let active = tunnels.activeCount
        if active == 0 { return "Tunnels keep running when this window closes." }
        return "\(active) tunnel\(active == 1 ? "" : "s") active — they keep running when this window closes."
    }

    private func toggle(_ forward: PortForward) {
        if tunnels.status(of: forward).isActive {
            tunnels.stop(forward)
        } else if let host = store.entry(id: forward.hostID) {
            tunnels.start(forward, via: store.resolved(host))
        }
    }

    private func delete(_ forward: PortForward) {
        tunnels.stopIfRunning(id: forward.id)
        store.delete(forward)
    }
}

private struct ForwardRow: View {
    let forward: PortForward
    let host: SessionEntry?
    let status: TunnelStatus
    let toggle: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(forward.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(forward.kind.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                    if forward.autoStart {
                        Image(systemName: "play.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Starts automatically when Portside launches")
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .failed(let message) = status {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(message)
                }
            }
            Spacer()
            if host != nil {
                Button(status.isActive ? "Stop" : "Start", action: toggle)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("host missing")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The session this tunnel used was deleted — edit the tunnel to pick another host.")
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(status.isActive ? "Stop" : "Start", action: toggle)
                .disabled(host == nil)
            Button("Edit…", action: edit)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .onTapGesture(count: 2, perform: edit)
    }

    private var subtitle: String {
        let route = forward.name.isEmpty ? "" : forward.routeText + " — "
        return route + "via " + (host?.name ?? "?")
    }

    private var statusDot: some View {
        Group {
            switch status {
            case .running:
                Circle().fill(Color.green)
            case .connecting:
                Circle().fill(Color.yellow)
            case .failed:
                Circle().fill(Color.red)
            case .stopped:
                Circle().fill(Color.secondary.opacity(0.4))
            }
        }
        .frame(width: 8, height: 8)
        .help(statusHelp)
    }

    private var statusHelp: String {
        switch status {
        case .running: return "Tunnel is up"
        case .connecting: return "Connecting…"
        case .failed: return "Tunnel failed"
        case .stopped: return "Stopped"
        }
    }
}

struct PortForwardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PortForward
    @State private var listenPortText: String
    @State private var destinationPortText: String
    private let hosts: [SessionEntry]
    private let isNew: Bool
    private let onComplete: (EditorResult<PortForward>) -> Void

    init(forward: PortForward, hosts: [SessionEntry], isNew: Bool,
         onComplete: @escaping (EditorResult<PortForward>) -> Void) {
        _draft = State(initialValue: forward)
        _listenPortText = State(initialValue: String(forward.listenPort))
        _destinationPortText = State(initialValue: String(forward.destinationPort))
        self.hosts = hosts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        self.isNew = isNew
        self.onComplete = onComplete
    }

    private var canSave: Bool {
        guard draft.hostID != nil, validPort(listenPortText) else { return false }
        if draft.kind == .dynamic { return true }
        return !draft.destinationHost.isEmpty && validPort(destinationPortText)
    }

    private func validPort(_ text: String) -> Bool {
        guard let port = Int(text) else { return false }
        return (1...65535).contains(port)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "New Tunnel" : "Edit Tunnel")
                .font(.headline)
            Form {
                TextField("Name", text: $draft.name, prompt: Text("optional — e.g. staging DB"))

                Picker("Type", selection: $draft.kind) {
                    ForEach(ForwardKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Text(draft.kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Via host", selection: $draft.hostID) {
                    Text("Choose a host…").tag(UUID?.none)
                    ForEach(hosts) { host in
                        Text(host.folder.isEmpty ? host.name : "\(host.folder)/\(host.name)")
                            .tag(UUID?.some(host.id))
                    }
                }

                TextField(
                    draft.kind == .remote ? "Remote listen port" : "Local listen port",
                    text: $listenPortText, prompt: Text("e.g. 8080")
                )

                if draft.kind != .dynamic {
                    TextField("Destination host", text: $draft.destinationHost,
                              prompt: Text(destinationPrompt))
                    TextField("Destination port", text: $destinationPortText, prompt: Text("e.g. 5432"))
                }

                TextField("Bind address", text: $draft.bindAddress,
                          prompt: Text("optional — 0.0.0.0 to listen on all interfaces"))

                Toggle("Start automatically when Portside launches", isOn: $draft.autoStart)
            }
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
                    draft.listenPort = Int(listenPortText) ?? draft.listenPort
                    draft.destinationPort = Int(destinationPortText) ?? draft.destinationPort
                    onComplete(.save(draft))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var destinationPrompt: String {
        draft.kind == .local
            ? "as seen from the SSH server — e.g. localhost or db01.internal"
            : "as seen from this Mac — e.g. localhost"
    }
}
