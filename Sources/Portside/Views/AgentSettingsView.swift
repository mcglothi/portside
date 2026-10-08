import AppKit
import SwiftUI

/// Settings ▸ Agents: turning Agent Access on, the `portside` command, which
/// programs have been approved, and what they've done.
struct AgentSettingsView: View {
    @EnvironmentObject var agent: AgentController
    @State private var installMessage: String?
    @State private var showingLog = false
    @State private var confirmingDontAsk = false
    @State private var confirmingProtected = false
    @State private var scopeDraft: String?

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
                     + "approval the first time. Protected hosts and large selections ask every time. "
                     + "An agent can never arm MultiExec, and can only type into a session if you turn on "
                     + "typing below.")
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

            Section {
                Toggle(isOn: Binding(get: { agent.settings.dontAskAllowed },
                                     set: { on in on ? (confirmingDontAsk = true) : agent.setDontAskAllowed(false) })) {
                    Label("Don\u{2019}t ask \u{2014} let agents act without confirmation", systemImage: "bolt.fill")
                }
                .disabled(!agent.settings.enabled)
                .tint(.orange)
                DontAskWarning()
                if agent.settings.dontAskAllowed {
                    Text(agent.settings.dontAsk
                         ? "On now. Disable or enable it any time from the \u{26A1} in the toolbar."
                         : "Allowed, but off right now \u{2014} enable it from the \u{26A1} in the toolbar.")
                        .font(.caption).foregroundStyle(.secondary)
                    scopeField
                    Toggle("Also for protected hosts", isOn: Binding(
                        get: { agent.settings.dontAskIncludesProtected },
                        set: { on in on ? (confirmingProtected = true) : agent.setDontAskIncludesProtected(false) }))
                    Toggle("Keep on after Portside quits", isOn: Binding(
                        get: { agent.settings.dontAskPersists }, set: { agent.setDontAskPersists($0) }))
                }
            } header: {
                Text("Don\u{2019}t Ask (at your own risk)")
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
        .alert("Let agents act without asking?", isPresented: $confirmingDontAsk) {
            Button("Turn On") { agent.setDontAskAllowed(true) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Any program on this Mac that reaches Portside will be let in without asking, "
                 + "can open as many hosts as it likes, and \u{2014} with typing on \u{2014} can type and run "
                 + "commands in your sessions without you seeing them first. Use it only on a machine and "
                 + "with hosts you'd trust it with. Everything is still logged, and it switches off when "
                 + "Portside quits \u{2014} turn it back on from the \u{26A1} in the toolbar.")
        }
        .alert("Skip confirmation for protected hosts too?", isPresented: $confirmingProtected) {
            Button("Include Protected Hosts", role: .destructive) { agent.setDontAskIncludesProtected(true) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("You marked these hosts protected so that nothing reaches them by accident. With this on, an "
                 + "agent can connect to them and type into them without asking.")
        }
    }

    /// Which hosts Don't Ask covers, in the sidebar filter syntax. Applied on
    /// Return, so the log records the scope chosen rather than every keystroke.
    @ViewBuilder private var scopeField: some View {
        let draft = scopeDraft ?? agent.settings.dontAskScope
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Only for hosts matching")
                TextField("", text: Binding(get: { draft }, set: { scopeDraft = $0 }),
                          prompt: Text("all hosts \u{2014} e.g. env:dev folder:lab"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { agent.setDontAskScope(draft); scopeDraft = nil }
                if scopeDraft != nil && draft != agent.settings.dontAskScope {
                    Button("Apply") { agent.setDontAskScope(draft); scopeDraft = nil }
                }
            }
            Group {
                if let coverage = agent.scopeCoverage(draft) {
                    Text(draft.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Covers every host, and local shells."
                         : "Covers \(coverage.matched) of \(coverage.total) hosts. Anything else, and local "
                           + "shells, still asks.")
                } else {
                    Text("That pattern doesn\u{2019}t parse, so Don\u{2019}t Ask would cover nothing.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
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

/// Toolbar badge shown while Agent Access is on, with the recent activity and
/// the Don't Ask and off switches one click away — the "a human can see it and
/// stop it" half of the design.
///
/// This view observes *nothing* and owns only whether the popover is open. The
/// icon and the popover's contents are their own views that observe the
/// controller. Any re-render of the button a toolbar popover is anchored to —
/// and an `@EnvironmentObject` re-renders on every change, read or not —
/// closed the popover the moment anything happened, including its own Enable.
struct AgentIndicator: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: { AgentIndicatorIcon() }
            .buttonStyle(.borderless)
            .accessibilityLabel("Agent Access")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AgentPopoverContent(close: { showing = false })
            }
    }
}

/// The icon alone: ⚡ while Don't Ask is on, crossed out while it's allowed
/// but off, otherwise a sparkle that lights up for a minute after a request.
/// Draws nothing while Agent Access is off.
private struct AgentIndicatorIcon: View {
    @EnvironmentObject var agent: AgentController

    var body: some View {
        if agent.settings.enabled {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let active = agent.lastActivity.map { context.date.timeIntervalSince($0) < 60 } ?? false
                let allowed = agent.settings.dontAskAllowed
                let yolo = allowed && agent.settings.dontAsk
                Image(systemName: yolo ? "bolt.fill" : allowed ? "bolt.slash" : active ? "sparkles" : "sparkle")
                    .foregroundStyle(yolo ? Color.orange : active ? Color.accentColor : Color.secondary)
                    .help(yolo ? "Don\u{2019}t Ask is on: agents act without confirmation"
                          : allowed ? "Don\u{2019}t Ask is off: agents ask for confirmation"
                          : active ? "An agent used Portside in the last minute" : "Agent Access is on")
            }
        }
    }
}

private struct AgentPopoverContent: View {
    @EnvironmentObject var agent: AgentController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent Access").font(.headline)
            if agent.settings.dontAskAllowed {
                let on = agent.settings.dontAsk
                HStack {
                    Label(on ? "Don\u{2019}t Ask is on" : "Don\u{2019}t Ask is off",
                          systemImage: on ? "bolt.fill" : "bolt.slash")
                        .foregroundStyle(on ? Color.orange : Color.secondary)
                    Spacer()
                    Button(on ? "Disable" : "Enable") { agent.setDontAsk(!on) }
                }
                let scope = agent.settings.dontAskScope
                Text(!on ? "Agents ask for confirmation as usual."
                     : (scope.isEmpty ? "Agents act without asking" : "Agents act without asking on \(scope)")
                       + (agent.settings.dontAskIncludesProtected ? ", protected hosts included."
                                                                  : ", except on protected hosts."))
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
            }
            AgentActivityList(limit: 8)
            Divider()
            HStack {
                Button("View Log\u{2026}") { close(); agent.showingLog = true }
                Spacer()
                Button("Turn Off Agent Access") { agent.setEnabled(false); close() }
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

/// The plain-language warning under the Don't Ask switch. Always visible,
/// not only after turning it on: the time to read it is before.
struct DontAskWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("For trusted machines and lab environments. Portside stops asking: new programs are let in, "
                     + "large selections open, and \u{2014} if typing is on \u{2014} agents type into and read "
                     + "your sessions without a prompt. A program that is wrong, confused, or following "
                     + "instructions it read on a server can do real damage before you notice.")
                Text("Still enforced: nothing is typed at a password prompt, MultiExec is never armed by an agent, "
                     + "typing needs its own switch, protected hosts still ask (unless included below), and every "
                     + "action is logged.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
    }
}
