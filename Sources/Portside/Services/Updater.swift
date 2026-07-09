import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater so the app can offer "Check for Updates…" and run
/// silent background checks. The feed and signing key live in Info.plist
/// (SUFeedURL / SUPublicEDKey), populated by Scripts/make_app.sh.
final class UpdaterViewModel: ObservableObject {
    let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
