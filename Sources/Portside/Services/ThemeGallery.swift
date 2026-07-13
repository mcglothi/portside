import Foundation

/// Browses mbadolato/iTerm2-Color-Schemes — the de-facto central collection
/// of terminal color schemes (~600, MIT licensed) — so themes can be
/// previewed and installed from inside the app.
///
/// The index is one GitHub API call (rate-limited to 60/hr unauthenticated),
/// so it's cached on disk for a day. Individual schemes are fetched from
/// raw.githubusercontent.com, which is not metered, and kept in memory for
/// the life of the gallery.
@MainActor
final class ThemeGallery: ObservableObject {
    @Published private(set) var names: [String] = []
    @Published private(set) var isLoadingIndex = false
    @Published private(set) var indexError: String?

    private var themeCache: [String: TerminalTheme] = [:]

    private static let indexURL = URL(string:
        "https://api.github.com/repos/mbadolato/iTerm2-Color-Schemes/contents/schemes")!
    private static let rawBase =
        "https://raw.githubusercontent.com/mbadolato/iTerm2-Color-Schemes/master/schemes/"
    private static let indexCacheKey = "themeGallery.index"
    private static let indexDateKey = "themeGallery.indexDate"
    private static let indexMaxAge: TimeInterval = 86_400

    enum GalleryError: LocalizedError {
        case badResponse
        var errorDescription: String? { "The theme catalog could not be loaded." }
    }

    func loadIndex() async {
        guard names.isEmpty, !isLoadingIndex else { return }

        let defaults = UserDefaults.standard
        if let cached = defaults.stringArray(forKey: Self.indexCacheKey),
           !cached.isEmpty,
           let date = defaults.object(forKey: Self.indexDateKey) as? Date,
           Date().timeIntervalSince(date) < Self.indexMaxAge {
            names = cached
            return
        }

        isLoadingIndex = true
        defer { isLoadingIndex = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.indexURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GalleryError.badResponse
            }
            struct Entry: Decodable { let name: String }
            let fetched = try JSONDecoder().decode([Entry].self, from: data)
                .map(\.name)
                .filter { $0.hasSuffix(".itermcolors") }
                .map { String($0.dropLast(".itermcolors".count)) }
            guard !fetched.isEmpty else { throw GalleryError.badResponse }
            names = fetched
            defaults.set(fetched, forKey: Self.indexCacheKey)
            defaults.set(Date(), forKey: Self.indexDateKey)
        } catch {
            // A stale cache beats an empty gallery when offline.
            if let cached = defaults.stringArray(forKey: Self.indexCacheKey), !cached.isEmpty {
                names = cached
            } else {
                indexError = error.localizedDescription
            }
        }
    }

    func theme(named name: String) async throws -> TerminalTheme {
        if let cached = themeCache[name] { return cached }
        let file = "\(name).itermcolors"
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: Self.rawBase + file) else { throw GalleryError.badResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GalleryError.badResponse
        }
        let theme = try TerminalTheme.imported(from: data, name: name)
        themeCache[name] = theme
        return theme
    }
}
