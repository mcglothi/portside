import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater so the app can offer "Check for Updates…" and run
/// silent background checks. The feed and signing key live in Info.plist
/// (SUFeedURL / SUPublicEDKey), populated by Scripts/make_app.sh.
final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false
    /// Mirrors Sparkle's own settings (Info.plist `SUEnableAutomaticChecks` /
    /// `SUScheduledCheckInterval` are just the first-launch defaults —
    /// Sparkle persists the live values itself once changed). Setting either
    /// automatically reschedules the next background check; no manual
    /// "restart the timer" call needed.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @Published var updateCheckInterval: TimeInterval {
        didSet { controller.updater.updateCheckInterval = updateCheckInterval }
    }
    @Published private(set) var lastUpdateCheckDate: Date?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        updateCheckInterval = controller.updater.updateCheckInterval
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .assign(to: &$lastUpdateCheckDate)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
