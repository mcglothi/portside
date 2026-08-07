import AppKit
import SwiftUI

/// Pushes one public key to a selection of hosts.
///
/// The first thing Portside does that changes remote machines, so it is
/// deliberately three screens rather than one button: **choose** what and
/// where, **confirm** against a list naming every host and the key's
/// fingerprint, then **watch** per-host results land. Nothing is contacted
/// before the confirm step.
struct KeyDistributionView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    /// Hosts ticked when the sheet opened (a sidebar selection, usually).
    let preselected: Set<UUID>

    private enum Stage: Equatable {
        case choosing
        case confirming
        case running
        case finished
    }

    @State private var stage: Stage = .choosing
    @State private var keys: [PublicKey] = []
    @State private var loadingKeys = true
    @State private var chosenKey: PublicKey?
    @State private var plan = KeyDistributionPlan(candidates: [])
    @State private var results: [KeyPushResult] = []
    @State private var pushTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch stage {
                case .choosing: choosing
                case .confirming: confirming
                case .running, .finished: running
                }
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .task { await loadKeys() }
        .onDisappear { pushTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.horizontal")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var title: String {
        switch stage {
        case .choosing: return "Copy SSH Key to Hosts"
        case .confirming: return "Confirm"
        case .running: return "Copying key…"
        case .finished: return "Finished"
        }
    }

    private var subtitle: String {
        switch stage {
        case .choosing:
            return "Adds a public key to each host's authorized_keys. Nothing is contacted yet."
        case .confirming:
            return "Check the key and the hosts below. This changes those machines."
        case .running:
            return "\(results.count) of \(plan.count) — one host at a time."
        case .finished:
            return finishedSummary
        }
    }

    private var finishedSummary: String {
        let added = results.filter { $0.outcome == .added }.count
        let had = results.filter { $0.outcome == .alreadyPresent }.count
        let bad = results.filter { !$0.outcome.isSuccess }.count
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if had > 0 { parts.append("\(had) already had it") }
        if bad > 0 { parts.append("\(bad) failed") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: " · ")
    }

    // MARK: - Choosing

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 0) {
            keyPicker
            Divider()
            hostPicker
        }
    }

    private var keyPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Key").font(.subheadline).bold()
            if loadingKeys {
                ProgressView().controlSize(.small)
            } else if keys.isEmpty {
                Text("No public keys found in ~/.ssh. Generate one with `ssh-keygen -t ed25519`.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $chosenKey) {
                    ForEach(keys) { key in
                        Text(key.summary).tag(Optional(key))
                    }
                }
                .labelsHidden()
                if let chosenKey {
                    // The fingerprint is shown *before* the push, not after —
                    // a filename does not identify a key, and this is the only
                    // thing anyone can check against a host or against what
                    // they were sent.
                    Text(chosenKey.fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    if !chosenKey.comment.isEmpty {
                        Text(chosenKey.comment).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(16)
    }

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hosts").font(.subheadline).bold()
                Spacer()
                Button("Select All") { plan.selectAll() }
                    .buttonStyle(.link)
                    .disabled(plan.candidates.allSatisfy { plan.isSelected($0) || $0.isProtected })
                Button("Select None") { plan.selectNone() }
                    .buttonStyle(.link)
                    .disabled(plan.isEmpty)
            }
            if !plan.protectedCandidates.isEmpty {
                Text("Select All skips protected hosts — tick those individually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(plan.candidates, id: \.id) { entry in
                    Toggle(isOn: Binding(
                        get: { plan.isSelected(entry) },
                        set: { plan.set(entry, selected: $0) })
                    ) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                            if entry.isProtected {
                                CapsuleBadge(text: "Protected", style: .tinted(.orange))
                            }
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
    }

    // MARK: - Confirming

    private var confirming: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let chosenKey {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key").font(.caption).foregroundStyle(.secondary)
                        Text(chosenKey.filename).bold()
                        Text(chosenKey.fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if !plan.protectedSelected.isEmpty {
                    Label(
                        "\(plan.protectedSelected.count) protected host\(plan.protectedSelected.count == 1 ? " is" : "s are") included.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hosts (\(plan.count))").font(.caption).foregroundStyle(.secondary)
                    // Every host is named. A count alone is what makes people
                    // click through a confirmation without reading it.
                    ForEach(plan.selectedEntries, id: \.id) { entry in
                        HStack(spacing: 6) {
                            Text("•")
                            Text(entry.name)
                            if entry.isProtected {
                                CapsuleBadge(text: "Protected", style: .tinted(.orange))
                            }
                            Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Each host is contacted once. A wrong password will not be retried — it is reported and left alone, so a bad run can't lock the account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Running

    private var running: some View {
        List {
            ForEach(plan.selectedEntries, id: \.id) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    if let result = results.first(where: { $0.entryID == entry.id }) {
                        Label(result.outcome.label, systemImage: icon(for: result.outcome))
                            .font(.caption)
                            .foregroundStyle(color(for: result.outcome))
                    } else if stage == .running {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func icon(for outcome: KeyPushOutcome) -> String {
        switch outcome {
        case .added: return "checkmark.circle.fill"
        case .alreadyPresent: return "checkmark.circle"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for outcome: KeyPushOutcome) -> Color {
        switch outcome {
        case .added: return .green
        case .alreadyPresent: return .secondary
        case .skipped: return .secondary
        case .failed: return .red
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if stage == .finished, results.contains(where: { !$0.outcome.isSuccess }) {
                Text("Failed hosts were left untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch stage {
            case .choosing:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue…") { stage = .confirming }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenKey == nil || plan.isEmpty)
            case .confirming:
                Button("Back") { stage = .choosing }
                Button(plan.summary(keyName: chosenKey?.filename ?? "key")) { start() }
                    .keyboardShortcut(.defaultAction)
            case .running:
                Button("Stop") { pushTask?.cancel() }
            case .finished:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Work

    private func loadKeys() async {
        plan = KeyDistributionPlan(
            candidates: KeyDistributionPlan.candidates(from: store.entries),
            selected: preselected
        )
        keys = await PublicKeyLocator.discover()
        chosenKey = keys.first
        loadingKeys = false
    }

    private func start() {
        let key = chosenKey
        let targets = plan.selectedEntries
        let defaults = store.defaults
        let defaultProfileID = store.defaultProfileID
        guard let key else { return }
        results = []
        stage = .running
        pushTask = Task { @MainActor in
            _ = await KeyDistributor.push(
                key: key,
                to: targets,
                password: { entry in
                    CredentialResolver.password(for: entry, defaultProfileID: defaultProfileID)
                },
                defaults: defaults,
                progress: { result in results.append(result) }
            )
            stage = .finished
        }
    }
}
