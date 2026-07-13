import Foundation

/// Finds the mosh client binary. GUI apps don't inherit the shell's PATH,
/// so the common install locations come first, then whatever PATH we have.
enum MoshLocator {
    private static let candidates = [
        "/opt/homebrew/bin/mosh",
        "/usr/local/bin/mosh",
        "/opt/local/bin/mosh",
    ]

    static func find() -> String? {
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return hit
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/mosh"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static var isAvailable: Bool { find() != nil }
}
