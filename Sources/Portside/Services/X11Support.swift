import Foundation

/// Whether this Mac can show windows forwarded with `ssh -X`.
///
/// Only consulted for hosts that turn X11 forwarding on, so nobody who doesn't
/// use it is told to install anything. Two things have to be true: an X server
/// (XQuartz) is installed, and Portside was launched with `DISPLAY` set —
/// XQuartz puts it into the login session, so a fresh install needs a log out
/// and back in before apps started afterwards see it. Without `DISPLAY`, ssh
/// skips the X11 request without a word, which is why this is worth saying.
enum X11Support {
    enum Status: Equatable {
        case ready
        case notInstalled
        /// Installed, but Portside's environment has no DISPLAY yet.
        case noDisplay
    }

    static let installHint = "brew install --cask xquartz"

    private static let serverPaths = [
        "/Applications/Utilities/XQuartz.app",
        "/Applications/XQuartz.app",
        "/opt/X11/bin/Xquartz",
    ]

    static func status(environment: [String: String] = ProcessInfo.processInfo.environment,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Status {
        guard serverPaths.contains(where: exists) else { return .notInstalled }
        guard let display = environment["DISPLAY"], !display.isEmpty else { return .noDisplay }
        return .ready
    }

    /// What's missing, in a sentence, or nil when X11 will work.
    static func problem(_ status: Status) -> String? {
        switch status {
        case .ready:
            return nil
        case .notInstalled:
            return "X11 forwarding needs XQuartz, which isn't installed. Install it with: \(installHint)"
        case .noDisplay:
            return "XQuartz is installed but hasn't started for this login yet. Log out and back in, then reopen Portside."
        }
    }

    /// A one-line notice for the terminal when a host asks for X11 and this
    /// Mac can't serve it. Only an explicit "On" counts: "Use ssh config"
    /// can't be read without parsing that config. The caller rules out mosh,
    /// which doesn't forward X11 — but a mosh host that fell back to ssh does.
    static func connectNotice(for entry: SessionEntry, status: Status = status()) -> String? {
        guard entry.kind == .host, entry.forwardX11 == true else { return nil }
        return problem(status)
    }
}
