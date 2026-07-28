import AppKit
import Foundation
import UniformTypeIdentifiers

/// The applications macOS already knows can open a given file, so choosing a
/// different editor for a remote file is a short menu rather than a hunt
/// through `/Applications` in an open panel.
enum EditorApps {

    /// Candidate apps for `filename`, best first.
    ///
    /// Two wrinkles make the naive "ask LaunchServices about this file type"
    /// answer wrong for remote ops work:
    ///
    /// 1. Most things you actually edit over SFTP have no extension at all
    ///    (`authorized_keys`, `motd`, `hosts`, `known_hosts`) — there's no UTI
    ///    to look up, so those fall back to plain-text handlers.
    /// 2. Extensions that *do* exist are often registered to nothing useful, or
    ///    to something surprising (`.conf`, `.yml`, `.service`). Plain-text
    ///    editors are therefore appended to every list, so the editor you
    ///    actually want is always present even when the type says otherwise.
    static func candidates(for filename: String) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in typeHandlers(for: filename) + plainTextEditors() where seen.insert(url).inserted {
            result.append(url)
        }
        return result
    }

    /// Apps registered for the file's own type. Empty for extensionless files.
    static func typeHandlers(for filename: String) -> [URL] {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    static func plainTextEditors() -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: .plainText)
    }

    /// What "Edit" opens a remote file in when no preferred editor is set.
    ///
    /// Falling through to `NSWorkspace.shared.open` (the system default
    /// handler) means the file's *own* type decides what runs it — a `.command`
    /// script downloaded over SFTP would be handed straight to Terminal. Since
    /// "Edit" only ever means "show me this file as text", the default has to
    /// be an actual text editor, never LaunchServices' generic dispatch.
    static func safeDefaultEditor() -> URL? {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        if FileManager.default.fileExists(atPath: textEdit.path) { return textEdit }
        return plainTextEditors().first
    }

    static func displayName(of appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func icon(of appURL: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// Opens `fileURL` in a specific app, or in the system default when
    /// `appURL` is nil. Returns false when nothing could be launched.
    static func open(_ fileURL: URL, with appURL: URL?) -> Bool {
        guard let appURL else {
            return NSWorkspace.shared.open(fileURL)
        }
        // The completion-handler form reports launch failures asynchronously;
        // the caller needs a synchronous answer to set the edit's status, so
        // validate the app up front and treat a successful launch request as
        // success. A missing/*moved* app is the realistic failure here.
        guard FileManager.default.fileExists(atPath: appURL.path) else { return false }
        NSWorkspace.shared.open(
            [fileURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()
        )
        return true
    }
}
