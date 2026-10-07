import SwiftUI

/// The host filter's syntax, one click from the field. Each example row adds
/// itself to the filter, so the reference doubles as a way to build one.
struct FilterHelpView: View {
    let folders: [String]
    let profiles: [String]
    let add: (String) -> Void

    private struct Row: Identifiable {
        let example: String
        let meaning: String
        var values: String = ""
        var id: String { example }
    }

    private var fieldRows: [Row] {
        func values(_ key: HostQuery.Key, limit: Int = 6) -> String {
            let all = HostQuery.suggestedValues(for: key, folders: folders, profiles: profiles)
            let shown = all.prefix(limit).joined(separator: ", ")
            return all.count > limit ? shown + ", \u{2026}" : shown
        }
        return [
            Row(example: "env:prod", meaning: "Environment", values: values(.env)),
            Row(example: "kind:k8s", meaning: "Connection type", values: values(.kind, limit: 8)),
            Row(example: "folder:lab", meaning: "Folder path contains", values: values(.folder)),
            Row(example: "profile:none", meaning: "Credential profile, or none", values: values(.profile)),
            Row(example: "is:fav", meaning: "Favourite or protected", values: values(.is)),
        ]
    }

    private let modifierRows = [
        Row(example: "-env:prod", meaning: "A leading - excludes whatever the term matches"),
        Row(example: "/^db-\\d+/", meaning: "Slashes make a case-insensitive regular expression"),
        Row(example: "folder:/lab|prod/", meaning: "Regex works on any field, too"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Filtering hosts").font(.headline)
            Text("Separate terms with spaces; a host must match all of them. A plain word matches the name, address or folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            section("Fields", fieldRows)
            section("Modifiers", modifierRows)

            Text("Type a field and colon, like env:, for its values. Save a filter from the magnifying glass.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 400)
    }

    private func section(_ title: String, _ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(rows) { row in
                    GridRow {
                        Button(row.example) { add(row.example) }
                            .buttonStyle(.link)
                            .font(.callout.monospaced())
                            .help("Add \(row.example) to the filter")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.meaning).font(.callout)
                            if !row.values.isEmpty {
                                Text(row.values)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
            }
        }
    }
}
