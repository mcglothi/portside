import Foundation

/// Session-logging configuration, persisted in the library.
struct LoggingSettings: Codable, Equatable {
    var enabled: Bool = false
    /// Empty = the default (~/Library/Logs/Portside).
    var directoryPath: String = ""
    /// gzip logs older than this many days on launch; 0 = never compress.
    var compressAfterDays: Int = 14

    var resolvedDirectory: URL {
        if !directoryPath.isEmpty {
            return URL(fileURLWithPath: (directoryPath as NSString).expandingTildeInPath)
        }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Portside")
        return logs
    }
}

/// One hit from a log search.
struct LogMatch: Identifiable {
    let id = UUID()
    let host: String
    let fileURL: URL
    let lineNumber: Int
    let timestamp: String   // nearest preceding time marker, or file date
    let line: String
    let context: [String]   // a few lines around the match
}
