import Foundation

/// What a bug report needs to know about this Portside, and nothing that
/// identifies the machines it connects to.
///
/// Reports from people other than the maintainer are what the road to 1.0 is
/// waiting on (`docs/road-to-1.0.md`, gates 1, 4 and 6), and the bug template
/// asks for the version, the macOS version and the library's shape — which
/// people guess at, or skip. This fills them in. It deliberately leaves out
/// everything the template warns against pasting: no hostnames, usernames,
/// folder names, paths, repository URLs or commands. Counts and switches
/// only, and the person sees all of it in the browser before anything is
/// submitted.
struct Diagnostics: Equatable {
    var version: String
    var build: String
    var macOS: String
    var appleSilicon: Bool
    var hostsByKind: [SessionKind: Int]
    var folders: Int
    var groups: Int
    var macros: Int
    var sharedInventories: Int
    var sharedInventoriesOn: Int
    var directoryTrackingOnConnect: Bool
    var sessionLogging: Bool
    var metalRenderer: Bool
    var agentAccess: Bool
    var agentTyping: Bool
    var agentEditing: Bool
    var dontAskAllowed: Bool
    var dontAskOn: Bool
    var approvedPrograms: Int

    var versionLine: String { "\(version) (build \(build))" }
    var macOSLine: String { "\(macOS), \(appleSilicon ? "Apple silicon" : "Intel")" }

    var libraryLine: String {
        let total = hostsByKind.values.reduce(0, +)
        let kinds = SessionKind.allCases.compactMap { kind -> String? in
            guard let n = hostsByKind[kind], n > 0 else { return nil }
            return "\(n) \(kind.label)"
        }
        var parts = ["\(total) \(total == 1 ? "entry" : "entries")" + (kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))")]
        parts.append("\(folders) folders")
        parts.append("\(groups) groups")
        parts.append("\(macros) macros")
        if sharedInventories > 0 {
            parts.append("\(sharedInventories) shared \(sharedInventories == 1 ? "inventory" : "inventories") (\(sharedInventoriesOn) on)")
        }
        return parts.joined(separator: ", ")
    }

    var settingsLines: [String] {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        var lines = [
            "Directory tracking on connect: \(onOff(directoryTrackingOnConnect))",
            "Session logging: \(onOff(sessionLogging))",
            "Metal renderer: \(onOff(metalRenderer))",
            "Agent Access: \(onOff(agentAccess))",
        ]
        if agentAccess {
            lines += [
                "Agent typing: \(onOff(agentTyping))",
                "Agent editing: \(onOff(agentEditing))",
                "Don't Ask: \(dontAskAllowed ? (dontAskOn ? "allowed, on" : "allowed, off") : "not allowed")",
                "Approved programs: \(approvedPrograms)",
            ]
        }
        return lines
    }

    /// Everything, for pasting anywhere.
    var text: String {
        (["Portside \(versionLine)", "macOS \(macOSLine)", "Library: \(libraryLine)"] + settingsLines)
            .joined(separator: "\n")
    }

    /// The bug form with what's known filled in. Field ids are the ones in
    /// `.github/ISSUE_TEMPLATE/bug_report.yml`; GitHub fills an issue form's
    /// fields from query parameters of the same name.
    func issueURL(base: URL = Docs.newBugReport) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "version", value: versionLine),
            URLQueryItem(name: "macos", value: macOSLine),
            URLQueryItem(name: "library", value: libraryLine),
            URLQueryItem(name: "settings", value: settingsLines.joined(separator: "\n")),
        ]
        return components.url!
    }
}

extension Diagnostics {
    /// The running Mac and app.
    static func current(entries: [SessionEntry], groups: Int, macros: Int,
                        inventorySources: [InventorySource],
                        terminal: TerminalSettings, logging: LoggingSettings,
                        agent: AgentController.Settings) -> Diagnostics {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var kinds: [SessionKind: Int] = [:]
        for entry in entries { kinds[entry.kind, default: 0] += 1 }
        // A nested folder counts once, as do its parents ("a/b" is a and a/b).
        var folders = Set<String>()
        for entry in entries where !entry.folder.isEmpty {
            var path = ""
            for part in entry.folder.split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                folders.insert(path)
            }
        }
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return Diagnostics(
            version: info["CFBundleShortVersionString"] as? String ?? "development build",
            build: info["CFBundleVersion"] as? String ?? "?",
            macOS: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            appleSilicon: appleSilicon,
            hostsByKind: kinds,
            folders: folders.count,
            groups: groups,
            macros: macros,
            sharedInventories: inventorySources.count,
            sharedInventoriesOn: inventorySources.filter(\.isEnabled).count,
            directoryTrackingOnConnect: terminal.injectShellIntegration,
            sessionLogging: logging.enabled,
            metalRenderer: terminal.useMetalRenderer,
            agentAccess: agent.enabled,
            agentTyping: agent.allowInput,
            agentEditing: agent.allowEdit,
            dontAskAllowed: agent.dontAskAllowed,
            dontAskOn: agent.dontAsk,
            approvedPrograms: agent.approvals.count)
    }
}
