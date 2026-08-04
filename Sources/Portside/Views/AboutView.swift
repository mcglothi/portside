import SwiftUI

/// About Portside — the version, and what changed in it and before it.
///
/// Replaces the stock About panel rather than sitting beside it. The stock one
/// answers "which version am I running", which is half the question; the other
/// half is "and what's in it", and until now that was only answerable from a
/// GitHub release page or from the update dialog you already dismissed.
struct AboutView: View {
    private let notes = ReleaseNotes.all

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if notes.isEmpty {
                // Only reachable if the bundled changelog went missing, which a
                // test is meant to prevent. Say so plainly rather than showing
                // an empty box that looks like "no changes".
                VStack(spacing: 6) {
                    Image(systemName: "doc.questionmark")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                    Text("Release notes aren't available in this build.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                notesList
            }
        }
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "sailboat")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Portside")
                    .font(.title2.weight(.semibold))
                Text(ReleaseNotes.versionDescription)
                    .foregroundStyle(.secondary)
                Text("A native macOS SSH workbench.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var notesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(note.version)
                                .font(.headline)
                            if let current = ReleaseNotes.appVersion, note.version == current {
                                Text("this version")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tint.opacity(0.2), in: Capsule())
                            }
                        }
                        // Rendered as markdown so the **lead-ins** each entry
                        // opens with stay bold, which is what makes a long
                        // changelog skimmable.
                        Text(markdown(note.body))
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    /// Falls back to the raw text if the markdown won't parse — a changelog you
    /// can read unstyled beats an empty view.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
