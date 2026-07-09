import AppKit
import SwiftUI

struct LoggingSettingsView: View {
    @EnvironmentObject var store: SessionStore

    private var logging: Binding<LoggingSettings> {
        Binding(get: { store.logging }, set: { store.updateLogging($0) })
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.logging.resolvedDirectory
        if panel.runModal() == .OK, let url = panel.url {
            var l = store.logging
            l.directoryPath = url.path
            store.updateLogging(l)
        }
    }

    var body: some View {
        Form {
            Section("Session Logging") {
                Toggle("Log session output to files", isOn: logging.enabled)
                Text("Each session is saved as a timestamped text file under a per-host folder, e.g. …/logs/tesla/tesla_2026-07-09_10-05-30.log. ANSI colors are stripped so logs stay searchable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Location") {
                HStack {
                    TextField("Folder", text: Binding(
                        get: { store.logging.directoryPath.isEmpty
                            ? store.logging.resolvedDirectory.path : store.logging.directoryPath },
                        set: { var l = store.logging; l.directoryPath = $0; store.updateLogging(l) }))
                        .truncationMode(.middle)
                    Button("Choose…") { chooseDirectory() }
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.logging.resolvedDirectory])
                    }
                }
            }

            Section("Retention") {
                Picker("Compress logs older than", selection: Binding(
                    get: { store.logging.compressAfterDays },
                    set: { var l = store.logging; l.compressAfterDays = $0; store.updateLogging(l) })) {
                    Text("Never").tag(0)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Text("Old logs are gzipped on launch to save space; they're still included in Search Logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 380)
    }
}
