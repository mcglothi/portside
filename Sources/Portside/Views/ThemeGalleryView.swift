import SwiftUI

/// KDE-Store-style browser for the iTerm2-Color-Schemes collection: search
/// the catalog, preview a scheme live, and install it into the theme picker.
struct ThemeGalleryView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var gallery = ThemeGallery()

    @State private var searchText = ""
    @State private var selectedName: String?
    @State private var previewTheme: TerminalTheme?
    @State private var previewError: String?

    private var filteredNames: [String] {
        guard !searchText.isEmpty else { return gallery.names }
        return gallery.names.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var isBuiltIn: Bool {
        selectedName.map { name in TerminalTheme.builtIns.contains { $0.name == name } } ?? false
    }

    private var isInstalled: Bool {
        selectedName.map { name in store.customThemes.contains { $0.name == name } } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Theme Gallery")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            HSplitView {
                catalog
                    .frame(minWidth: 220, idealWidth: 240)
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 440, idealHeight: 500)
        .task { await gallery.loadIndex() }
        .task(id: selectedName) {
            previewTheme = nil
            previewError = nil
            guard let name = selectedName else { return }
            do {
                previewTheme = try await gallery.theme(named: name)
            } catch is CancellationError {
            } catch {
                previewError = error.localizedDescription
            }
        }
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(gallery.names.count) themes", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)

            Divider()

            if gallery.isLoadingIndex {
                Spacer()
                ProgressView("Loading catalog…")
                Spacer()
            } else if let error = gallery.indexError {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").font(.title2)
                    Text(error).font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
                Spacer()
            } else {
                List(filteredNames, id: \.self, selection: $selectedName) { name in
                    Text(name)
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let theme = previewTheme {
            VStack(alignment: .leading, spacing: 12) {
                Text(theme.name).font(.title3.bold())
                preview(for: theme)
                swatches(for: theme)
                Spacer()
                HStack {
                    if isBuiltIn {
                        Label("Built in", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                    } else if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install & Apply") { install(theme, apply: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBuiltIn)
                    Button("Install") { install(theme, apply: false) }
                        .disabled(isBuiltIn || isInstalled)
                }
            }
            .padding(16)
        } else if let error = previewError {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(error).font(.caption)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if selectedName != nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a theme to preview it")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func preview(for theme: TerminalTheme) -> some View {
        TerminalPreviewView(theme: theme, fontName: store.appearance.fontName, fontSize: 12)
    }

    private func swatches(for theme: TerminalTheme) -> some View {
        VStack(spacing: 3) {
            ForEach([0..<8, 8..<16], id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: HexColor.nsColor(theme.ansi[i])))
                            .frame(height: 18)
                    }
                }
            }
        }
    }

    private func install(_ theme: TerminalTheme, apply: Bool) {
        let stored = store.addCustomTheme(theme)
        if apply {
            store.updateAppearance(store.appearance.applying(stored))
        }
    }
}
