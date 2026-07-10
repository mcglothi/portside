import SwiftUI

/// Lists running containers/pods for an in-progress session and returns the
/// one the user picks, so they don't have to remember churning names/ids.
struct ContainerPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: SessionEntry
    let onPick: (String) -> Void

    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded([RunningContainer])
        case failed(String)
    }

    private var isKubernetes: Bool { entry.kind == .kubernetes }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(isKubernetes ? "Running Pods" : "Running Containers",
                      systemImage: entry.icon)
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
            .padding(12)

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
            .padding(12)
        }
        .frame(width: 460, height: 360)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text(isKubernetes ? "Listing pods…" : "Listing containers…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let items) where items.isEmpty:
            ContentUnavailableView(
                isKubernetes ? "No running pods" : "No running containers",
                systemImage: entry.icon,
                description: Text(isKubernetes
                    ? "Nothing running in this namespace/context."
                    : "Nothing running on this host.")
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
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Couldn't list \(isKubernetes ? "pods" : "containers")")
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
            let items = try await ContainerLister.list(for: entry)
            state = .loaded(items)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
