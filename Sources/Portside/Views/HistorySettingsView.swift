import SwiftUI

/// Everything Portside records, in one place.
///
/// Logging and history capture genuinely different things — a transcript of
/// what appeared on screen versus structured records of what was run — and are
/// stored differently for good reason: transcripts reach gigabytes and belong
/// in rotating files, not the library JSON. But they were previously governed
/// from two separate tabs with two separate ideas of privacy, so "exclude
/// protected hosts" silently covered history while transcripts of those same
/// hosts kept being written. One surface, one privacy rule.
struct RecordingSettingsView: View {
    @EnvironmentObject var store: SessionStore
    @State private var confirmingClear = false

    private var settings: HistorySettings { store.history }

    private func binding<T: Equatable>(
        _ keyPath: WritableKeyPath<HistorySettings, T>
    ) -> Binding<T> {
        Binding(
            get: { store.history[keyPath: keyPath] },
            set: {
                var updated = store.history
                updated[keyPath: keyPath] = $0
                store.updateHistorySettings(updated)
            }
        )
    }

    var body: some View {
        Form {
            Section("Session transcripts") {
                LoggingControls()
                Text("Writes everything that appears on screen to a rotating log file. Works on every transport, including serial and telnet. Searchable from Tools ▸ Search Logs. The folder and compression settings above apply to transcripts only — they're the one thing here stored as files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connection history") {
                LabeledContent("Per-host totals") {
                    Text("Always on")
                        .foregroundStyle(.secondary)
                }
                Text("How many times you've connected to each host, and when you last did. Used to rank Quick Connect and to spot hosts you haven't touched in a while. Stored in a history file beside your library — not as log files, so the transcript folder and compression settings above don't apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Also keep a full connection log", isOn: binding(\.keepFullLog))
                Text("Records every individual connection with its timestamp — a running record of which machines you accessed and when. Off by default; turning it back off deletes what was collected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.keepFullLog {
                    Picker("Keep at most", selection: binding(\.logLimit)) {
                        Text("500 connections").tag(500)
                        Text("2,000 connections").tag(2_000)
                        Text("10,000 connections").tag(10_000)
                    }
                }
            }

            Section("Command history") {
                Toggle("Record commands and their exit codes", isOn: binding(\.keepCommandHistory))
                Text("Uses the shell integration installed from the file browser (Install Shell Integration) to capture each command, when it ran, how long it took, and whether it succeeded. Hosts without that snippet installed record nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.keepCommandHistory {
                    Label {
                        Text("Command lines are stored in plain text. Anything typed inline — a password in `mysql -p…`, an API token in a `curl` header, a key in an environment assignment — is written to disk as-is. It's kept beside your library rather than inside it, so it won't travel with an exported or shared session library, but it is readable by anything that can read your files. Prefer prompts and environment files for secrets while this is on.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    Picker("Keep at most", selection: binding(\.commandLimit)) {
                        Text("1,000 commands").tag(1_000)
                        Text("5,000 commands").tag(5_000)
                        Text("20,000 commands").tag(20_000)
                    }
                    Text("Turning this off deletes everything already recorded. Takes effect for sessions opened afterwards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Toggle("Stop recording protected hosts", isOn: binding(\.excludeProtectedHosts))
                // Earlier wording said "leaves them out entirely", which read as
                // a guarantee about data already on disk. It only affects what
                // gets written from now on, and transcripts already open keep
                // the settings they started with.
                Text("Applies from now on: protected hosts stop being added to totals, the log, recorded commands, the recents list, and new session transcripts. It does not remove anything already recorded — use Clear History for that — and sessions already open keep the setting they started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stale hosts") {
                Picker("Consider stale after", selection: binding(\.staleAfterDays)) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                }
                Text("Shown in Tools ▸ Coverage, for pruning a large imported library with evidence rather than guesswork.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                    Spacer()
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
        .confirmationDialog(
            "Clear all connection history?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes per-host totals, the connection log, every recorded command, and the recents list. Quick Connect's ranking and stale-host detection start over. This can't be undone.")
        }
    }

    private var summary: String {
        let hosts = store.connectionStats.count
        let total = store.connectionStats.reduce(0) { $0 + $1.count }
        guard hosts > 0 else { return "Nothing recorded yet" }
        let base = "\(total) connection\(total == 1 ? "" : "s") across \(hosts) host\(hosts == 1 ? "" : "s")"
        let commands = store.commandHistory.count
        return commands == 0 ? base : base + ", \(commands) command\(commands == 1 ? "" : "s")"
    }
}
