import SwiftUI

struct UpdateSettingsView: View {
    @EnvironmentObject var updater: UpdaterViewModel

    /// Sparkle stores the interval as a raw `TimeInterval`; these are the
    /// common presets, tagged by their value so the `Picker` binds directly.
    private static let intervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("Every hour", 3600),
        ("Every 6 hours", 21600),
        ("Daily", 86400),
        ("Weekly", 604800),
    ]

    var body: some View {
        Form {
            Section("Automatic Updates") {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Picker("Check", selection: $updater.updateCheckInterval) {
                    ForEach(Self.intervalOptions, id: \.seconds) { option in
                        Text(option.label).tag(option.seconds)
                    }
                }
                .disabled(!updater.automaticallyChecksForUpdates)
            }
            Section {
                HStack {
                    if let last = updater.lastUpdateCheckDate {
                        Text("Last checked \(last, format: .relative(presentation: .named))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Never checked yet")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 220)
    }
}
