import SwiftUI

/// What Portside doesn't know about the fleet, and the means to fix it here.
///
/// Presented from Tools, matching Search Logs and Port Forwarding. The plan
/// originally argued for a sidebar destination, but a fourth segment crowded
/// the section picker enough to clip its labels — and Tools is already the
/// established home for this kind of workbench view, so consistency with the
/// app beat the abstract argument. The "spot a gap, fix it in bulk" flow works
/// the same either way.
struct CoverageView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var library: LibraryCommands
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []

    private var findings: [InventoryCoverage.Finding] {
        InventoryCoverage.findings(
            entries: store.entries,
            defaults: store.defaults,
            profiles: store.credentialProfiles,
            staleIDs: ConnectionHistory.staleEntryIDs(
                store.connectionStats, staleAfterDays: store.history.staleAfterDays
            ),
            connectedIDs: ConnectionHistory.connectedEntryIDs(store.connectionStats)
        )
    }

    private var covered: Double? {
        InventoryCoverage.coveredFraction(
            entries: store.entries,
            defaults: store.defaults,
            profiles: store.credentialProfiles
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inventory Coverage").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            list
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var list: some View {
        // An empty library and a fully-covered one both show "no findings", and
        // they mean opposite things: nothing to survey versus nothing left to
        // fix. Separated so the view never congratulates you on an empty list.
        if store.entries.contains(where: { $0.kind == .host }) {
            return AnyView(
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        summary
                        if findings.isEmpty {
                            allClear
                        } else {
                            ForEach(findings) { finding in
                                card(for: finding)
                            }
                        }
                    }
                    .padding(10)
                }
            )
        }
        return AnyView(
            EmptyStateView(
                icon: "square.stack.3d.up.slash",
                title: "No hosts to survey",
                detail: "Coverage reports what Portside doesn't know about your fleet — environment tags, credential profiles, hosts you've never reached. Import a ~/.ssh/config or add a session to get started.",
                action: EmptyStateView.Action(label: "Import…") { library.requestImport() }
            )
        )
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let covered {
                HStack {
                    Text("Fully described")
                        .font(.caption)
                    Spacer()
                    Text("\(Int((covered * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: covered)
                    .controlSize(.small)
            } else {
                Text("No hosts in the library yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allClear: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.title)
                .foregroundStyle(.green)
            Text("Every host is tagged and has credentials configured.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func card(for finding: InventoryCoverage.Finding) -> some View {
        let isOpen = expanded.contains(finding.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if isOpen { expanded.remove(finding.id) } else { expanded.insert(finding.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: finding.gap.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(finding.gap.title)
                        .font(.callout)
                    Spacer(minLength: 4)
                    Text("\(finding.entries.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(finding.gap.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isOpen {
                Divider()
                fixBar(for: finding)
                ForEach(finding.entries) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text(entry.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if !entry.folder.isEmpty {
                            Text(entry.folder)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Close the gap for everything listed, in one action — the reason this is
    /// a destination and not a report.
    @ViewBuilder
    private func fixBar(for finding: InventoryCoverage.Finding) -> some View {
        let ids = Set(finding.entries.map(\.id))
        switch finding.gap {
        case .noEnvironment:
            HStack(spacing: 4) {
                Text("Tag all:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(HostEnvironment.allCases.filter { $0 != .none }) { environment in
                    Button(environment.label) {
                        store.setEnvironment(environment, ids: ids)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
            }
        case .noCredentialProfile:
            if store.credentialProfiles.isEmpty {
                Text("Create a profile in Settings ▸ Profiles to apply one here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Text("Apply to all:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(store.credentialProfiles) { profile in
                        Button(profile.name) {
                            store.applyCredentialProfile(profile.id, to: ids)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }
                }
            }
        case .stale:
            Text("Nothing to fix here — this is a usage fact, not a gap. Shown so a big imported library can be pruned with evidence.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .neverConnected:
            // Deliberately no bulk action. The obvious one would be "delete
            // these", and an unvisited host is exactly as likely to be one you
            // simply haven't needed yet as one that was never real.
            Text("Nothing to fix here — open one to find out. Only connections Portside recorded count, so hosts you used before history was on will appear here too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .noStoredCredentials:
            // No bulk fix offered on purpose: this one is frequently *not* a
            // problem (ssh-agent, ~/.ssh/config), and turning on saved
            // passwords across a fleet is not something to make one click away.
            Text("Assign a credential profile or edit a host to add a key. Hosts using ssh-agent need nothing here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
