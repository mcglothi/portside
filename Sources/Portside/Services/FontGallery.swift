import AppKit
import CoreText

/// Browses the Nerd Fonts releases (github.com/ryanoasis/nerd-fonts) — the
/// de-facto collection of terminal-patched monospace fonts — and installs
/// families into ~/Library/Fonts. Uses the .tar.xz assets (~5x smaller than
/// the zips); macOS bsdtar auto-detects the compression.
///
/// Like ThemeGallery, the release index is one GitHub API call cached for a
/// day; downloads come from objects.githubusercontent.com and are unmetered.
@MainActor
final class FontGallery: ObservableObject {
    struct FontAsset: Identifiable, Equatable, Codable {
        var name: String       // release asset stem, e.g. "JetBrainsMono"
        var url: URL
        var bytes: Int
        var id: String { name }
        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    @Published private(set) var assets: [FontAsset] = []
    @Published private(set) var isLoadingIndex = false
    @Published private(set) var indexError: String?
    @Published private(set) var installing: Set<String> = []
    @Published private(set) var installedStems: Set<String> = []

    private static let releaseURL = URL(string:
        "https://api.github.com/repos/ryanoasis/nerd-fonts/releases/latest")!
    private static let indexCacheKey = "fontGallery.index"
    private static let indexDateKey = "fontGallery.indexDate"
    private static let indexMaxAge: TimeInterval = 86_400
    private static let userFonts = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Fonts")

    enum GalleryError: LocalizedError {
        case badResponse, extractFailed, noFontsInArchive
        var errorDescription: String? {
            switch self {
            case .badResponse: return "The font catalog could not be loaded."
            case .extractFailed: return "The downloaded archive could not be extracted."
            case .noFontsInArchive: return "No font files were found in the archive."
            }
        }
    }

    init() {
        refreshInstalled()
    }

    /// A family counts as installed when any user font file starts with its
    /// stem — Nerd Fonts name files like "JetBrainsMonoNerdFont-Regular.ttf".
    func refreshInstalled() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Self.userFonts.path)) ?? []
        installedStems = Set(assets.map(\.name).filter { stem in
            files.contains { $0.hasPrefix(stem + "NerdFont") }
        })
    }

    func loadIndex() async {
        guard assets.isEmpty, !isLoadingIndex else { return }

        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.indexCacheKey),
           let cached = try? JSONDecoder().decode([FontAsset].self, from: data),
           !cached.isEmpty,
           let date = defaults.object(forKey: Self.indexDateKey) as? Date,
           Date().timeIntervalSince(date) < Self.indexMaxAge {
            assets = cached
            refreshInstalled()
            return
        }

        isLoadingIndex = true
        defer { isLoadingIndex = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.releaseURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GalleryError.badResponse
            }
            struct Release: Decodable {
                struct Asset: Decodable {
                    let name: String
                    let browser_download_url: URL
                    let size: Int
                }
                let assets: [Asset]
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let fetched = release.assets
                .filter { $0.name.hasSuffix(".tar.xz") && !$0.name.hasPrefix("FontPatcher") }
                .map { FontAsset(name: String($0.name.dropLast(".tar.xz".count)),
                                 url: $0.browser_download_url, bytes: $0.size) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !fetched.isEmpty else { throw GalleryError.badResponse }
            assets = fetched
            refreshInstalled()
            if let encoded = try? JSONEncoder().encode(fetched) {
                defaults.set(encoded, forKey: Self.indexCacheKey)
                defaults.set(Date(), forKey: Self.indexDateKey)
            }
        } catch {
            if let data = defaults.data(forKey: Self.indexCacheKey),
               let cached = try? JSONDecoder().decode([FontAsset].self, from: data), !cached.isEmpty {
                assets = cached
                refreshInstalled()
            } else {
                indexError = error.localizedDescription
            }
        }
    }

    /// Downloads, extracts, and copies the family's font files into
    /// ~/Library/Fonts, then registers them so they're usable immediately
    /// without an app restart. Returns the installed file URLs.
    @discardableResult
    func install(_ asset: FontAsset) async throws -> [URL] {
        installing.insert(asset.name)
        defer { installing.remove(asset.name) }

        let (archive, response) = try await URLSession.shared.download(from: asset.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GalleryError.badResponse
        }

        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }
        try await Self.run("/usr/bin/tar", ["-xf", archive.path, "-C", extractDir.path])

        let fontFiles = (FileManager.default
            .enumerator(at: extractDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        guard !fontFiles.isEmpty else { throw GalleryError.noFontsInArchive }

        try FileManager.default.createDirectory(at: Self.userFonts, withIntermediateDirectories: true)
        var installed: [URL] = []
        for file in fontFiles {
            let dest = Self.userFonts.appendingPathComponent(file.lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: file, to: dest)
            installed.append(dest)
        }
        // fontd notices ~/Library/Fonts on its own eventually; registering
        // process-wide makes the family selectable right now. The per-URL
        // call is synchronous — the family must be queryable the moment we
        // return so "Install & Use" can look it up (the URLs-array variant
        // registers asynchronously).
        for url in installed {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        installedStems.insert(asset.name)
        return installed
    }

    /// The monospace family name the asset installed (e.g. "JetBrainsMono
    /// Nerd Font Mono"), preferring the fixed-advance "Mono" variant.
    static func installedFamilyName(for asset: FontAsset) -> String? {
        // CoreText, not NSFontManager: the latter can serve a cached list
        // that misses fonts registered moments ago.
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        let matches = families.filter {
            $0.replacingOccurrences(of: " ", with: "").hasPrefix(asset.name + "NerdFont")
        }
        return matches.first { $0.hasSuffix("Nerd Font Mono") } ?? matches.first
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: GalleryError.extractFailed)
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}
