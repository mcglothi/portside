import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettingsView: View {
    @EnvironmentObject var store: SessionStore
    @State private var showingThemeImporter = false
    @State private var showingGallery = false
    @State private var showingFontGallery = false
    @State private var importError: String?

    /// Fixed-pitch families make the terminal legible; offer those first.
    /// State (not static) so the list can refresh after a font install.
    @State private var monospacedFamilies: [String] = Self.scanFamilies()

    private static func scanFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }

    private var appearance: Binding<TerminalAppearance> {
        Binding(get: { store.appearance }, set: { store.updateAppearance($0) })
    }

    private func colorBinding(_ keyPath: WritableKeyPath<TerminalAppearance, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: HexColor.nsColor(store.appearance[keyPath: keyPath])) },
            set: { newColor in
                var updated = store.appearance
                updated[keyPath: keyPath] = HexColor.hex(from: NSColor(newColor))
                store.updateAppearance(updated)
            }
        )
    }

    private var cursorShapeBinding: Binding<CursorShape> {
        Binding(
            get: { store.appearance.cursorShape },
            set: { var updated = store.appearance; updated.cursorShape = $0; store.updateAppearance(updated) }
        )
    }

    private var cursorBlinksBinding: Binding<Bool> {
        Binding(
            get: { store.appearance.cursorBlinks },
            set: { var updated = store.appearance; updated.cursorBlinks = $0; store.updateAppearance(updated) }
        )
    }

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: appearance.fontName) {
                    // Keep the current selection visible even if it isn't a
                    // detected fixed-pitch family (e.g. just installed).
                    let families = monospacedFamilies.contains(store.appearance.fontName)
                        ? monospacedFamilies
                        : ([store.appearance.fontName] + monospacedFamilies)
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: appearance.fontSize, in: 8...24, step: 1)
                    Text("\(Int(store.appearance.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Button("Browse Fonts…") { showingFontGallery = true }
                    Spacer()
                    Text("Nerd Fonts collection")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Theme") {
                Picker("Preset", selection: Binding(
                    get: { store.appearance.themeName },
                    set: { name in
                        if let theme = store.allThemes.first(where: { $0.name == name }) {
                            store.updateAppearance(store.appearance.applying(theme))
                        }
                    }
                )) {
                    ForEach(store.allThemes) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                }
                ColorPicker("Text", selection: colorBinding(\.foregroundHex), supportsOpacity: false)
                ColorPicker("Background", selection: colorBinding(\.backgroundHex), supportsOpacity: false)
                ColorPicker("Cursor", selection: colorBinding(\.cursorHex), supportsOpacity: false)
                Picker("Cursor Shape", selection: cursorShapeBinding) {
                    ForEach(CursorShape.allCases) { shape in
                        Text(shape.label).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Toggle("Blinking Cursor", isOn: cursorBlinksBinding)
                    Spacer()
                    CursorShapeSwatch(shape: store.appearance.cursorShape,
                                      blinks: store.appearance.cursorBlinks,
                                      color: store.appearance.cursor)
                }
                ColorPicker("Alert Color", selection: colorBinding(\.alertHex), supportsOpacity: false)
                HStack {
                    Button("Browse Gallery…") { showingGallery = true }
                    Button("Import Theme…") { showingThemeImporter = true }
                    Spacer()
                    Text("iTerm2 .itermcolors or Portside .json")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Preview") {
                preview
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 700, idealHeight: 780)
        .sheet(isPresented: $showingGallery) {
            ThemeGalleryView().environmentObject(store)
        }
        .sheet(isPresented: $showingFontGallery, onDismiss: {
            monospacedFamilies = Self.scanFamilies()
        }) {
            FontGalleryView().environmentObject(store)
        }
        .fileImporter(
            isPresented: $showingThemeImporter,
            allowedContentTypes: [.json, .propertyList, .xml, .data],
            allowsMultipleSelection: false
        ) { result in importTheme(result) }
        .alert("Import Theme", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var preview: some View {
        TerminalPreviewView(theme: store.appearance.asTheme,
                            fontName: store.appearance.fontName,
                            fontSize: store.appearance.fontSize)
    }

    private func importTheme(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            let theme = try TerminalTheme.imported(from: data, name: name)
            let stored = store.addCustomTheme(theme)
            store.updateAppearance(store.appearance.applying(stored))
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// Small live sample of the chosen cursor shape/blink so the picker's effect
/// is visible without a real terminal — mirrors the actual caret geometry
/// (full cell width for block/underline, a thin edge for bar). Driven by a
/// `TimelineView` rather than a `withAnimation`-toggled `@State` flag: the
/// latter runs its own independent repeating animation on the swatch's
/// identity, so a shape change made mid-blink got silently absorbed into
/// that animation instead of showing immediately. Recomputing from the
/// current time on every tick means there's no stale state to get stuck on.
private struct CursorShapeSwatch: View {
    let shape: CursorShape
    let blinks: Bool
    let color: NSColor

    private static let cellSize = CGSize(width: 14, height: 18)
    private static let blinkInterval: TimeInterval = 0.6

    var body: some View {
        Group {
            if blinks {
                TimelineView(.periodic(from: .now, by: Self.blinkInterval)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / Self.blinkInterval)
                    frame(visible: tick.isMultiple(of: 2))
                }
            } else {
                frame(visible: true)
            }
        }
    }

    private func frame(visible: Bool) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(.tertiary, lineWidth: 1)
            glyph
                .opacity(visible ? 1 : 0)
        }
        .frame(width: Self.cellSize.width, height: Self.cellSize.height)
        .animation(.easeInOut(duration: 0.3), value: visible)
    }

    @ViewBuilder private var glyph: some View {
        let fill = Color(nsColor: color)
        switch shape {
        case .block:
            Rectangle().fill(fill)
        case .underline:
            Rectangle().fill(fill).frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        case .bar:
            Rectangle().fill(fill).frame(width: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
