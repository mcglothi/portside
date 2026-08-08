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
            destinationLine
        }
        .padding(16)
    }

    /// The question this sheet gets asked: *which account does it land in?*
    /// Stated once, prominently, and kept truthful as the selection and the
    /// override change.
    private var destinationLine: some View {
        HStack(spacing: 6) {
            Image(systemName: overrideIsActive
                  ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
            Text(plan.accountSummary(override: accountOverride))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(overrideIsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .padding(.top, 4)
    }

    /// Names the credential sudo will be answered with, so nobody has to
    /// reverse-engineer the resolution order to find out what Portside is
    /// about to spend.
    ///
    /// States the rule rather than probing per host: `CredentialStore` is a
    /// thin wrapper over the real Keychain with no cache, so asking it once
    /// per selected host — to build a sentence — is a Keychain hit per host,
    /// and on a dev build a prompt per host.
    private var sudoCredentialNote: String {
        "sudo is answered with the same saved password Portside logs in with, on the "
            + "assumption it is also the sudo password. It is sent once; if sudo wants a "
            + "different one, that host fails and is reported."
    }

    /// Any non-empty account is an override, and every override means sudo.
    /// One rule, so the warning is never conditional on something invisible.
    private var overrideIsActive: Bool {
        KeyDistributor.requiresSudo(account: accountOverride)
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
                            Spacer()
                            // The account, called out rather than left inside
                            // the address — it is the thing being decided.
                            Text(accountLabel(for: entry))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(overrideIsActive ? AnyShapeStyle(.tint)
                                                                  : AnyShapeStyle(.secondary))
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

    /// What this row's key will land under, following the override when set.
    private func accountLabel(for entry: SessionEntry) -> String {
        let override = accountOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return "→ \(override)" }
        if !(entry.sshAlias?.isEmpty ?? true) { return "→ ~/.ssh/config" }
        let user = (entry.user ?? "").trimmingCharacters(in: .whitespaces)
        return user.isEmpty ? "→ ~/.ssh/config" : "→ \(user)"
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
            return "Leave empty and the key goes to each host's own login account — "
                + "no special privileges needed."
        }
        return "Portside still logs in as each host's own user and runs "
            + "sudo. Hosts where that isn't permitted will be reported "
            + "as failures — nothing is retried."
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
                if overrideIsActive {
                    let account = accountOverride.trimmingCharacters(in: .whitespaces)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Requires sudo on every host above.", systemImage: "lock.shield")
                            .font(.callout).bold()
                        Text("The key goes to \(account)’s home, not the account Portside "
                             + "logs in as. That needs sudo, because writing into another "
                             + "account’s home always does.")
                        Text("sudo sh -c '…'  →  installs for \(account)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        // Saying which credential is about to be spent, and on
                        // what. sudo answered from stdin with a blanked prompt
                        // is invisible from here — "sudo just worked" and "sudo
                        // was never needed" look identical — and a feature
                        // built on not spending credentials wrongly should not
                        // spend one silently.
                        Text(sudoCredentialNote)
                        Text("A host that doesn’t permit it is reported as a failure and "
                             + "left alone. sudo is attempted once, never retried.")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
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
        // Prefilled only when every selected host already resolves to this
        // exact account, so leaving it untouched changes nothing. See
        // `KeyDistributionPlan.prefillAccount`.
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
        guard let key else { return }
        results = []
        stage = .running
        pushTask = Task { @MainActor in
            _ = await KeyDistributor.push(
                key: key,
                to: targets,
                password: { entry in
                    // Always the host's own. The login never changes — a
                    // different target account is reached by escalating, not
                    // by logging in as someone else — so this password is both
                    // the one ssh needs and the one `sudo -S` needs.
                    CredentialResolver.password(for: entry, defaultProfileID: defaultProfileID)
                },
                defaults: defaults,
                account: account.isEmpty ? nil : account,
                progress: { result in results.append(result) }
            )
            stage = .finished
        }
    }
}
