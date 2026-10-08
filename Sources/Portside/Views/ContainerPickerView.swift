import SwiftUI

/// Lists running containers/pods for an in-progress session and returns the
/// one the user picks, so they don't have to remember churning names/ids.
/// For Kubernetes it also picks the context and the container, from the same
/// CLI and kubeconfig the session will use.
struct ContainerPickerView: View {
    enum Mode: String, Identifiable {
        case targets, contexts, containers
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let entry: SessionEntry
    var mode: Mode = .targets
    let onPick: (String) -> Void

    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded([RunningContainer])
        case failed(String)
    }

    private var isKubernetes: Bool { entry.kind == .kubernetes }

    private var title: String {
        switch mode {
        case .targets: return isKubernetes ? "Workloads and Pods" : "Running Containers"
        case .contexts: return "Kubernetes Contexts"
        case .containers: return "Containers in \(entry.kubernetes?.pod ?? "Pod")"
        }
    }

    /// What's being listed, for "Listing …", "No …" and "Couldn't list …".
    private var noun: String {
        switch mode {
        case .targets: return isKubernetes ? "workloads and pods" : "containers"
        case .contexts: return "contexts"
        case .containers: return "containers"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: entry.icon)
                    .font(.headline)
                Spacer()
                Button {
                    state = .loading
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(Metrics.sheetChrome)

            Divider()

            content
                .frame(maxWidth: .infinity, minHeight: 220)

            Divider()

            HStack {
                Text(transportNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Metrics.sheetChrome)
        }
        .frame(width: 460, height: 360)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("Listing \(noun)\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let items) where items.isEmpty:
            EmptyStateView(
                icon: entry.icon,
                title: "No \(noun)",
                detail: mode == .contexts ? "The kubeconfig has no contexts."
                    : isKubernetes ? "Nothing is running in this namespace and context."
                    : "Nothing is running on this host."
            )

        case .loaded(let items):
            List(items) { item in
                Button {
                    onPick(item.name)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.icon)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                            if !item.detail.isEmpty {
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Couldn\u{2019}t list \(noun)")
                    .fontWeight(.medium)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                Text("You can still type the name by hand.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var transportNote: String {
        entry.usesLocalTransport
            ? "Running on this Mac"
            : "Via \(entry.hostname.isEmpty ? (entry.sshAlias ?? "SSH host") : entry.hostname)"
    }

    private func load() async {
        do {
            switch mode {
            case .targets:
                state = .loaded(try await ContainerLister.list(for: entry))
            case .contexts:
                let (contexts, current) = try await ContainerLister.contexts(for: entry)
                state = .loaded(contexts.map { c in
                    let detail = [c.name == current ? "current" : "", c.cluster == c.name ? "" : c.cluster,
                                  c.namespace.isEmpty ? "" : "namespace \(c.namespace)"]
                    return RunningContainer(name: c.name, detail: detail.filter { !$0.isEmpty }.joined(separator: " · "))
                })
            case .containers:
                let (names, defaultName) = try await ContainerLister.containers(for: entry)
                state = .loaded(names.map {
                    RunningContainer(name: $0, detail: $0 == defaultName ? "default \u{2014} used when none is set" : "")
                })
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
