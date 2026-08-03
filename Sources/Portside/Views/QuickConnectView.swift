import SwiftUI

/// ⌘K command palette: fuzzy-search every host and saved group, and open the
/// selection on Return. Empty query shows recent hosts first, so it doubles as
/// a fast reconnect.
struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var sessions: SessionManager
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool
    @State private var groupNotice: String?

    /// Either kind of thing ⌘K can open. Groups were reachable only from the
    /// sidebar, which is the one place you aren't when you reach for ⌘K.
    enum Item: Identifiable {
        case host(SessionEntry)
        case group(SessionGroup)

        var id: UUID {
            switch self {
            case .host(let e): return e.id
            case .group(let g): return g.id
            }
        }

        var name: String {
            switch self {
            case .host(let e): return e.name
            case .group(let g): return g.name
            }
        }
    }

    private var results: [Item] {
        // Recents are resolved here (they need the store); the ordering rule
        // itself is static so it can be tested without a view.
        let ranked = store.frecentEntries(limit: 8)
        let rankedIDs = Set(ranked.map(\.id))
        let legacy = store.recentEntries(limit: 8).map(\.entry).filter { !rankedIDs.contains($0.id) }
        return Self.ordered(
            query: query,
            entries: store.entries,
            groups: store.groups,
            recents: Array((ranked + legacy).prefix(8))
        )
    }

    /// The palette's result list.
    ///
    /// With a query, hosts and groups compete on the same fuzzy score with no
    /// thumb on the scale — a group named "splunk" and a host named
    /// "splunk-01" sort by how well each matches what was typed.
    ///
    /// Without one, groups sit *below* the recents deliberately: ⌘K then Return
    /// reconnecting to the host you were last on is muscle memory worth more
    /// than putting groups first. They still land above the bulk of the
    /// library, which is where you'd go looking for them.
    static func ordered(
        query: String,
        entries: [SessionEntry],
        groups: [SessionGroup],
        recents: [SessionEntry]
    ) -> [Item] {
        guard !query.isEmpty else {
            // Frecency rather than pure recency: a host hit constantly should
            // outrank one touched once yesterday. Recents top up the list
            // rather than being replaced by it -- an either/or meant one new
            // statistic could displace everything a user had been using.
            let recentIDs = Set(recents.map(\.id))
            let rest = entries
                .filter { !recentIDs.contains($0.id) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let sortedGroups = groups
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return recents.map(Item.host) + sortedGroups.map(Item.group) + rest.map(Item.host)
        }
        var scored: [(item: Item, score: Int)] = []
        for entry in entries {
            if let s = rank(entry, query: query) { scored.append((.host(entry), s)) }
        }
        for group in groups {
            if let s = rank(group, query: query) { scored.append((.group(group), s)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.name.localizedCaseInsensitiveCompare(rhs.item.name) == .orderedAscending
        }
        return scored.map(\.item)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Connect to…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.return) { connectSelected(); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "sailboat")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "Nothing saved yet" : "No matches for “\(query)”")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                QuickConnectRow(item: item, selected: index == selectedIndex)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(item) }
                                    .onHover { if $0 { selectedIndex = index } }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 300)
                    .onChange(of: selectedIndex) { _, new in
                        if results.indices.contains(new) {
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(results[new].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 520)
        .onAppear { fieldFocused = true }
        // Any keystroke changes the result set; keep the highlight in range.
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .alert(
            "Group opened incomplete",
            isPresented: Binding(get: { groupNotice != nil }, set: { if !$0 { groupNotice = nil } })
        ) {
            Button("OK", role: .cancel) { groupNotice = nil; dismiss() }
        } message: {
            Text(groupNotice ?? "")
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
    }

    private func connectSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        open(results[selectedIndex])
    }

    private func open(_ item: Item) {
        switch item {
        case .host(let entry):
            sessions.connect(to: store.resolved(entry))
            dismiss()
        case .group(let group):
            let result = sessions.launch(group) { id in
                store.entry(id: id).map(store.resolved)
            }
            // A group that opened six of eight panes has to say so. The palette
            // stays up to say it — dismissing would take the warning with it.
            if let notice = result.notice(for: group, nameForID: { store.entry(id: $0)?.name }) {
                groupNotice = notice
            } else {
                dismiss()
            }
        }
    }

    // MARK: - Fuzzy ranking

    /// Best subsequence score across the host's name (preferred) and its
    /// user@host / folder metadata. nil means no match.
    static func rank(_ entry: SessionEntry, query: String) -> Int? {
        let name = score(query, in: entry.name).map { $0 + 10 }
        let meta = score(query, in: entry.subtitle + " " + entry.folder)
        switch (name, meta) {
        case let (n?, m?): return max(n, m)
        case let (n?, nil): return n
        case let (nil, m?): return m
        default: return nil
        }
    }

    /// The group equivalent: its name, or the folder it's filed in.
    static func rank(_ group: SessionGroup, query: String) -> Int? {
        let name = score(query, in: group.name).map { $0 + 10 }
        let meta = score(query, in: group.folder)
        switch (name, meta) {
        case let (n?, m?): return max(n, m)
        case let (n?, nil): return n
        case let (nil, m?): return m
        default: return nil
        }
    }

    /// Subsequence match with bonuses for contiguous runs and word starts,
    /// so "gv" ranks "grafana-vm" above an incidental scattered match.
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, streak = 0, total = 0
        for (ti, ch) in t.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                total += 1 + streak
                let boundary = "-/. _".contains
                if ti == 0 || boundary(t[ti - 1]) { total += 3 }
                streak += 1
                qi += 1
            } else {
                streak = 0
            }
        }
        return qi == q.count ? total : nil
    }
}

private struct QuickConnectRow: View {
    let item: QuickConnectView.Item
    let selected: Bool

    var body: some View {
        switch item {
        case .host(let entry): hostRow(entry)
        case .group(let group): groupRow(group)
        }
    }

    private func groupRow(_ group: SessionGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(selected ? Color.white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .foregroundStyle(selected ? Color.white : .primary)
                Text(groupSubtitle(group))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if group.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.white : .yellow)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .padding(.horizontal, 6)
        )
    }

    private func groupSubtitle(_ group: SessionGroup) -> String {
        let panes = "\(group.paneCount) pane\(group.paneCount == 1 ? "" : "s")"
        return group.folder.isEmpty ? panes : "\(panes) · \(group.folder)"
    }

    private func hostRow(_ entry: SessionEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon)
                .foregroundStyle(selected ? Color.white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .foregroundStyle(selected ? Color.white : .primary)
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if entry.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.white : .secondary)
            }
            TransportBadge(entry: entry)
            EnvironmentBadge(environment: entry.environment)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                .padding(.horizontal, 6)
        )
    }

    private func subtitle(_ entry: SessionEntry) -> String {
        entry.folder.isEmpty ? entry.subtitle : "\(entry.subtitle) · \(entry.folder)"
    }
}
