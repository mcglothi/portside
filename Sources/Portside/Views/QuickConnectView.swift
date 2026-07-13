import SwiftUI

/// ⌘K command palette: fuzzy-search every host and connect on Return.
/// Empty query shows recent hosts first, so it doubles as a fast reconnect.
struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var sessions: SessionManager
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private var results: [SessionEntry] {
        let all = store.entries
        guard !query.isEmpty else {
            let recent = store.recentEntries(limit: 8).map(\.entry)
            let recentIDs = Set(recent.map(\.id))
            let rest = all
                .filter { !recentIDs.contains($0.id) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return recent + rest
        }
        var scored: [(entry: SessionEntry, score: Int)] = []
        for entry in all {
            if let s = Self.rank(entry, query: query) {
                scored.append((entry, s))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.entry.name.localizedCaseInsensitiveCompare(rhs.entry.name) == .orderedAscending
        }
        return scored.map(\.entry)
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
                    Text(query.isEmpty ? "No hosts yet" : "No matches for “\(query)”")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                QuickConnectRow(entry: entry, selected: index == selectedIndex)
                                    .id(entry.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { connect(entry) }
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
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
    }

    private func connectSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        connect(results[selectedIndex])
    }

    private func connect(_ entry: SessionEntry) {
        sessions.connect(to: store.resolved(entry))
        dismiss()
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
    let entry: SessionEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.icon)
                .foregroundStyle(selected ? Color.white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .foregroundStyle(selected ? Color.white : .primary)
                Text(subtitle)
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

    private var subtitle: String {
        entry.folder.isEmpty ? entry.subtitle : "\(entry.subtitle) · \(entry.folder)"
    }
}
