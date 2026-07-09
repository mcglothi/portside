import AppKit
import SwiftUI

/// Global search across all session logs — find a command you ran and see the
/// surrounding context, even in compressed archives.
struct LogSearchView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [LogMatch] = []
    @State private var isSearching = false
    @State private var searched = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search session logs…", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit(runSearch)
                if isSearching { ProgressView().controlSize(.small) }
                Button("Search", action: runSearch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()

            if results.isEmpty {
                ContentUnavailableView(
                    searched && !isSearching ? "No matches" : "Search your logs",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(searched && !isSearching
                        ? "Nothing matched “\(query)”."
                        : "Find a command or output across every session log, including compressed archives."))
                    .frame(maxHeight: .infinity)
            } else {
                List(results) { match in
                    resultRow(match)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private func resultRow(_ match: LogMatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.caption2).foregroundStyle(.secondary)
                Text(match.host).fontWeight(.semibold)
                Text(match.timestamp).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([match.fileURL])
                } label: {
                    Label("Reveal", systemImage: "folder").font(.caption)
                }
                .buttonStyle(.borderless)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(match.context.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.localizedCaseInsensitiveContains(query) ? Color.primary : Color.secondary)
                        .fontWeight(line.localizedCaseInsensitiveContains(query) ? .bold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.vertical, 3)
    }

    private func runSearch() {
        guard !query.isEmpty else { return }
        isSearching = true
        searched = true
        let q = query
        let settings = store.logging
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LogManager.search(q, settings: settings)
            DispatchQueue.main.async {
                results = found
                isSearching = false
            }
        }
    }
}
