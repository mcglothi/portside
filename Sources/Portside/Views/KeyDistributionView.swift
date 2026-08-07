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
    /// Public key chosen when the sheet opened. Set when arriving from a
    /// credential profile, where the key is the whole point of the trip and
    /// picking a different one would be a mistake waiting to happen.
    var preselectedKeyPath: String? = nil

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
    /// Empty means "each host's own resolved user", which is the default and
    /// the common case.
    @State private var accountOverride = ""

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
            accountField
        }
        .padding(16)
    }

    private var accountField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Copy to account:")
                TextField("each host's own user", text: $accountOverride)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            Text(accountHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accountHint: String {
        let account = accountOverride.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty else {
            return "The key goes to whichever account Portside logs in as for each host."
        }
        if overrideHasCredential {
            return "Logs in as \(account) instead, so the key lands in that account's home. "
                + "Using the “\(overrideProfileName ?? account)” profile's password."
            }
        return "Logs in as \(account) instead. No credential profile has that user, so this "
            + "runs key/agent-only — the host's own saved password belongs to a different "
            + "account and will not be offered."
    }

    /// The profile whose user matches the override, if any.
    private var overrideProfile: CredentialProfile? {
        let account = accountOverride.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty else { return nil }
        return store.credentialProfiles.first {
            ($0.user ?? "").trimmingCharacters(in: .whitespaces) == account
        }
    }
    private var overrideProfileName: String? { overrideProfile?.name }
    private var overrideHasCredential: Bool {
        guard let overrideProfile else { return false }
        return CredentialStore.profilePassword(for: overrideProfile.id) != nil
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
                // The single most confusable thing about this operation: the
                // key's *filename* suggests an account (`svc_ansible.pub`),
                // but it lands in the home directory of whoever Portside logs
                // in as for that host. Saying so beside the host list is
                // cheaper than the support question.
                if !accountOverride.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("Logging in as \(accountOverride.trimmingCharacters(in: .whitespaces)) — "
                          + "the key lands in that account's home on every host above.",
                          systemImage: "person.crop.circle.badge.checkmark")
                        .font(.callout)
                        .foregroundStyle(.tint)
                }
                Text("The key is added to each host's login account — the user shown above, resolved from the host, its credential profile, then your defaults. An aliased host uses whatever `~/.ssh/config` says. It does not go to an account named after the key file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
        // **Resolved, not raw.** A host with no user of its own takes one from
        // its credential profile or the library defaults, and every connect
        // path in the app goes through `resolved` for exactly that reason. Raw
        // entries would send `ssh hostname` with no user, ssh would fall back
        // to the local account name, and the key would land in the wrong
        // account's `~/.ssh` — the same failure 0.22.3 fixed for passwords.
        // It also means the user shown next to each host is the one the key
        // will actually be installed for.
        plan = KeyDistributionPlan(
            candidates: KeyDistributionPlan.candidates(from: store.entries.map(store.resolved)),
            selected: preselected
        )
        keys = await PublicKeyLocator.discover()
        if let preselectedKeyPath {
            // The profile's key may live outside ~/.ssh, so fall back to
            // reading it directly rather than silently choosing a different
            // key than the one the profile names.
            if let known = keys.first(where: { $0.path == preselectedKeyPath }) {
                chosenKey = known
            } else if let loaded = await PublicKeyLocator.load(path: preselectedKeyPath) {
                keys.insert(loaded, at: 0)
                chosenKey = loaded
            } else {
                chosenKey = keys.first
            }
        } else {
            chosenKey = keys.first
        }
        loadingKeys = false
    }

    private func start() {
        let key = chosenKey
        let targets = plan.selectedEntries
        let defaults = store.defaults
        let defaultProfileID = store.defaultProfileID
        let account = accountOverride.trimmingCharacters(in: .whitespaces)
        let profiles = store.credentialProfiles
        guard let key else { return }
        results = []
        stage = .running
        pushTask = Task { @MainActor in
            _ = await KeyDistributor.push(
                key: key,
                to: targets,
                password: { entry in
                    // With the account overridden, the host's own password is
                    // for somebody else — see `KeyDistributor.password(forAccount:)`.
                    account.isEmpty
                        ? CredentialResolver.password(for: entry, defaultProfileID: defaultProfileID)
                        : KeyDistributor.password(forAccount: account, profiles: profiles,
                                                  profilePassword: CredentialStore.profilePassword)
                },
                defaults: defaults,
                account: account.isEmpty ? nil : account,
                progress: { result in results.append(result) }
            )
            stage = .finished
        }
    }
}
