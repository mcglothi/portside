import SwiftUI

struct SessionArea: View {
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        Group {
            if sessions.sessions.isEmpty {
                EmptyStateView()
            } else if sessions.multiExecActive {
                MultiExecView()
            } else {
                VStack(spacing: 0) {
                    TabBar()
                    Divider()
                    if let tab = sessions.selectedTab {
                        HSplitView {
                            PaneTreeView(tab: tab)
                                .frame(minWidth: 400)
                                .layoutPriority(1)
                            if sessions.filesPaneVisible, let sftp = sessions.selected?.sftp {
                                SFTPPaneView(model: sftp)
                                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 560)
                            }
                        }
                    }
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
                .disabled(sessions.multiExecActive
                    || !(sessions.selected?.entry?.supportsFileBrowser ?? false))
                .help("Show the remote file browser for this session")
            }
            ToolbarItem {
                Toggle(isOn: $sessions.multiExecActive) {
                    Label("MultiExec", systemImage: "square.grid.2x2")
                }
                .toggleStyle(.button)
                .disabled(sessions.sessions.isEmpty)
                .help("Show all sessions and broadcast keystrokes to every included one")
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
                        Text("Session ended — press ⏎ or click to close")
                            .font(.callout)
                        Button("Close") { sessions.close(session) }
                            .keyboardShortcut(.defaultAction)
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

struct MultiExecView: View {
    @EnvironmentObject var sessions: SessionManager
    @EnvironmentObject var store: SessionStore
    @State private var commandInput = ""

    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text("MultiExec is ON — keystrokes typed in any included terminal go to all of them")
                    .fontWeight(.semibold)
                Spacer()
                Button("Exit MultiExec") { sessions.multiExecActive = false }
            }
            .padding(8)
            .background(Color.orange.opacity(0.25))

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(sessions.sessions) { session in
                        MultiExecTile(session: session)
                    }
                }
                .padding(8)
            }

            Divider()

            if !store.macros.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Macros:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                Image(systemName: "chevron.right")
                    .foregroundStyle(.orange)
                TextField("Run a command in all included sessions…", text: $commandInput)
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

struct MultiExecTile: View {
    @ObservedObject var session: TerminalSession
    @State private var confirmingInclude = false

    /// Protected hosts require explicit confirmation before joining the broadcast.
    private var includeBinding: Binding<Bool> {
        Binding(
            get: { session.includedInMultiExec },
            set: { newValue in
                if newValue, session.isProtected {
                    confirmingInclude = true
                } else {
                    session.includedInMultiExec = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(isOn: includeBinding) {
                    Text(session.title)
                        .lineLimit(1)
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                .help("Include this terminal in MultiExec broadcast")
                if session.isProtected {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Protected host")
                }
                EnvironmentBadge(environment: session.environment)
                Spacer()
                Circle()
                    .fill(session.isRunning ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
            }
            .padding(6)
            .background(session.includedInMultiExec ? Color.orange.opacity(0.15) : Color.clear)

            TerminalHostingView(session: session, autoFocus: false)
                .id(session.id)
        }
        .confirmationDialog(
            "\"\(session.title)\" is a protected host. Include it in the MultiExec broadcast?",
            isPresented: $confirmingInclude
        ) {
            Button("Include Protected Host", role: .destructive) {
                session.includedInMultiExec = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .frame(height: 320)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    session.includedInMultiExec ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.3),
                    lineWidth: session.includedInMultiExec ? 2 : 1
                )
        )
        .opacity(session.includedInMultiExec ? 1 : 0.55)
    }
}

struct TabBar: View {
    @EnvironmentObject var sessions: SessionManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sessions.tabs) { tab in
                    if let leaf = tab.activeLeaf {
                        TabChip(
                            session: leaf,
                            isSelected: tab.id == sessions.selectedTabID,
                            onSelect: { sessions.selectedTabID = tab.id },
                            onClose: { sessions.closeTab(tab) }
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct TabChip: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let envColor = session.environment.color {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(envColor)
                    .frame(width: 3, height: 14)
            }
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(session.title)
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
