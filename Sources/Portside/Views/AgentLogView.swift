import AppKit
import SwiftUI

/// Everything agents have asked Portside for, from `portside.agent.log` —
/// across launches, unlike the in-memory activity list. The record of what a
/// program did on your behalf belongs somewhere you can read it without
/// opening Finder and a text editor.
struct AgentLogView: View {
    @EnvironmentObject var agent: AgentController
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var filter = ""
    @State private var problemsOnly = false

    struct Entry: Identifiable, Hashable {
        let id: Int
        var time: Date?
        var client: String
        var method: String
        var params: String
        var outcome: String
        var path: String
    }

    /// The newest entries are what anyone opening this wants; older ones stay
    /// in the file.
    static let shownLimit = 2000

    private var shown: [Entry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { e in
            (!problemsOnly || e.outcome != "ok")
                && (needle.isEmpty || [e.client, e.method, e.params, e.outcome]
                    .contains { $0.lowercased().contains(needle) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent Log").font(.headline)
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
                Toggle("Refusals and errors only", isOn: $problemsOnly).toggleStyle(.checkbox)
            }
            .padding(12)
            Divider()
            if shown.isEmpty {
                Text(entries.isEmpty ? "No agent activity has been logged." : "Nothing matches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(shown) {
                    TableColumn("Time") { e in
                        Text(e.time.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "")
                            .font(.caption.monospacedDigit())
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Program") { e in Text(e.client).help(e.path) }
                        .width(min: 60, ideal: 80)
                    TableColumn("Request") { e in
                        Text(e.params.isEmpty ? e.method : "\(e.method)  \(e.params)")
                            .font(.callout.monospaced())
                            .help(e.params)
                    }
                    TableColumn("Outcome") { e in
                        Label(e.outcome, systemImage: e.outcome == "ok" ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(e.outcome == "ok" ? Color.secondary : Color.orange)
                    }
                    .width(min: 80, ideal: 100)
                }
            }
            Divider()
            HStack {
                Text("\(shown.count) of \(entries.count) entries").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { load() }
                Button("Show in Finder") {
                    if let url = agent.logURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(agent.logURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, minHeight: 440)
        .onAppear(perform: load)
    }

    private func load() {
        guard let url = agent.logURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            entries = []
            return
        }
        let iso = ISO8601DateFormatter()
        let lines = text.split(separator: "\n").suffix(Self.shownLimit)
        entries = lines.enumerated().compactMap { index, line in
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return nil }
            return Entry(id: index, time: o["time"].flatMap(iso.date(from:)), client: o["client"] ?? "",
                         method: o["method"] ?? "", params: o["params"] ?? "", outcome: o["outcome"] ?? "",
                         path: o["path"] ?? "")
        }.reversed()
    }
}
