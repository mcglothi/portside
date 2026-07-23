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
    /// Shared identities hosts can defer to — see `CredentialProfile`.
    @Published private(set) var credentialProfiles: [CredentialProfile] = []
    /// The profile applied when a host has `savePassword` on but no explicit
    /// `credentialProfileID` and no password of its own — the implicit
    /// fallback that preserves pre-profiles behavior for hosts that never
    /// opt into a *named* profile. Seeded once by `migrateLegacyDefault()`.
    @Published var defaultProfileID: UUID?
    @Published var logging = LoggingSettings()
    @Published var terminal = TerminalSettings()
    @Published var keyBindings = KeyBindings()
    /// The last-persisted open session layout, replayed on launch when
    /// `terminal.restoreMode` allows. Written continuously as tabs change.
    @Published private(set) var workspace = WorkspaceSnapshot()

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
        var terminal: TerminalSettings?
        var workspace: WorkspaceSnapshot?
        var keyBindings: KeyBindings?
        var credentialProfiles: [CredentialProfile]?
        var defaultProfileID: UUID?
    }

    /// Built-in presets plus imported themes, for the settings picker.
    var allThemes: [TerminalTheme] { TerminalTheme.builtIns + customThemes }

    private let fileURL: URL
    /// When true, first-launch seeding reads ~/.ssh/config. Tests pass a temp
    /// file and disable seeding so they start from an empty, isolated library.
    private let seedsFromSSHConfig: Bool

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = appSupport.appendingPathComponent("Portside/portside.json")
        seedsFromSSHConfig = true
        load()
    }

    /// Test seam: an isolated library backed by `fileURL`, never touching the
    /// user's real library or ~/.ssh/config.
    init(fileURL: URL, seedsFromSSHConfig: Bool = false) {
        self.fileURL = fileURL
        self.seedsFromSSHConfig = seedsFromSSHConfig
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

    /// Deletes every entry whose id is in `ids`, saving once. No-op (and no
    /// save) when nothing matches, so a stray empty selection can't churn disk.
    func delete(ids: Set<UUID>) {
        guard entries.contains(where: { ids.contains($0.id) }) else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    /// Bulk-flips "Save password in Keychain" for every entry whose id is in
    /// `ids` — for imported libraries where most hosts should have it on but
    /// weren't created through the editor's per-host toggle. Only sets the
    /// flag; it doesn't (can't) invent an actual password for the Keychain —
    /// each host still needs its password entered once in the editor.
    func setSavePassword(_ on: Bool, ids: Set<UUID>) {
        var changed = false
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].savePassword != on {
            entries[i].savePassword = on
            changed = true
        }
        guard changed else { return }
        save()
    }

    /// Favorited hosts, alphabetical — feeds the welcome screen's Favorites
    /// section.
    var favoriteEntries: [SessionEntry] {
        entries.filter(\.isFavorite)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].isFavorite.toggle()
        save()
    }

    /// Bulk-sets favorite status across a multi-selection, mirroring
    /// `setSavePassword(_:ids:)`.
    func setFavorite(_ on: Bool, ids: Set<UUID>) {
        var changed = false
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].isFavorite != on {
            entries[i].isFavorite = on
            changed = true
        }
        guard changed else { return }
        save()
    }

    // MARK: - Credential profiles

    func upsert(_ profile: CredentialProfile) {
        if let i = credentialProfiles.firstIndex(where: { $0.id == profile.id }) {
            credentialProfiles[i] = profile
        } else {
            credentialProfiles.append(profile)
        }
        save()
    }

    /// Removes the profile and its Keychain password. Hosts still pointing at
    /// it (`credentialProfileID`) are left alone rather than mutated here —
    /// resolution treats an unknown profile id as "no profile assigned," and
    /// the editor/sidebar show it as unassigned once the id no longer matches
    /// anything in `credentialProfiles`.
    func delete(_ profile: CredentialProfile) {
        credentialProfiles.removeAll { $0.id == profile.id }
        if defaultProfileID == profile.id { defaultProfileID = nil }
        CredentialStore.deleteProfilePassword(for: profile.id)
        save()
    }

    func credentialProfile(id: UUID?) -> CredentialProfile? {
        guard let id else { return nil }
        return credentialProfiles.first { $0.id == id }
    }

    /// Bulk-assigns (or clears, with `id: nil`) a credential profile across a
    /// multi-selection or a whole folder — mirrors `setSavePassword(_:ids:)`.
    /// Assigning also flips `savePassword` on (assigning a profile is an
    /// explicit "yes, use a saved credential here"); clearing leaves
    /// `savePassword` as-is, since a host might still want its own
    /// individually-saved password.
    func applyCredentialProfile(_ id: UUID?, to ids: Set<UUID>) {
        var changed = false
        for i in entries.indices where ids.contains(entries[i].id) {
            if entries[i].credentialProfileID != id {
                entries[i].credentialProfileID = id
                changed = true
            }
            if id != nil, !entries[i].savePassword {
                entries[i].savePassword = true
                changed = true
            }
        }
        guard changed else { return }
        save()
    }

    /// Migrates the old single "default password" (Settings ▸ Connection)
    /// into a profile named "Default", set as the implicit fallback — runs
    /// once, only when there's something to migrate and no profiles exist
    /// yet. Preserves existing behavior for hosts relying on the old
    /// fallback without touching their own data.
    private func migrateLegacyDefault() {
        guard credentialProfiles.isEmpty else { return }
        let legacyPassword = CredentialStore.defaultPassword()
        let hasLegacyDefault = (defaults.user?.isEmpty == false)
            || (defaults.identityFile?.isEmpty == false)
            || (defaults.defaultSavePassword ?? false)
            || legacyPassword != nil
        guard hasLegacyDefault else { return }
        let profile = CredentialProfile(name: "Default", user: defaults.user, identityFile: defaults.identityFile)
        credentialProfiles = [profile]
        defaultProfileID = profile.id
        if let legacyPassword {
            CredentialStore.setProfilePassword(legacyPassword, for: profile.id)
            CredentialStore.deleteDefaultPassword()
        }
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

    /// Adds (or replaces by name) an imported theme and returns the stored
    /// copy. Names colliding with a built-in get a suffix so `allThemes` ids
    /// (which are the names) stay unique.
    @discardableResult
    func addCustomTheme(_ theme: TerminalTheme) -> TerminalTheme {
        var theme = theme
        if TerminalTheme.builtIns.contains(where: { $0.name == theme.name }) {
            theme.name += " (Imported)"
        }
        customThemes.removeAll { $0.name == theme.name }
        customThemes.append(theme)
        save()
        return theme
    }

    func updateDefaults(_ defaults: ConnectionDefaults) {
        self.defaults = defaults
        save()
    }

    func updateLogging(_ logging: LoggingSettings) {
        self.logging = logging
        save()
    }

    func updateTerminal(_ terminal: TerminalSettings) {
        self.terminal = terminal
        save()
    }

    func updateKeyBindings(_ keyBindings: KeyBindings) {
        self.keyBindings = keyBindings
        save()
    }

    /// Records the open session layout for restore-on-launch. No-op when the
    /// snapshot is unchanged so churning tabs don't rewrite disk needlessly.
    func saveWorkspace(_ snapshot: WorkspaceSnapshot) {
        guard snapshot != workspace else { return }
        workspace = snapshot
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

    /// Applies an assigned credential profile's user/identity (if any) —
    /// *overriding* the entry's own values, since the point of a profile is
    /// that rotating it actually changes what a host uses, even if the host
    /// has stale values of its own from before being assigned — then falls
    /// back to the connection defaults for whatever's still blank, so a
    /// global default user/key applies without editing each host.
    func resolved(_ entry: SessionEntry) -> SessionEntry {
        var e = entry
        if let profile = credentialProfile(id: e.credentialProfileID) {
            if let u = profile.user, !u.isEmpty, e.sshAlias?.isEmpty ?? true { e.user = u }
            if let key = profile.identityFile, !key.isEmpty { e.identityFile = key }
        }
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

    /// Moves every entry in `ids` into `folder` ("" = top level), saving once.
    /// Skips entries already there; saves only if at least one actually moved.
    func move(entryIDs ids: Set<UUID>, toFolder folder: String) {
        var changed = false
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].folder != folder {
            entries[i].folder = folder
            changed = true
        }
        if changed { save() }
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

    /// Merges a Portside export. Entries get fresh ids and no saved-password
    /// flag (Keychain secrets never travel in an export), standalone folders
    /// merge by path, and macros dedupe by name. Returns what was added.
    @discardableResult
    func importExport(entries importedEntries: [SessionEntry],
                      folders importedFolders: [String],
                      macros importedMacros: [Macro]) -> (sessions: Int, macros: Int) {
        for folder in importedFolders {
            let clean = normalize(folder)
            if !clean.isEmpty, !explicitFolders.contains(clean) {
                explicitFolders.append(clean)
            }
        }

        let existingKeys = Set(entries.map { "\($0.folder)|\($0.name)|\($0.hostname)" })
        var addedSessions = 0
        for var entry in importedEntries {
            let key = "\(entry.folder)|\(entry.name)|\(entry.hostname)"
            if existingKeys.contains(key) { continue }
            entry.id = UUID()
            entry.savePassword = false
            entries.append(entry)
            addedSessions += 1
        }

        let existingMacroNames = Set(macros.map(\.name))
        var addedMacros = 0
        for macro in importedMacros where !existingMacroNames.contains(macro.name) {
            var copy = macro
            copy.id = UUID()
            macros.append(copy)
            addedMacros += 1
        }

        save()
        return (addedSessions, addedMacros)
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
            terminal = doc.terminal ?? TerminalSettings()
            workspace = doc.workspace ?? WorkspaceSnapshot()
            keyBindings = doc.keyBindings ?? KeyBindings()
            credentialProfiles = doc.credentialProfiles ?? []
            defaultProfileID = doc.defaultProfileID
        } else if seedsFromSSHConfig {
            entries = SSHConfigImporter.importEntries()
            save()
        }
        // Only the real app instance (never a test's isolated fileURL init,
        // which always passes seedsFromSSHConfig: false) may touch the actual
        // system Keychain here — CredentialStore isn't test-isolated itself,
        // so without this guard a test run reads/mutates the real default
        // password out from under the user.
        if seedsFromSSHConfig {
            migrateLegacyDefault()
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
                                        customThemes: customThemes, defaults: defaults, logging: logging,
                                        terminal: terminal, workspace: workspace, keyBindings: keyBindings,
                                        credentialProfiles: credentialProfiles, defaultProfileID: defaultProfileID))
                .write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Portside: failed to save library: \(error)")
        }
    }
}
