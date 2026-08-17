import AppKit
import SwiftUI

/// Rotates one key for another across a selection of hosts.
///
/// **One sheet, three stages you drive.** Add is non-destructive and repeatable,
/// Verify changes nothing, and only Retire removes anything — and it is offered
/// solely for hosts that passed Verify *in this sheet*. Keeping them in one
/// place is the point: the gate between stage two and stage three is the whole
/// feature, and it is only legible if you can see what each host has proved.
///
/// The staging mirrors `KeyDistributionView`'s choose/confirm/watch, because the
/// destructive stage deserves the same treatment a push gets: a confirmation
/// naming every host, and results per host rather than one "done".
struct KeyRotationView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    /// Hosts ticked when the sheet opened, usually a sidebar selection.
    let preselected: Set<UUID>
    /// The key to retire, chosen before the sheet opened. Set when arriving
    /// from a credential profile, where the key the profile currently names is
    /// self-evidently the one being replaced. The *new* key is never
    /// pre-chosen — that is the decision the sheet exists to make.
    var preselectedOldKeyPath: String? = nil

    @State private var keys: [PublicKey] = []
    @State private var loadingKeys = true
    @State private var newKey: PublicKey?
    @State private var oldKey: PublicKey?
    @State private var accountOverride = ""
    @State private var plan = KeyDistributionPlan(candidates: [])
    @State private var rotation: KeyRotation?
    @State private var phase: KeyRotation.Phase = .add
    /// The stage currently contacting hosts, if any.
    @State private var running: KeyRotation.Phase?
    /// The stage awaiting confirmation, if any. Verify never appears here — it
    /// changes nothing, so asking would be ceremony.
    @State private var confirming: KeyRotation.Phase?
    @State private var work: Task<Void, Never>?
    @State private var readiness: PrivateKeyReadiness?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 660, height: 620)
        .task { await loadKeys() }
        .onDisappear { work?.cancel() }
        // Changing either key builds a fresh rotation, discarding every
        // verification — see `rebuildRotation`. The new key also has to be
        // re-checked locally, since a different key can be locked when the last
        // one wasn't.
        .onChange(of: newKey) { _, _ in
            rebuildRotation()
            Task { await refreshReadiness() }
        }
        .onChange(of: oldKey) { _, _ in rebuildRotation() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(confirming == nil ? "Rotate SSH Key" : "Confirm").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    private var subtitle: String {
        if let confirming {
            return confirming == .retire
                ? "This removes a key from those machines. Check the list."
                : "Check the key and the hosts below. This changes those machines."
        }
        if let running {
            return "\(running.title) — one host at a time."
        }
        guard let rotation else { return "Choose the new key, the old key, and the hosts." }
        return "\(rotation.addedCount) added · \(rotation.verifiedCount) verified · "
            + "\(rotation.retiredCount) retired"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let confirming {
            confirmation(for: confirming)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    keyPickers
                    Divider()
                    stagePicker
                    Divider()
                    hostList
                }
            }
        }
    }

    // MARK: - Keys

    private var keyPickers: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loadingKeys {
                ProgressView().controlSize(.small)
            } else if keys.isEmpty {
                Text("No public keys found in ~/.ssh. Generate one with `ssh-keygen -t ed25519`.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                keyRow("New key", selection: $newKey, key: newKey)
                keyRow("Old key", selection: $oldKey, key: oldKey,
                       placeholder: "Choose the key to retire")
            }
            if let problem = readiness?.problem {
                warning(problem, icon: "exclamationmark.triangle.fill")
            }
            accountField
        }
        .padding(16)
    }

    /// A key picker plus its fingerprint.
    ///
    /// The fingerprint is shown for both keys and shown *now*, because a
    /// filename does not identify a key — and here the consequence of picking
    /// the wrong "old" one is deleting access rather than merely adding it.
    private func keyRow(_ label: String, selection: Binding<PublicKey?>, key: PublicKey?,
                        placeholder: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label).font(.subheadline).bold().frame(width: 64, alignment: .leading)
                Picker("", selection: selection) {
                    if let placeholder {
                        Text(placeholder).tag(Optional<PublicKey>.none)
                    }
                    ForEach(keys) { candidate in
                        Text(candidate.summary).tag(Optional(candidate))
                    }
                }
                .labelsHidden()
            }
            if let key {
                Text(key.fingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 72)
            }
        }
    }

    private var accountField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Account:").frame(width: 64, alignment: .leading)
                TextField("each host's own user", text: $accountOverride)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            if KeyDistributor.requiresSudo(account: accountOverride) {
                Text("Reaching another account needs sudo on every host, answered with the "
                     + "same saved password Portside logs in with. Sent once, never retried.")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.leading, 72)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: accountOverride) { _, _ in rebuildRotation() }
    }

    // MARK: - Stage

    private var stagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $phase) {
                ForEach(KeyRotation.Phase.allCases) { stage in
                    Text("\(stage.rawValue + 1). \(stage.title)").tag(stage)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(phase.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Said here rather than only at the moment of refusal, so the rule
            // is visible before anyone has invested in a plan that can't finish.
            if phase == .retire, let blocker = rotation?.retirementBlocker {
                warning(blocker, icon: "lock.fill")
            }
        }
        .padding(16)
    }

    // MARK: - Hosts

    private var hostList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Hosts").font(.subheadline).bold()
                Spacer()
                Button("Select All") { plan.selectAll(); rebuildRotation(keepingResults: true) }
                    .buttonStyle(.link)
                    .disabled(plan.candidates.allSatisfy { plan.isSelected($0) || $0.isProtected })
                Button("Select None") { plan.selectNone(); rebuildRotation(keepingResults: true) }
                    .buttonStyle(.link)
                    .disabled(plan.isEmpty)
            }
            if !plan.protectedCandidates.isEmpty {
                Text("Select All skips protected hosts — tick those individually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(plan.candidates, id: \.id) { entry in
                hostRow(entry)
            }
        }
        .padding(16)
    }

    private func hostRow(_ entry: SessionEntry) -> some View {
        Toggle(isOn: Binding(
            get: { plan.isSelected(entry) },
            set: { plan.set(entry, selected: $0); rebuildRotation(keepingResults: true) })
        ) {
            HStack(spacing: 6) {
                Text(entry.name)
                if entry.isProtected {
                    CapsuleBadge(text: "Protected", style: .tinted(.orange))
                }
                Spacer()
                if running != nil, plan.isSelected(entry), statuses(for: entry).isEmpty {
                    ProgressView().controlSize(.small)
                }
                ForEach(statuses(for: entry), id: \.text) { status in
                    Label(status.text, systemImage: status.icon)
                        .font(.caption)
                        .foregroundStyle(status.color)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
    }

    private struct Status {
        let text: String
        let icon: String
        let color: Color
    }

    /// What this host has been through, in stage order — so a row reads as a
    /// history rather than replacing one answer with the next. The verify
    /// result is the one that decides whether stage three is available, so it
    /// keeps its own colour even once a retirement has landed.
    private func statuses(for entry: SessionEntry) -> [Status] {
        guard let rotation else { return [] }
        var out: [Status] = []
        if let added = rotation.added[entry.id] {
            out.append(Status(text: added.label, icon: icon(added), color: colour(added)))
        }
        if let verified = rotation.verified[entry.id] {
            out.append(Status(text: verified.label,
                              icon: verified.provesKeyWorks ? "checkmark.seal.fill" : "xmark.seal",
                              color: verified.provesKeyWorks ? .green : .orange))
        }
        if let retired = rotation.retired[entry.id] {
            out.append(Status(text: retired.label,
                              icon: retired.isSuccess ? "trash" : "exclamationmark.triangle.fill",
                              color: retired.isSuccess ? .secondary : .red))
        }
        return out
    }

    private func icon(_ outcome: KeyPushOutcome) -> String {
        switch outcome {
        case .added: return "plus.circle.fill"
        case .alreadyPresent: return "checkmark.circle"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func colour(_ outcome: KeyPushOutcome) -> Color {
        switch outcome {
        case .added: return .green
        case .alreadyPresent, .skipped: return .secondary
        case .failed: return .red
        }
    }

    // MARK: - Confirmation

    /// Names every host rather than counting them — the same rule a push
    /// follows, for the same reason.
    private func confirmation(for stage: KeyRotation.Phase) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if stage == .retire, let oldKey {
                    warning("This removes \(oldKey.filename) from the hosts below. Each host "
                            + "copies its authorized_keys aside first, and refuses outright if "
                            + "the new key isn't actually in the file.",
                            icon: "exclamationmark.triangle.fill")
                    fingerprintLine("Removing", oldKey)
                    if let newKey { fingerprintLine("Keeping", newKey) }
                } else if let newKey {
                    fingerprintLine("Adding", newKey)
                }

                Text(stage == .retire ? "Losing the old key" : "Hosts")
                    .font(.subheadline).bold()
                ForEach(targets(for: stage), id: \.id) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack").foregroundStyle(.secondary)
                        Text(entry.name)
                        if entry.isProtected {
                            CapsuleBadge(text: "Protected", style: .tinted(.orange))
                        }
                        Spacer()
                    }
                    .font(.callout)
                }

                if stage == .retire, let oldKey {
                    let stale = KeyRotationReferences.references(
                        to: oldKey, hosts: targets(for: stage),
                        profiles: store.credentialProfiles, defaults: store.defaults)
                    if !stale.isEmpty {
                        // Retiring changes the *host*. It does not change the
                        // pointer on this Mac that tells ssh to offer the key —
                        // and a host that no longer accepts the only key its
                        // config offers is a host you cannot log into.
                        warning("Still set to use \(oldKey.filename) after this: "
                                + stale.map(\.label).joined(separator: ", ")
                                + ". Point them at the new key, or they'll go on offering a key "
                                + "these hosts have stopped accepting.",
                                icon: "link.badge.plus")
                    }
                    Text(KeyRotationReferences.sshConfigCaveat)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if stage == .retire, let rotation, !rotation.verifiedWithoutSuccessfulPush.isEmpty {
                    Text("Verified without this rotation having installed the key: "
                         + rotation.verifiedWithoutSuccessfulPush.map(\.name).joined(separator: ", ")
                         + ". The key is there by some other route, which is worth knowing before "
                         + "removing the old one.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if stage == .retire, let rotation {
                    let skipped = plan.selectedEntries.filter { !rotation.canRetire(hostID: $0.id) }
                    if !skipped.isEmpty {
                        Text("Keeping the old key (not verified): "
                             + skipped.map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fingerprintLine(_ label: String, _ key: PublicKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) \(key.filename)").font(.callout)
            Text(key.fingerprint)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }

    private func warning(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            if confirming != nil {
                Button("Back") { confirming = nil }
                Button(confirmTitle) { start(confirming ?? phase) }
                    .keyboardShortcut(.defaultAction)
            } else if running != nil {
                Button("Stop") { work?.cancel() }
            } else {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(runTitle) { begin(phase) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun(phase))
            }
        }
        .padding(16)
    }

    private var runTitle: String {
        switch phase {
        case .add: return "Add to \(plan.count) host\(plan.count == 1 ? "" : "s")…"
        case .verify: return "Verify \(plan.count) host\(plan.count == 1 ? "" : "s")"
        case .retire:
            let count = rotation?.awaitingRetirement.count ?? 0
            return "Retire on \(count) host\(count == 1 ? "" : "s")…"
        }
    }

    private var confirmTitle: String {
        guard confirming == .retire else { return "Add the key" }
        return rotation?.retirementSummary() ?? "Retire"
    }

    private func canRun(_ stage: KeyRotation.Phase) -> Bool {
        guard newKey != nil, !plan.isEmpty else { return false }
        switch stage {
        case .add:
            return true
        case .verify:
            // A locked or missing private key fails every host identically, so
            // the preflight blocks here rather than producing forty misleading
            // rejections.
            return readiness?.isReady ?? false
        case .retire:
            return rotation.map { !$0.awaitingRetirement.isEmpty && $0.retirementBlocker == nil }
                ?? false
        }
    }

    private func targets(for stage: KeyRotation.Phase) -> [SessionEntry] {
        switch stage {
        case .add, .verify: return plan.selectedEntries
        case .retire: return rotation?.awaitingRetirement ?? []
        }
    }

    // MARK: - Work

    private func loadKeys() async {
        // Resolved, not raw — the same rule the push path follows, so the
        // account each key lands in is the one ssh will actually log in as.
        plan = KeyDistributionPlan(
            candidates: KeyDistributionPlan.candidates(from: store.entries.map(store.resolved)),
            selected: preselected
        )
        keys = await PublicKeyLocator.discover()
        if let preselectedOldKeyPath {
            // A profile's key can live outside ~/.ssh, so read it directly
            // rather than quietly retiring a different key than the one named.
            if let known = keys.first(where: { $0.path == preselectedOldKeyPath }) {
                oldKey = known
            } else if let loaded = await PublicKeyLocator.load(path: preselectedOldKeyPath) {
                keys.insert(loaded, at: 0)
                oldKey = loaded
            }
        }
        // Never the same key as the one being retired: that rotation is a
        // no-op the model refuses anyway, and offering it as the default reads
        // like a suggestion.
        newKey = keys.first { $0 != oldKey } ?? keys.first
        loadingKeys = false
        rebuildRotation()
        await refreshReadiness()
    }

    private func refreshReadiness() async {
        guard let newKey else {
            readiness = nil
            return
        }
        readiness = await KeyRotator.readiness(of: newKey)
    }

    /// Rebuilds the rotation when its identity changes.
    ///
    /// `keepingResults` is only ever true for a change of *host selection*.
    /// Changing either key produces a brand-new `KeyRotation`, which is what
    /// discards every verification — a proof about one key says nothing about
    /// another, and this is the mechanism that makes "verified in this session"
    /// true rather than merely intended.
    private func rebuildRotation(keepingResults: Bool = false) {
        guard let newKey else {
            rotation = nil
            return
        }
        let hosts = plan.selectedEntries
        let account = accountOverride.trimmingCharacters(in: .whitespaces)
        if keepingResults, let existing = rotation,
           existing.newKey == newKey, existing.oldKey == oldKey, existing.account == account {
            rotation = existing.retargeted(to: hosts)
        } else {
            rotation = KeyRotation(hosts: hosts, newKey: newKey, oldKey: oldKey, account: account)
        }
    }

    /// Stage two changes nothing, so it runs on the spot; the two that touch
    /// hosts go through a confirmation naming every one of them.
    private func begin(_ stage: KeyRotation.Phase) {
        if stage == .verify {
            start(stage)
        } else {
            confirming = stage
        }
    }

    private func start(_ stage: KeyRotation.Phase) {
        guard let newKey, var current = rotation else { return }
        confirming = nil
        running = stage

        let account = accountOverride.trimmingCharacters(in: .whitespaces)
        let accountOrNil = account.isEmpty ? nil : account
        let defaults = store.defaults
        let defaultProfileID = store.defaultProfileID
        let targets = targets(for: stage)
        let oldKey = self.oldKey

        work = Task { @MainActor in
            switch stage {
            case .add:
                _ = await KeyDistributor.push(
                    key: newKey, to: targets,
                    password: { CredentialResolver.password(for: $0,
                                                            defaultProfileID: defaultProfileID) },
                    defaults: defaults, account: accountOrNil,
                    progress: { result in
                        current.record(result.outcome, forHost: result.entryID)
                        rotation = current
                    })
            case .verify:
                _ = await KeyRotator.verify(
                    key: newKey, on: targets, defaults: defaults, account: accountOrNil,
                    progress: { result in
                        current.record(result.outcome, forHost: result.entryID)
                        rotation = current
                    })
            case .retire:
                guard let oldKey else { break }
                _ = await KeyRotator.retire(
                    oldKey: oldKey, keeping: newKey, on: targets,
                    password: { CredentialResolver.password(for: $0,
                                                            defaultProfileID: defaultProfileID) },
                    defaults: defaults, account: accountOrNil,
                    progress: { result in
                        current.record(result.outcome, forHost: result.entryID)
                        rotation = current
                    })
            }
            running = nil
            // Land on the next stage, so the order is walked rather than
            // remembered. Never past verify — reaching stage three is something
            // the results have to earn.
            if stage == .add { phase = .verify }
        }
    }
}
