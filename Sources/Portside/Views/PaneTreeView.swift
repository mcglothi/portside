import UniformTypeIdentifiers
import SwiftUI

/// Renders a tab's pane tree: leaves are terminals, interior nodes are
/// horizontal/vertical splits. Today every tab is a single leaf; this view is
/// already recursive so splitting (0.9) needs no new rendering code.
struct PaneTreeView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let zoomed = tab.zoomedPaneID, let session = tab.leaves.first(where: { $0.id == zoomed }) {
            PaneLeafView(session: session, tab: tab)
                .id(session.id)
                .overlay(alignment: .topTrailing) {
                    Label("Zoomed", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.quaternary))
                        .padding(6)
                        .help("This pane is maximized — ⌘⇧↵ to restore the split")
                }
        } else if let root = tab.root {
            PaneNodeView(node: root, tab: tab)
        }
    }
}

struct PaneNodeView: View {
    let node: PaneNode<TerminalSession>
    @ObservedObject var tab: Tab

    var body: some View {
        switch node {
        case .leaf(let session):
            // Identity tied to the session so switching tabs (a single leaf,
            // not in a ForEach) recreates the terminal's NSViewRepresentable and
            // swaps to the new session's view — otherwise the cached NSView from
            // makeNSView keeps showing the previous session.
            PaneLeafView(session: session, tab: tab)
                .id(session.id)
        case .split(_, let orientation, let children):
            container(orientation, children)
        }
    }

    @ViewBuilder
    private func container(_ orientation: PaneOrientation, _ children: [PaneNode<TerminalSession>]) -> some View {
        // AnyView at the recursion point breaks the otherwise-infinite view type.
        if orientation == .horizontal {
            HSplitView {
                ForEach(children) { child in
                    AnyView(PaneNodeView(node: child, tab: tab))
                }
            }
        } else {
            VSplitView {
                ForEach(children) { child in
                    AnyView(PaneNodeView(node: child, tab: tab))
                }
            }
        }
    }
}

/// A single terminal leaf, plus the focus ring and — when its tab is armed for
/// MultiExec — a per-pane include toggle, protected-host guard, and the
/// included/excluded styling that used to live on the MultiExec grid tiles.
struct PaneLeafView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var sessions: SessionManager
    @ObservedObject var session: TerminalSession
    @ObservedObject var tab: Tab
    @State private var hovering = false
    @State private var isDropTarget = false
    @State private var hoveringGrip = false
    @State private var hoveringPane = false

    private var armed: Bool { tab.broadcastArmed }
    private var included: Bool { session.includedInMultiExec }
    private var isActive: Bool { tab.leaves.count > 1 && session.id == tab.activePaneID }
    private var alert: Color { Color(nsColor: store.appearance.alert) }

    /// The handle you drag to rearrange panes.
    ///
    /// A grip rather than the pane itself: the terminal is an AppKit view that
    /// owns the mouse, so dragging anywhere inside it selects text — which is
    /// what it should do.
    ///
    /// Revealed on hover, and only when there's another pane to swap with. A
    /// permanent badge sits on top of the terminal's first line for the whole
    /// life of the tab — the same mistake the MultiExec chip made before it
    /// became a real bar, and the reason that bar exists.
    ///
    /// Top *trailing*, for the same reason: a shell prompt and its output start
    /// at the left, so the leading corner is exactly where the first line is.
    /// The right edge is only reached by wrapped lines, and then only while
    /// you're pointing at that pane.
    @ViewBuilder private var rearrangeGrip: some View {
        if hoveringPane, tab.leaves.count > 1 {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(5)
                .background(Color.black.opacity(hoveringGrip ? 0.75 : 0.35),
                            in: RoundedRectangle(cornerRadius: 5))
                .opacity(hoveringGrip ? 1 : 0.6)
                .padding(6)
                .help("Drag onto another pane to swap the two")
                .onHover { hoveringGrip = $0 }
                .onDrag { NSItemProvider(object: session.id.uuidString as NSString) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalPane(session: session)
                .opacity(armed && !included ? 0.55 : 1)
            // A real bar rather than a floating chip: the old overlay sat on
            // top of the terminal's first line, hiding output on every pane
            // for the whole time MultiExec was armed.
            if armed {
                Divider()
                includeBar
            }
        }
            .overlay {
                let ring = ringColor
                if ring != nil {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(ring!, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) { rearrangeGrip }
            .onHover { hoveringPane = $0 }
            .overlay {
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            // The drop lands on the pane body rather than on an overlay: an
            // overlay big enough to catch a drop would also swallow the clicks
            // meant for the terminal underneath it.
            .onDrop(of: [.text], isTargeted: $isDropTarget) { providers in
                loadTabID(from: providers) { sessions.swapPanes($0, session.id) }
            }
            // Host-to-host copy: a file dragged from the SFTP pane lands in
            // whatever directory *this* pane's shell is sitting in.
            //
            // The drop itself is caught in AppKit by `LoggingTerminalView`
            // (see `enableRemoteFileDrops` for why neither SwiftUI drop API
            // can see this drag); it lands here for the store lookup and any
            // error presentation.
            .onChange(of: session.pendingRemoteDrop) { _, payload in
                guard let payload else { return }
                session.pendingRemoteDrop = nil
                acceptRelayDrop(payload)
            }
            .onChange(of: session.pendingLocalDrop) { _, urls in
                guard let urls, !urls.isEmpty else { return }
                session.pendingLocalDrop = nil
                acceptLocalDrop(urls)
            }
            .overlay {
                if showsDropHighlight {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .background(Color.accentColor.opacity(0.08))
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.12), value: showsDropHighlight)
                }
            }
            // A pane flashes when the copy actually lands on it, so a fan-out
            // is visible as several panes lighting up in turn. The drag icon
            // can only ever drop on one of them.
            .overlay {
                if session.relayLanded {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.green, lineWidth: 3)
                        .background(Color.green.opacity(0.10))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: session.relayLanded)
            .alert(
                "Could not copy here",
                isPresented: Binding(
                    get: { session.relayError != nil },
                    set: { if !$0 { session.relayError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { session.relayError = nil }
            } message: {
                Text(session.relayError ?? "")
            }
            .confirmationDialog(
                "\"\(session.title)\" is a protected host. Include it in the MultiExec broadcast?",
                isPresented: confirmingInclude
            ) {
                Button("Include Protected Host", role: .destructive) {
                    sessions.confirmProtectedInclusion()
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    /// Takes a remote file dropped on this pane and starts the relay.
    ///
    /// The source entry is resolved from the store at drop time rather than
    /// trusted from the pasteboard, so a drag that started before a host was
    /// edited or deleted cannot act on stale connection details.
    private func acceptRelayDrop(_ payload: RemoteFileDragPayload) {
        guard let sourceEntry = store.entry(id: payload.entryID) else {
            session.relayError = "That host is no longer in your session library."
            return
        }
        guard let destinationEntry = session.entry else {
            session.relayError = "This pane has no host to copy to — "
                + "host-to-host copy needs a plain SSH session."
            return
        }

        // Dropping onto a pane that is currently broadcasting sends the file
        // to the whole group, matching what typing into that pane would do.
        // Dropping onto an *excluded* pane while armed copies only there —
        // exclusion means "keystrokes don't reach this box", and a file is no
        // different.
        if let group = broadcastTargets(), group.count > 1 {
            RemoteRelayCoordinator.startFanOut(
                payload: payload, sourceEntry: sourceEntry,
                droppedOn: session, targets: group,
                concurrency: store.defaults.resolvedTransferConcurrency
            )
            return
        }

        RemoteRelayCoordinator.start(
            payload: payload,
            sourceEntry: sourceEntry,
            destinationSession: session,
            destinationEntry: destinationEntry
        )
    }

    /// Takes local files dropped on this pane — from Finder or anywhere else
    /// — and uploads them where a remote file dropped here would go: the
    /// whole broadcast group when this pane is broadcasting, otherwise just
    /// this host.
    private func acceptLocalDrop(_ urls: [URL]) {
        guard let destinationEntry = session.entry, destinationEntry.supportsFileBrowser else {
            session.relayError = "This pane has no host to upload to — "
                + "file upload needs a plain SSH session."
            return
        }
        let group = broadcastTargets()
            ?? [RemoteRelayCoordinator.Target(session: session, entry: destinationEntry)]
        RemoteRelayCoordinator.startLocalFanOut(
            urls: urls, droppedOn: session, targets: group,
            concurrency: store.defaults.resolvedTransferConcurrency
        )
    }

    /// Highlights this pane while a droppable file hovers anywhere in the
    /// group it would be copied to — not just over this pane.
    ///
    /// The drag icon can only sit over one pane, so without this a fan-out
    /// looks identical to a single-host copy right up until the file appears
    /// on hosts you did not visibly aim at. Lighting the whole group during
    /// the hover answers "where is this going?" before the drop rather than
    /// after it.
    private var showsDropHighlight: Bool {
        if session.dropTargeted { return true }
        guard tab.broadcastArmed, session.includedInMultiExec else { return false }
        return tab.leaves.contains { $0.dropTargeted && $0.includedInMultiExec }
    }

    /// Every pane the file should reach, or nil when this is an ordinary
    /// single-pane drop.
    ///
    /// Panes with no file browser (containers, local shells, mosh) are left
    /// out rather than reported: a mixed group is an ordinary way to work,
    /// and a broadcast that half-fails by design should not raise an error
    /// about it every time.
    private func broadcastTargets() -> [RemoteRelayCoordinator.Target]? {
        guard tab.broadcastArmed, session.includedInMultiExec else { return nil }
        let targets = tab.leaves.compactMap { leaf -> RemoteRelayCoordinator.Target? in
            guard leaf.includedInMultiExec,
                  let entry = leaf.entry, entry.supportsFileBrowser
            else { return nil }
            return .init(session: leaf, entry: entry)
        }
        return targets.isEmpty ? nil : targets
    }

    /// Presented over the pane the manager raised the guard for — so ⌥⌘M on a
    /// protected host gets the same dialog, anchored the same way, as its chip.
    private var confirmingInclude: Binding<Bool> {
        Binding(
            get: { sessions.pendingProtectedInclusionID == session.id },
            set: { shown in
                if !shown, sessions.pendingProtectedInclusionID == session.id {
                    sessions.pendingProtectedInclusionID = nil
                }
            }
        )
    }

    /// Accent ring on the active pane; otherwise the alert-colored ring on an
    /// included pane while armed. Nil (no ring) for a lone or excluded pane.
    private var ringColor: Color? {
        if isActive { return .accentColor }
        if armed && included { return alert.opacity(0.8) }
        return nil
    }

    /// The per-pane include toggle, as a status bar under its terminal.
    ///
    /// No host title: the pane's own prompt already says which box this is, and
    /// repeating it crowded out the one thing the bar exists to report. The
    /// whole strip is the click target, which is a far bigger one than the
    /// floating chip it replaced.
    private var includeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: included ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(included ? alert : .secondary)
            if session.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(included ? "Broadcasting" : "Excluded")
                .font(.caption.weight(.semibold))
                .foregroundStyle(included ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? alert.opacity(0.22) : Color.secondary.opacity(0.10))
        .contentShape(Rectangle())
        .onTapGesture { sessions.toggleIncludedInMultiExec(session) }
        .onHover { hovering = $0 }
        .overlay(ArrowCursorArea().allowsHitTesting(false))
        .help("\(included ? "Exclude" : "Include") this pane — \(toggleShortcut) toggles the focused pane")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(session.title), \(included ? "included in" : "excluded from") MultiExec")
    }

    private var toggleShortcut: String {
        store.keyBindings.binding(for: .togglePaneInMultiExec).displaySymbol
    }
}

/// Restores the arrow cursor over a control layered on top of a terminal.
///
/// SwiftTerm claims its whole bounds with `addCursorRect(bounds, cursor: .iBeam)`,
/// and a SwiftUI-drawn overlay is painted into the hosting view rather than
/// getting an `NSView` of its own — so there is nothing to out-rank that claim
/// and the I-beam stays put over the chip. A real (non-hit-testing) view with
/// its own cursor rect, added above the terminal, is what wins.
private struct ArrowCursorArea: NSViewRepresentable {
    final class CursorView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
        /// Geometry-based, so the cursor rect still applies; clicks continue
        /// through to the SwiftUI tap gesture underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) { view.window?.invalidateCursorRects(for: view) }
}
