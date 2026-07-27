import AppKit
import SwiftUI

/// Transcript controls, embedded in `RecordingSettingsView` rather than owning
/// their own Settings tab — logging and history are one decision for the user
/// even though they're two mechanisms underneath.
struct LoggingControls: View {
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
        Toggle("Save session transcripts to files", isOn: logging.enabled)

        if store.logging.enabled {
            HStack {
                TextField("Folder", text: Binding(
                    get: {
                        store.logging.directoryPath.isEmpty
                            ? store.logging.resolvedDirectory.path
                            : store.logging.directoryPath
                    },
                    set: { var l = store.logging; l.directoryPath = $0; store.updateLogging(l) }))
                    .truncationMode(.middle)
                Button("Choose…") { chooseDirectory() }
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.logging.resolvedDirectory])
                }
            }

            Picker("Compress transcripts older than", selection: Binding(
                get: { store.logging.compressAfterDays },
                set: { var l = store.logging; l.compressAfterDays = $0; store.updateLogging(l) })) {
                Text("Never").tag(0)
                Text("7 days").tag(7)
                Text("14 days").tag(14)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            Text("Saved per host as timestamped text, ANSI stripped so they stay searchable. Old ones are gzipped on launch and still included in Search Logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
