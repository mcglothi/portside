import AppKit
import SwiftUI

/// Browsable history: what you ran, and where you've been.
///
/// The commands tab is the reason the OSC 133 capture exists — without a view,
/// recorded commands are a database with no query. Selecting one shows the
/// surrounding transcript, which is what makes command history a table of
/// contents for the session log rather than a second, disconnected record.
struct HistoryView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case commands, connections, events
        var id: String { rawValue }
        var title: String {
            switch self {
            case .commands: return "Commands"
            case .connections: return "Hosts"
            case .events: return "Events"
            }
        }
    }

    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .commands
    @State private var query = ""
    @State private var selected: CommandEvent?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .commands: commandsPane
            case .connections: connectionsPane
            case .events: eventsPane
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField(tab == .commands ? "Filter commands" : "Filter hosts", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    // MARK: - Commands

    private var commands: [CommandEvent] {
        let all = store.commands(limit: 2_000)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.command.localizedCaseInsensitiveContains(query)
                || hostName(for: $0.entryID).localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var commandsPane: some View {
        if !store.history.keepCommandHistory && store.commandHistory.isEmpty {
            empty(
                icon: "terminal",
                title: "Command history is off",
                detail: "Turn it on in Settings ▸ Recording, then install shell integration on a host from the file browser. Commands, timings and exit codes appear here."
            )
        } else if store.commandHistory.isEmpty {
            empty(
                icon: "terminal",
                title: "Nothing recorded yet",
                detail: "Commands appear once a host has shell integration installed — the file browser's ⋯ menu offers it per host."
            )
        } else {
            HSplitView {
                List(commands, selection: Binding(
                    get: { selected?.id },
                    set: { id in selected = commands.first { $0.id == id } }
                )) { event in
                    commandRow(event).tag(event.id)
                }
                .frame(minWidth: 320)

                detailPane
                    .frame(minWidth: 300)
            }
        }
    }

    private func commandRow(_ event: CommandEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon(event))
                .foregroundStyle(statusTint(event))
                .font(.caption)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.command.isEmpty ? "(command not reported)" : event.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(event.command.isEmpty ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(hostName(for: event.entryID))
                    Text(event.startedAt.formatted(date: .abbreviated, time: .standard))
                    if let duration = event.duration, duration >= 1 {
                        Text(durationText(duration))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let event = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.command.isEmpty ? "(command not reported)" : event.command)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent("Host") { Text(hostName(for: event.entryID)) }
                    LabeledContent("Started") {
                        Text(event.startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if let duration = event.duration {
                        LabeledContent("Took") { Text(durationText(duration)) }
                    }
                    LabeledContent("Exit") {
                        Text(event.exitCode.map(String.init) ?? "not reported")
                            .foregroundStyle(statusTint(event))
                    }

                    Divider()
                    transcriptExcerpt(for: event)
                }
                .font(.caption)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a command")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The transcript around the command, when one was being kept. Recorded
    /// commands outlive their transcripts (compression, cleanup, logging off at
    /// the time), so absence is normal and says so plainly.
    @ViewBuilder
    private func transcriptExcerpt(for event: CommandEvent) -> some View {
        if let path = event.logPath, let offset = event.logOffset,
           let text = LogManager.excerpt(path: path, around: offset) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("From the session transcript")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                }
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }
        } else if event.logPath != nil {
            Text("The transcript for this session is no longer available — it may have been compressed or removed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("No transcript was being saved when this ran. Turn on session transcripts in Settings ▸ Recording to capture output alongside commands.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Connections

    private var connectionRows: [(entry: SessionEntry?, stat: ConnectionStat)] {
        let rows = store.connectionStats
            .sorted { $0.lastConnected > $1.lastConnected }
            .map { (store.entry(id: $0.entryID), $0) }
        guard !query.isEmpty else { return rows }
        return rows.filter { ($0.0?.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var connectionsPane: some View {
        if store.connectionStats.isEmpty {
            empty(
                icon: "clock.arrow.circlepath",
                title: "No connections recorded yet",
                detail: "Per-host totals are kept automatically and drive Quick Connect's ordering."
            )
        } else {
            List(connectionRows, id: \.stat.entryID) { row in
                HStack(spacing: 8) {
                    Image(systemName: row.entry?.icon ?? "questionmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        // A stat can outlive the host it refers to.
                        Text(row.entry?.name ?? "Deleted host")
                            .font(.callout)
                            .foregroundStyle(row.entry == nil ? .secondary : .primary)
                        Text("Last connected \(row.stat.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("\(row.stat.count)×")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
    }

    // MARK: - Events (the opt-in full log)

    private var events: [ConnectionLogEntry] {
        let all = store.connectionLog.sorted { $0.at > $1.at }
        guard !query.isEmpty else { return all }
        return all.filter { hostName(for: $0.entryID).localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var eventsPane: some View {
        if !store.history.keepFullLog && store.connectionLog.isEmpty {
            empty(
                icon: "list.bullet.rectangle",
                title: "The connection log is off",
                detail: "Turn it on in Settings ▸ Recording to keep a timestamped record of every connection attempt, including ones that failed. Per-host totals are kept either way and shown under Hosts."
            )
        } else if store.connectionLog.isEmpty {
            empty(
                icon: "list.bullet.rectangle",
                title: "No events recorded yet",
                detail: "Each connection attempt will appear here with its outcome."
            )
        } else {
            List(events) { event in
                HStack(spacing: 8) {
                    Image(systemName: outcomeIcon(event.outcome))
                        .foregroundStyle(outcomeTint(event.outcome))
                        .font(.caption)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hostName(for: event.entryID)).font(.callout)
                        Text(event.at.formatted(date: .abbreviated, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(outcomeLabel(event.outcome))
                        .font(.caption2)
                        .foregroundStyle(outcomeTint(event.outcome))
                }
                .padding(.vertical, 1)
            }
        }
    }

    /// Entries written before outcomes were tracked have none; they're shown as
    /// unknown rather than assumed successful.
    private func outcomeLabel(_ outcome: ConnectionOutcome?) -> String {
        switch outcome {
        case .connected: return "Connected"
        case .failed: return "Failed"
        case .attempted: return "Attempted"
        case nil: return "—"
        }
    }

    private func outcomeIcon(_ outcome: ConnectionOutcome?) -> String {
        switch outcome {
        case .connected: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .attempted: return "circle.dashed"
        case nil: return "questionmark.circle"
        }
    }

    private func outcomeTint(_ outcome: ConnectionOutcome?) -> Color {
        switch outcome {
        case .connected: return .green
        case .failed: return .orange
        case .attempted, nil: return .secondary
        }
    }

    // MARK: - Helpers

    private func empty(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(title).font(.callout)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func hostName(for id: UUID?) -> String {
        guard let id else { return "Local" }
        return store.entry(id: id)?.name ?? "Deleted host"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        return String(format: "%.0fm %.0fs", (seconds / 60).rounded(.down), seconds.truncatingRemainder(dividingBy: 60))
    }

    private func statusIcon(_ event: CommandEvent) -> String {
        switch event.succeeded {
        case true?: return "checkmark.circle.fill"
        case false?: return "xmark.circle.fill"
        default: return "circle.dashed"
        }
    }

    private func statusTint(_ event: CommandEvent) -> Color {
        switch event.succeeded {
        case true?: return .green
        case false?: return .orange
        default: return .secondary
        }
    }
}
