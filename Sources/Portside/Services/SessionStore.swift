import Foundation

/// Portside's own session/macro library, persisted as JSON in Application
/// Support. Seeded from ~/.ssh/config on first launch; after that Portside
/// owns the data, which is what makes entries editable and folderable.
final class SessionStore: ObservableObject {
    @Published private(set) var entries: [SessionEntry] = []
    @Published private(set) var macros: [Macro] = []
    @Published private(set) var forwards: [PortForward] = []
    /// Most-recent-first connection history for the welcome screen.
    @Published private(set) var recents: [RecentConnection] = []
    /// Folders that exist independently of any session, so empty folders and
    /// subfolders can be created and persist.
    @Published private(set) var explicitFolders: [String] = []
    @Published var appearance: TerminalAppearance = .default
    /// Themes imported by the user, shown alongside the built-ins.
    @Published private(set) var customThemes: [TerminalTheme] = []
    /// Fallback user/key applied to sessions that don't specify their own.
    @Published var defaults = ConnectionDefaults()
    @Published var logging = LoggingSettings()

    private struct Document: Codable {
        var entries: [SessionEntry]
        var macros: [Macro]
        var forwards: [PortForward]?
        var recents: [RecentConnection]?
        var explicitFolders: [String]?
        var appearance: TerminalAppearance?
        var customThemes: [TerminalTheme]?
        var defaults: ConnectionDefaults?
        var logging: LoggingSettings?
    }

    /// Built-in presets plus imported themes, for the settings picker.
    var allThemes: [TerminalTheme] { TerminalTheme.builtIns + customThemes }

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = appSupport.appendingPathComponent("Portside/portside.json")
        load()
    }

    /// Union of folders implied by sessions and standalone folders.
    var folders: [String] {
        let fromEntries = entries.map(\.folder).filter { !$0.isEmpty }
        return Array(Set(fromEntries + explicitFolders)).sorted()
    }

    // MARK: - CRUD

    func upsert(_ entry: SessionEntry) {
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    func delete(_ entry: SessionEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Clones a session (fresh id, " copy" suffix) right after the original.
    /// The saved password isn't copied — it's keyed by id and stays with the
    /// original; the clone can set its own.
    @discardableResult
    func duplicate(_ entry: SessionEntry) -> SessionEntry {
        var copy = entry
        copy.id = UUID()
        copy.name = entry.name + " copy"
        copy.savePassword = false
        copy.source = .manual
        if let i = entries.firstIndex(where: { $0.id == entry.id }) {
            entries.insert(copy, at: i + 1)
        } else {
            entries.append(copy)
        }
        save()
        return copy
    }

    func upsert(_ macro: Macro) {
        if let i = macros.firstIndex(where: { $0.id == macro.id }) {
            macros[i] = macro
        } else {
            macros.append(macro)
        }
        save()
    }

    func delete(_ macro: Macro) {
        macros.removeAll { $0.id == macro.id }
        save()
    }

    func upsert(_ forward: PortForward) {
        if let i = forwards.firstIndex(where: { $0.id == forward.id }) {
            forwards[i] = forward
        } else {
            forwards.append(forward)
        }
        save()
    }

    func delete(_ forward: PortForward) {
        forwards.removeAll { $0.id == forward.id }
        save()
    }

    /// The library entry a forward tunnels through, if it still exists.
    func entry(id: UUID?) -> SessionEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    // MARK: - Recent connections

    /// Moves (or adds) the host to the front of the history. Capped well above
    /// what the welcome screen shows so deleted hosts don't shrink the list.
    func recordConnection(_ entry: SessionEntry) {
        recents.removeAll { $0.entryID == entry.id }
        recents.insert(RecentConnection(entryID: entry.id, date: Date()), at: 0)
        if recents.count > 20 {
            recents.removeLast(recents.count - 20)
        }
        save()
    }

    /// The history joined against the library — deleted hosts drop out.
    func recentEntries(limit: Int) -> [(entry: SessionEntry, date: Date)] {
        var result: [(SessionEntry, Date)] = []
        for recent in recents {
            guard let entry = entry(id: recent.entryID) else { continue }
            result.append((entry, recent.date))
            if result.count == limit { break }
        }
        return result
    }

    func updateAppearance(_ appearance: TerminalAppearance) {
        self.appearance = appearance
        save()
    }

    /// Adds (or replaces by name) an imported theme and returns it.
    func addCustomTheme(_ theme: TerminalTheme) {
        customThemes.removeAll { $0.name == theme.name }
        customThemes.append(theme)
        save()
    }

    func updateDefaults(_ defaults: ConnectionDefaults) {
        self.defaults = defaults
        save()
    }

    func updateLogging(_ logging: LoggingSettings) {
        self.logging = logging
        save()
    }

    /// All sessions in a folder and its subfolders, resolved and sorted by name.
    func entriesInFolder(_ path: String) -> [SessionEntry] {
        let prefix = path + "/"
        return entries
            .filter { $0.folder == path || $0.folder.hasPrefix(prefix) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map(resolved)
    }

    /// Fills in user/identity from the connection defaults when a session
    /// leaves them blank, so a default user/key applies without editing each host.
    func resolved(_ entry: SessionEntry) -> SessionEntry {
        var e = entry
        if (e.user?.isEmpty ?? true), e.sshAlias?.isEmpty ?? true,
           let u = defaults.user, !u.isEmpty {
            e.user = u
        }
        if (e.identityFile?.isEmpty ?? true), let key = defaults.identityFile, !key.isEmpty {
            e.identityFile = key
        }
        return e
    }

    // MARK: - Folders

    /// Moves a session into `folder` ("" = top level).
    func move(entryID: UUID, toFolder folder: String) {
        guard let i = entries.firstIndex(where: { $0.id == entryID }) else { return }
        guard entries[i].folder != folder else { return }
        entries[i].folder = folder
        save()
    }

    func createFolder(_ path: String) {
        let clean = normalize(path)
        guard !clean.isEmpty, !explicitFolders.contains(clean) else { return }
        explicitFolders.append(clean)
        save()
    }

    /// Renames the leaf of `path` to `newName`, rewriting affected sessions and
    /// subfolders so their paths follow.
    func renameFolder(_ path: String, to newName: String) {
        let leaf = normalize(newName)
        guard !leaf.isEmpty, !leaf.contains("/") else { return }
        let parent = folderParent(path)
        let newPath = parent.isEmpty ? leaf : parent + "/" + leaf
        guard newPath != path else { return }
        let prefix = path + "/"

        for i in entries.indices {
            if entries[i].folder == path {
                entries[i].folder = newPath
            } else if entries[i].folder.hasPrefix(prefix) {
                entries[i].folder = newPath + "/" + String(entries[i].folder.dropFirst(prefix.count))
            }
        }
        explicitFolders = explicitFolders.map { f in
            if f == path { return newPath }
            if f.hasPrefix(prefix) { return newPath + "/" + String(f.dropFirst(prefix.count)) }
            return f
        }
        save()
    }

    /// Deletes a folder and its descendants, relocating any sessions underneath
    /// to the deleted folder's parent so nothing is lost.
    func deleteFolder(_ path: String) {
        let parent = folderParent(path)
        let prefix = path + "/"
        for i in entries.indices where entries[i].folder == path || entries[i].folder.hasPrefix(prefix) {
            entries[i].folder = parent
        }
        explicitFolders.removeAll { $0 == path || $0.hasPrefix(prefix) }
        save()
    }

    private func normalize(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private func folderParent(_ path: String) -> String {
        var parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    // MARK: - Imports

    /// Adds new hosts from ~/.ssh/config that aren't already in the library.
    @discardableResult
    func mergeSSHConfig() -> Int {
        let existingAliases = Set(entries.compactMap(\.sshAlias))
        let new = SSHConfigImporter.importEntries().filter {
            guard let alias = $0.sshAlias else { return true }
            return !existingAliases.contains(alias)
        }
        guard !new.isEmpty else { return 0 }
        entries.append(contentsOf: new)
        save()
        return new.count
    }

    /// Adds imported entries, skipping exact duplicates (name + host + folder).
    @discardableResult
    func addImported(entries newEntries: [SessionEntry], macros newMacros: [Macro]) -> (sessions: Int, macros: Int) {
        let existingKeys = Set(entries.map { "\($0.folder)|\($0.name)|\($0.hostname)" })
        let fresh = newEntries.filter { !existingKeys.contains("\($0.folder)|\($0.name)|\($0.hostname)") }
        entries.append(contentsOf: fresh)

        let existingMacroNames = Set(macros.map(\.name))
        let freshMacros = newMacros.filter { !existingMacroNames.contains($0.name) }
        macros.append(contentsOf: freshMacros)

        if !fresh.isEmpty || !freshMacros.isEmpty { save() }
        return (fresh.count, freshMacros.count)
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let doc = try? JSONDecoder().decode(Document.self, from: data) {
            entries = doc.entries
            macros = doc.macros
            forwards = doc.forwards ?? []
            recents = doc.recents ?? []
            explicitFolders = doc.explicitFolders ?? []
            appearance = doc.appearance ?? .default
            customThemes = doc.customThemes ?? []
            defaults = doc.defaults ?? ConnectionDefaults()
            logging = doc.logging ?? LoggingSettings()
        } else {
            entries = SSHConfigImporter.importEntries()
            save()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(entries: entries, macros: macros, forwards: forwards,
                                        recents: recents,
                                        explicitFolders: explicitFolders, appearance: appearance,
                                        customThemes: customThemes, defaults: defaults, logging: logging))
                .write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Portside: failed to save library: \(error)")
        }
    }
}
