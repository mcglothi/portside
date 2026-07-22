import SwiftUI

struct SessionArea: View {
    @EnvironmentObject var sessions: SessionManager

    private var armed: Bool { sessions.selectedTab?.broadcastArmed ?? false }

    var body: some View {
        Group {
            if sessions.sessions.isEmpty {
                EmptyStateView()
            } else if let tab = sessions.selectedTab {
                VStack(spacing: 0) {
                    TabBar()
                    Divider()
                    TabContentView(tab: tab)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $sessions.filesPaneVisible) {
                    Label("Files", systemImage: "folder")
                }
                .toggleStyle(.button)
                .disabled(armed || !(sessions.selected?.entry?.supportsFileBrowser ?? false))
                .help("Show the remote file browser for this session")
            }
            ToolbarItem {
                Toggle(isOn: Binding(
                    get: { sessions.isGridView },
                    set: { sessions.setGridView($0) }
                )) {
                    Label("Grid View", systemImage: "square.grid.2x2")
                }
                .toggleStyle(.button)
                .disabled(!sessions.canGridView)
                .help("Tile every open session into one grid to watch them at once")
            }
            ToolbarItem {
                Toggle(isOn: Binding(
                    get: { armed },
                    set: { sessions.setBroadcastArmed($0) }
                )) {
                    Label("MultiExec", systemImage: "dot.radiowaves.left.and.right")
                }
                .toggleStyle(.button)
                .disabled((sessions.selectedTab?.leaves.count ?? 0) < 2)
                .help("Broadcast keystrokes to every included pane in this tab (Grid View first to gather separate tabs)")
            }
        }
    }
}

/// A tab's content: the pane tree, wrapped with the broadcast banner and the
/// macro/command bars when the tab is armed for MultiExec.
struct TabContentView: View {
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var store: SessionStore
    @ObservedObject var tab: Tab
    @State private var commandInput = ""

    private var alert: Color { Color(nsColor: store.appearance.alert) }

    var body: some View {
        VStack(spacing: 0) {
            if tab.broadcastArmed {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("MultiExec is ON — keystrokes go to every included pane in this tab")
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Disarm") { sessions.setBroadcastArmed(false) }
                }
                .padding(8)
                .background(alert.opacity(0.25))
                Divider()
            }

            HSplitView {
                PaneTreeView(tab: tab)
                    .frame(minWidth: 400)
                    .layoutPriority(1)
                if sessions.filesPaneVisible, let sftp = sessions.selected?.sftp {
                    SFTPPaneView(model: sftp)
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: 560)
                }
            }

            if tab.broadcastArmed {
                Divider()
                if !store.macros.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Text("Macros:").font(.caption).foregroundStyle(.secondary)
                            ForEach(store.macros) { macro in
                                Button(macro.name) { sessions.run(macro) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .help(macro.text)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .background(.bar)
                    Divider()
                }
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").foregroundStyle(alert)
                    TextField("Run a command in all included panes…", text: $commandInput)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            sessions.broadcast(commandInput)
                            commandInput = ""
                        }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }
}

/// A single terminal plus a "session ended" bar once its process exits.
struct TerminalPane: View {
    @EnvironmentObject var sessions: SessionManager
    @ObservedObject var session: TerminalSession

    var body: some View {
        TerminalHostingView(session: session)
            .overlay(alignment: .topTrailing) {
                if session.findVisible {
                    FindBar(session: session)
                        .padding(8)
                }
            }
            .overlay(alignment: .bottom) {
                if !session.isRunning {
                    HStack(spacing: 10) {
                        Image(systemName: "power")
                            .foregroundStyle(.secondary)
                        Text("Session ended")
                            .font(.callout)
                        Button("Reconnect") { sessions.reconnect(session) }
                        Button("Close") { sessions.close(session) }
                            .keyboardShortcut(.defaultAction)
                            .help("Press ⏎ or ⌃D to close")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.quaternary))
                    .padding(.bottom, 18)
                }
            }
    }
}

/// iTerm-style find bar for scrollback search, driving SwiftTerm's search.
struct FindBar: View {
    @ObservedObject var session: TerminalSession
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Find", text: $session.findTerm)
                .textFieldStyle(.plain)
                .frame(width: 160)
                .focused($focused)
                .onSubmit { session.findNext() }
                .onChange(of: session.findTerm) { _, _ in session.findNext() }
                .onKeyPress(.escape) { session.hideFind(); return .handled }

            Button {
                session.findCaseSensitive.toggle()
                session.findNext()
            } label: {
                Text("Aa")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(session.findCaseSensitive ? Color.accentColor : .secondary)
            .help("Match case")

            Button { session.findPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Previous match")

            Button { session.findNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Next match (return)")

            Button { session.hideFind() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (esc)")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .shadow(radius: 6, y: 2)
        .onAppear { focused = true }
    }
}

struct TabBar: View {
    @EnvironmentObject var sessions: SessionManager
    /// The tab being renamed (drives the rename alert), plus its draft name.
    @State private var renamingTab: Tab?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions.tabs) { tab in
                    TabChip(
                        tab: tab,
                        isSelected: tab.id == sessions.selectedTabID,
                        onSelect: { sessions.selectedTabID = tab.id },
                        onClose: { sessions.closeTab(tab) },
                        onRename: { renameText = tab.customTitle ?? tab.activeLeaf?.title ?? ""; renamingTab = tab },
                        onCloseOthers: { sessions.closeOtherTabs(tab) }
                    )
                }
                Button {
                    sessions.openLocalShell()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New local shell (⌘T)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .alert("Rename Tab", isPresented: Binding(
            get: { renamingTab != nil },
            set: { if !$0 { renamingTab = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let tab = renamingTab { sessions.renameTab(tab, to: renameText) }
                renamingTab = nil
            }
            Button("Cancel", role: .cancel) { renamingTab = nil }
        } message: {
            Text("Leave blank to restore the automatic name.")
        }
    }
}

struct TabChip: View {
    @ObservedObject var tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onCloseOthers: () -> Void

    private var title: String { tab.customTitle ?? tab.activeLeaf?.title ?? "shell" }
    private var running: Bool { tab.activeLeaf?.isRunning ?? false }
    private var hasActivity: Bool { !isSelected && tab.leaves.contains { $0.hasActivity } }

    var body: some View {
        HStack(spacing: 6) {
            if let envColor = tab.activeLeaf?.environment.color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(envColor)
                    .frame(width: 3, height: 14)
            }
            // Blue "new activity" is kept distinct from the green running / gray
            // stopped states (and from a green system accent).
            Circle()
                .fill(hasActivity ? Color.blue : (running ? Color.green : Color.secondary))
                .frame(width: 6, height: 6)
                .help(hasActivity ? "New activity" : (running ? "Running" : "Ended"))
            Text(title)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Close", action: onClose)
            Button("Close Others", action: onCloseOthers)
                .disabled(tab.leaves.isEmpty)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var store: SessionStore

    private var recents: [(entry: SessionEntry, date: Date)] {
        store.recentEntries(limit: 8)
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sailboat")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Welcome aboard")
                .font(.title2.weight(.semibold))
            Text("Pick a host from the sidebar, or open a local shell.")
                .foregroundStyle(.secondary)
            Button("New Local Shell") { sessions.openLocalShell() }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Jump back in")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.leading, 10)
                    ForEach(recents, id: \.entry.id) { recent in
                        RecentConnectionRow(entry: recent.entry, date: recent.date) {
                            sessions.connect(to: store.resolved(recent.entry))
                        }
                    }
                }
                .frame(maxWidth: 400)
                .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One recent host on the welcome screen; click reconnects.
struct RecentConnectionRow: View {
    let entry: SessionEntry
    let date: Date
    let connect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 8) {
                Image(systemName: entry.icon)
                    .foregroundStyle(.secondary)
                Text(entry.name)
                    .lineLimit(1)
                Text(entry.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                EnvironmentBadge(environment: entry.environment)
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Reconnect to \(entry.name)")
    }
}
