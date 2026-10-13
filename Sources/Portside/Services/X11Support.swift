import Foundation

/// Whether this Mac can show windows forwarded with `ssh -Y`/`-X`.
///
/// Only consulted for hosts that turn X11 forwarding on, so nobody who doesn't
/// use it is told to install anything. Two things have to be true: an X server
/// (XQuartz) is installed, and ssh has a `DISPLAY` to forward to. Without
/// one, ssh skips the X11 request without a word, which is why this is worth
/// saying.
///
/// `DISPLAY` used to mean Portside's own: XQuartz puts it into the login
/// session, so a fresh install needed a log out and back in before Portside
/// saw it. It doesn't need to. A running XQuartz listens on
/// `/tmp/.X11-unix/X0`, which `DISPLAY=:0` reaches, so ssh children get that
/// when Portside has no `DISPLAY` of its own (`displayEnvironment`).
enum X11Support {
    enum Status: Equatable {
        case ready
        case notInstalled
        /// Installed, but no X server is running and Portside has no DISPLAY.
        case notRunning
    }

    static let installHint = "brew install --cask xquartz"

    private static let serverPaths = [
        "/Applications/Utilities/XQuartz.app",
        "/Applications/XQuartz.app",
        "/opt/X11/bin/Xquartz",
    ]

    /// The socket a running XQuartz serves display :0 on.
    static let displaySocket = "/tmp/.X11-unix/X0"

    static func status(environment: [String: String] = ProcessInfo.processInfo.environment,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Status {
        guard serverPaths.contains(where: exists) else { return .notInstalled }
        if let display = environment["DISPLAY"], !display.isEmpty { return .ready }
        return exists(displaySocket) ? .ready : .notRunning
    }

    /// `DISPLAY` for an ssh child when Portside has none and XQuartz is
    /// running: the case a fresh install is in until the next login.
    static func displayEnvironment(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        if let display = environment["DISPLAY"], !display.isEmpty { return nil }
        return exists(displaySocket) ? "DISPLAY=:0" : nil
    }

    /// What's missing, in a sentence, or nil when X11 will work.
    static func problem(_ status: Status) -> String? {
        switch status {
        case .ready:
            return nil
        case .notInstalled:
            return "X11 forwarding needs XQuartz, which isn't installed. Install it with: \(installHint)"
        case .notRunning:
            return "XQuartz is installed but not running. Open XQuartz, then connect again."
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
