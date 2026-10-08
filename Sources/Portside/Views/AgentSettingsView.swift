import AppKit
import SwiftUI

/// Settings ▸ Agents: turning Agent Access on, the `portside` command, which
/// programs have been approved, and what they've done.
struct AgentSettingsView: View {
    @EnvironmentObject var agent: AgentController
    @State private var installMessage: String?
    @State private var showingLog = false

    /// The CLI inside this app bundle.
    static var bundledCLI: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/portside-cli")
    }

    /// Where "Install" links it: a per-user bin directory that needs no admin
    /// rights and is on PATH for most shells set up for developer tools.
    static var linkLocation: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/portside")
    }

    /// Uses the bundled binary's own path, so it works before (or without)
    /// the ~/.local/bin link and survives the link being removed.
    static var mcpCommand: String { "claude mcp add portside -- \(bundledCLI.path) mcp" }

    var body: some View {
        Form {
            Section {
                Toggle("Allow agents to use Portside", isOn: Binding(
                    get: { agent.settings.enabled }, set: { agent.setEnabled($0) }))
                Text("Lets programs on this Mac — Claude Code, Codex, your own scripts — list your hosts "
                     + "and open sessions through the `portside` command. Each program asks for your "
                     + "approval the first time. Protected hosts and large selections ask every time, "
                     + "and an agent can never arm MultiExec or type into a session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = agent.serverError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Section("Command") {
                HStack {
                    Text("portside").font(.body.monospaced())
                    Spacer()
                    Button("Install in ~/.local/bin") { installCLI() }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.bundledCLI.path, forType: .string)
                    }
                }
                if let installMessage {
                    Text(installMessage).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text("Try `portside hosts env:prod`, or tell an agent: \u{201C}use `portside --help` to log me in "
                     + "to every web host in prod.\u{201D}")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("MCP") {
                HStack {
                    Text(Self.mcpCommand).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.mcpCommand, forType: .string)
                    }
                }
                Text("Run this once to give Claude Code Portside\u{2019}s tools directly. Any MCP client works "
                     + "the same way: the server is `portside mcp` on stdio, and every call goes through the "
                     + "same approvals as the command.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Typing") {
                Toggle("Allow agents to type into sessions", isOn: Binding(
                    get: { agent.settings.allowInput }, set: { agent.setAllowInput($0) }))
                    .disabled(!agent.settings.enabled)
                Text("Lets an approved program type into a session and read its screen. Each pane asks "
                     + "the first time; protected hosts and multi-line input ask every time; nothing is ever "
                     + "typed at a password prompt or broadcast to MultiExec. A pane being typed into shows "
                     + "\u{201C}Agent typing\u{201D}. Turning this off takes typing back from every program.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Confirmation") {
                Stepper(value: Binding(get: { agent.settings.connectCap }, set: { agent.setConnectCap($0) }),
                        in: 1...500) {
                    Text("Ask before an agent opens more than \(agent.settings.connectCap) hosts at once")
                }
                Text("Protected hosts always ask, whatever the count.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Approved Programs") {
                if agent.settings.approvals.isEmpty {
                    Text("None yet. A program is added when you approve it.").foregroundStyle(.secondary)
                }
                ForEach(agent.settings.approvals) { approval in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(approval.name).font(.body.weight(.medium))
                            Text("\(approval.tier.label) \u{00B7} approved "
                                 + RelativeTime.phrase(for: approval.approvedAt))
                                .font(.caption).foregroundStyle(.secondary)
                            if !approval.path.isEmpty {
                                Text(approval.path).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button("Revoke") { agent.revoke(approval) }
                    }
                }
            }

            Section {
                AgentActivityList(limit: 12)
                HStack {
                    Button("View Log\u{2026}") { showingLog = true }
                    Spacer()
                    Button("Show Log in Finder") {
                        if let url = agent.logURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    .disabled(agent.logURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
                }
            } header: {
                Text("Recent Activity")
            }
        }
        .formStyle(.grouped)
        .settingsPageSizing()
        // Settings is its own window, so it presents its own copy of the sheet.
        .sheet(isPresented: $showingLog) { AgentLogView().environmentObject(agent) }
    }

    private func installCLI() {
        let fm = FileManager.default
        let link = Self.linkLocation
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Replace only a link — never a real file someone put there.
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                _ = existing
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                installMessage = "\(link.path) already exists and isn't a link, so it was left alone."
                return
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: Self.bundledCLI)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").contains { $0 == link.deletingLastPathComponent().path }
            installMessage = "Linked \(link.path) \u{2192} Portside." + (onPath ? "" :
                " If `portside` isn't found, add ~/.local/bin to your PATH.")
        } catch {
            installMessage = "Couldn't link it: \(error.localizedDescription)"
        }
    }
}

struct AgentActivityList: View {
    @EnvironmentObject var agent: AgentController
    var limit: Int

    var body: some View {
        if agent.activity.isEmpty {
            Text("Nothing yet.").foregroundStyle(.secondary)
        }
        ForEach(agent.activity.prefix(limit)) { item in
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: item.outcome == "ok" ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(item.outcome == "ok" ? Color.secondary : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(item.client)  \(item.method) \(item.detail)").font(.callout.monospaced())
                        .lineLimit(1).truncationMode(.tail)
                    Text(RelativeTime.phrase(for: item.date) + (item.outcome == "ok" ? "" : " \u{00B7} \(item.outcome)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Toolbar badge shown while Agent Access is on: lit for a minute after any
/// request, with the recent activity and an off switch one click away —
/// the "a human can see it and stop it" half of the design.
struct AgentIndicator: View {
    @EnvironmentObject var agent: AgentController
    @State private var showing = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let active = agent.lastActivity.map { context.date.timeIntervalSince($0) < 60 } ?? false
            Button { showing.toggle() } label: {
                Label("Agent Access", systemImage: active ? "sparkles" : "sparkle")
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
            }
            .help(active ? "An agent used Portside in the last minute" : "Agent Access is on")
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Agent Access").font(.headline)
                AgentActivityList(limit: 8)
                Divider()
                HStack {
                    Button("View Log\u{2026}") { showing = false; agent.showingLog = true }
                    Spacer()
                    Button("Turn Off Agent Access") { agent.setEnabled(false); showing = false }
                }
            }
            .padding(14)
            .frame(width: 360)
        }
    }
}
