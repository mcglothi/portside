import SwiftUI

/// Browser for the Nerd Fonts collection: search the release assets, install
/// a family into ~/Library/Fonts, and optionally switch the terminal to it.
struct FontGalleryView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var gallery = FontGallery()

    @State private var searchText = ""
    @State private var selectedName: String?
    @State private var installError: String?

    private var filteredAssets: [FontGallery.FontAsset] {
        guard !searchText.isEmpty else { return gallery.assets }
        return gallery.assets.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedAsset: FontGallery.FontAsset? {
        gallery.assets.first { $0.name == selectedName }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Font Gallery")
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
        .alert("Install Font", isPresented: Binding(
            get: { installError != nil }, set: { if !$0 { installError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(installError ?? "")
        }
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search \(gallery.assets.count) fonts", text: $searchText)
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
                List(filteredAssets, selection: $selectedName) { asset in
                    HStack {
                        Text(asset.name)
                        Spacer()
                        if gallery.installedStems.contains(asset.name) {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let asset = selectedAsset {
            let isInstalled = gallery.installedStems.contains(asset.name)
            let isInstalling = gallery.installing.contains(asset.name)
            VStack(alignment: .leading, spacing: 12) {
                Text(asset.name).font(.title3.bold())
                Text("Nerd Fonts patched family · \(asset.sizeLabel) download")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if isInstalled, let family = FontGallery.installedFamilyName(for: asset) {
                    fontSample(family: family)
                } else {
                    Text("Monospace font patched with powerline symbols, icons, "
                         + "and glyphs. Installs into your user font library "
                         + "(~/Library/Fonts).")
                        .font(.callout)
                }
                Spacer()
                HStack {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                        Text("Downloading…").foregroundStyle(.secondary)
                    } else if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install & Use") { install(asset, use: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInstalling)
                    Button("Install") { install(asset, use: false) }
                        .disabled(isInstalling || isInstalled)
                }
            }
            .padding(16)
        } else {
            Text("Select a font family")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fontSample(family: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("user@portside:~$ echo ahoy")
            Text("0123456789 !=> -> ~ {} []")
            Text("The quick brown fox jumps over the lazy dog")
        }
        .font(.custom(family, size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: store.appearance.background))
        .foregroundStyle(Color(nsColor: store.appearance.foreground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func install(_ asset: FontGallery.FontAsset, use: Bool) {
        Task {
            do {
                try await gallery.install(asset)
                if use, let family = FontGallery.installedFamilyName(for: asset) {
                    var updated = store.appearance
                    updated.fontName = family
                    store.updateAppearance(updated)
                }
            } catch {
                installError = error.localizedDescription
            }
        }
    }
}
