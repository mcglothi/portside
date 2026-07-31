import AppKit
import Foundation

/// Portside's own session/macro library, persisted as JSON in Application
/// Support. Seeded from ~/.ssh/config on first launch; after that Portside
/// owns the data, which is what makes entries editable and folderable.
final class SessionStore: ObservableObject {
    @Published private(set) var entries: [SessionEntry] = []
    @Published private(set) var macros: [Macro] = []
    /// Saved host groups — a named layout that reopens as one tab.
    @Published private(set) var groups: [SessionGroup] = []
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
    @Published private(set) var connectionStats: [ConnectionStat] = []
    @Published private(set) var connectionLog: [ConnectionLogEntry] = []
    @Published private(set) var history = HistorySettings()
    @Published private(set) var commandHistory: [CommandEvent] = []
    @Published var keyBindings = KeyBindings()
    /// The last-persisted open session layout, replayed on launch when
    /// `terminal.restoreMode` allows. Written continuously as tabs change.
    @Published private(set) var workspace = WorkspaceSnapshot()

    private struct Document: Codable {
        var entries: [SessionEntry]
        var macros: [Macro]
        var groups: LenientArray<SessionGroup>?
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
        var connectionStats: [ConnectionStat]?
        var connectionLog: [ConnectionLogEntry]?
        var history: HistorySettings?
        // Read-only now: present in libraries written before history moved to
        // its own file, and migrated out on first load.
        var commandHistory: [CommandEvent]?
    }

    /// Built-in presets plus imported themes, for the settings picker.
    var allThemes: [TerminalTheme] { TerminalTheme.builtIns + customThemes }

    private let fileURL: URL

    /// History lives beside the library rather than inside it, for three
    /// reasons: recording a command would otherwise rewrite the entire host
    /// library (hosts, folders, macros, profiles) on every command typed;
    /// `portside.json` is what Export Sessions writes, so recorded command
    /// lines would travel with any shared or backed-up library; and history is
    /// churn-heavy data with a completely different lifetime from the library
    /// it sits next to.
    private var historyFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("history.json")
    }

    /// Set when history was migrated out of the library mid-load; the library
    /// is rewritten once loading has finished, never during.
    private var needsLegacyHistoryCleanup = false

    /// State that belongs to *this Mac*, not to the infrastructure the library
    /// describes.
    ///
    /// The library is the thing worth backing up, sharing and putting in a
    /// synced folder. These fields would actively misbehave there: a second Mac
    /// restoring the first one's open tabs, a laptop adopting a desktop's font
    /// size and Metal setting, a log directory that doesn't exist on the other
    /// machine. Third file for a third lifetime, on the same reasoning that
    /// moved history out — churn-heavy, machine-shaped, nobody's idea of
    /// shareable.
    ///
    /// Every field optional and defaulted: this file is *disposable*. Losing it
    /// costs you a window layout and a font size, so a decode failure falls
    /// back to defaults rather than blocking anything, which is the opposite of
    /// how the library is treated.
    private struct LocalDocument: Codable {
        var workspace: WorkspaceSnapshot?
        var appearance: TerminalAppearance?
        var customThemes: [TerminalTheme]?
        var terminal: TerminalSettings?
        var logging: LoggingSettings?
        var recents: [RecentConnection]?
    }

    private var localFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("local.json")
    }

    /// Set when local state was migrated out of the library mid-load; the
    /// library is rewritten once loading has finished, never during.
    private var needsLegacyLocalCleanup = false

    private struct HistoryDocument: Codable {
        var connectionStats: [ConnectionStat]?
        var connectionLog: [ConnectionLogEntry]?
        var commandHistory: [CommandEvent]?
    }
    /// When true, first-launch seeding reads ~/.ssh/config. Tests pass a temp
    /// file and disable seeding so they start from an empty, isolated library.
    private let seedsFromSSHConfig: Bool

    /// Runs the app against a throwaway library instead of the real one.
    ///
    /// A build started with `swift run` otherwise shares everything with the
    /// installed app: the same hosts, the same saved workspace, the same
    /// history. That makes driving a dev build a small risk to real data every
    /// time, and it means every launch stops to ask whether to restore the
    /// session you left open in the *other* copy.
    ///
    ///     PORTSIDE_LIBRARY_DIR=/tmp/portside-test swift run
    ///
    /// Seeding from `~/.ssh/config` is deliberately off in this mode. An
    /// isolated library is for testing, and quietly filling it with the
    /// developer's real infrastructure defeats most of the point — including
    /// keeping real hostnames out of screenshots.
    static let libraryDirectoryOverrideKey = "PORTSIDE_LIBRARY_DIR"

    init() {
        let override = ProcessInfo.processInfo.environment[Self.libraryDirectoryOverrideKey]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        if let override {
            NSLog("Portside: using library at \(override.path) (\(Self.libraryDirectoryOverrideKey))")
        }
        let directory = override
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Portside")
        fileURL = directory.appendingPathComponent("portside.json")
        seedsFromSSHConfig = (override == nil)
        coalescesHistoryWrites = true
        load()
        observeTermination()
    }

    /// Test seam: an isolated library backed by `fileURL`, never touching the
    /// user's real library or ~/.ssh/config.
    ///
    /// History writes are synchronous here by default. The coalescing window
    /// needs a main run loop to fire, which most tests don't spin, so
    /// coalescing by default would turn every history assertion into a timing
    /// race. Tests covering the window itself opt in — some driving it with
    /// `flushHistory()`, some spinning the run loop to prove the timer lands
    /// a write on its own.
    init(fileURL: URL, seedsFromSSHConfig: Bool = false, coalescesHistoryWrites: Bool = false) {
        self.fileURL = fileURL
        self.seedsFromSSHConfig = seedsFromSSHConfig
        self.coalescesHistoryWrites = coalescesHistoryWrites
        load()
        observeTermination()
    }

    /// History writes are coalesced, so quitting has to settle the outstanding
    /// one — otherwise the last few seconds of commands before a quit are the
    /// ones that reliably go missing.
    private func observeTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flushHistory()
        }
    }

    private var terminationObserver: NSObjectProtocol?

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
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

    /// Removes the entry and its saved Keychain password together. Deletion
    /// used to leave the credential behind for context-menu and bulk paths —
    /// only the editor's own Delete button happened to clean it up, as a
    /// separate call the view made before this one. An orphaned credential
    /// then sits in the Keychain indefinitely, under a UUID no session
    /// references anymore.
    func delete(_ entry: SessionEntry) {
        entries.removeAll { $0.id == entry.id }
        CredentialStore.deletePassword(for: entry.id)
        save()
    }

    /// Deletes every entry whose id is in `ids` (and each one's Keychain
    /// password), saving once. No-op (and no save) when nothing matches, so a
    /// stray empty selection can't churn disk.
    func delete(ids: Set<UUID>) {
        guard entries.contains(where: { ids.contains($0.id) }) else { return }
        entries.removeAll { ids.contains($0.id) }
        for id in ids { CredentialStore.deletePassword(for: id) }
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
    /// Bulk environment tagging, for classifying a large imported inventory
    /// without editing hosts one at a time.
    func setEnvironment(_ environment: HostEnvironment, ids: Set<UUID>) {
        var changed = false
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].environment != environment {
            entries[i].environment = environment
            changed = true
        }
        guard changed else { return }
        save()
    }

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
            // Only remove the old copy once the new one is confirmed on disk
            // (write success, then a read-back) — this used to delete
            // unconditionally, so a failed Keychain write (locked keychain, a
            // stale ACL) silently lost the password rather than leaving it
            // somewhere the user could still find it.
            let wrote = CredentialStore.setProfilePassword(legacyPassword, for: profile.id)
            let confirmed = wrote && CredentialStore.profilePassword(for: profile.id) == legacyPassword
            if confirmed {
                CredentialStore.deleteDefaultPassword()
            } else {
                NSLog("Portside: legacy default password migration to profile \(profile.id) did not verify — leaving the old Keychain entry in place")
            }
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

    // MARK: - Groups

    func upsert(_ group: SessionGroup) {
        var copy = group
        copy.updatedAt = Date()
        if let i = groups.firstIndex(where: { $0.id == group.id }) {
            groups[i] = copy
        } else {
            groups.append(copy)
        }
        save()
    }

    func delete(_ group: SessionGroup) {
        groups.removeAll { $0.id == group.id }
        save()
    }

    func group(id: UUID) -> SessionGroup? { groups.first { $0.id == id } }

    /// Replaces a group's saved arrangement, leaving its name and folder alone.
    ///
    /// Called when a group's tab closes, so the group remembers what you left
    /// rather than what you first saved — decided as silent-with-undo rather
    /// than an explicit "Update Group" step, to be lived with for a while. No
    /// group, no write: closing an ordinary tab must not invent one.
    func updateLayout(groupID: UUID, layout: WorkspaceSnapshot.TabSnapshot, wasGridView: Bool) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard groups[i].layout != layout || groups[i].wasGridView != wasGridView else { return }
        groups[i].layout = layout
        groups[i].wasGridView = wasGridView
        groups[i].updatedAt = Date()
        save()
    }

    /// Groups whose folder is `folder`, name-sorted for the sidebar.
    func groups(inFolder folder: String) -> [SessionGroup] {
        groups.filter { $0.folder == folder }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func delete(_ macro: Macro) {
        macros.removeAll { $0.id == macro.id }
        save()
    }

    func setFavorite(_ isFavorite: Bool, macro: Macro) {
        guard let i = macros.firstIndex(where: { $0.id == macro.id }),
              macros[i].isFavorite != isFavorite else { return }
        macros[i].isFavorite = isFavorite
        save()
    }

    /// Macros pinned to the MultiExec bar, in library order so the bar does not
    /// reshuffle itself as things are favourited.
    var favoriteMacros: [Macro] { macros.filter(\.isFavorite) }

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
    /// Records the outcome of a connection attempt.
    ///
    /// Only a confirmed connection touches the aggregate. An attempt that
    /// failed is still worth logging, but counting it would inflate the host's
    /// total, reset its last-connected date, lift it up Quick Connect's
    /// ranking, and stop it ever showing as stale — all on the strength of a
    /// connection that never happened.
    func recordConnection(_ entry: SessionEntry, outcome: ConnectionOutcome) {
        guard !(history.excludeProtectedHosts && entry.isProtected) else { return }
        let now = Date()

        if history.keepFullLog {
            connectionLog.append(ConnectionLogEntry(entryID: entry.id, at: now, outcome: outcome))
            connectionLog = ConnectionHistory.trimmed(connectionLog, to: history.logLimit)
            scheduleHistorySave()
        }
        guard outcome == .connected else { return }
        recordConnection(entry)
    }

    func recordConnection(_ entry: SessionEntry) {
        // Opting a protected host out leaves it out of everything -- recents,
        // aggregate, and log -- rather than half-recording it.
        guard !(history.excludeProtectedHosts && entry.isProtected) else { return }

        let now = Date()
        recents.removeAll { $0.entryID == entry.id }
        recents.insert(RecentConnection(entryID: entry.id, date: now), at: 0)
        if recents.count > 20 {
            recents.removeLast(recents.count - 20)
        }

        connectionStats = ConnectionHistory.recording(
            entryID: entry.id, at: now, into: connectionStats
        )
        scheduleHistorySave()
        saveLocal()   // recents are this Mac's jump-back-in list
    }

    func updateHistorySettings(_ settings: HistorySettings) {
        let wasKeepingLog = history.keepFullLog
        let wasKeepingCommands = history.keepCommandHistory
        history = settings
        // Same contract as the connection log: opting out discards what was
        // already gathered, or opting out wouldn't mean much.
        // Both clears must happen BEFORE the write. Persisting first and
        // clearing after left the opted-out data on disk to be reloaded next
        // launch -- the deletion appeared to work and silently didn't.
        let stoppedLog = wasKeepingLog && !settings.keepFullLog
        let stoppedCommands = wasKeepingCommands && !settings.keepCommandHistory
        if stoppedCommands { commandHistory = [] }
        if stoppedLog { connectionLog = [] }
        if stoppedLog || stoppedCommands { flushHistory() }
        save()
    }

    /// Clears history. Aggregate, log and commands go together -- "clear
    /// history" that left per-host counts or recorded command lines behind
    /// would not be believed, and shouldn't be.
    func clearHistory() {
        connectionStats = []
        connectionLog = []
        commandHistory = []
        recents = []
        flushHistory()
        saveLocal()
    }

    /// Records a command the shell reported. Honours the same protected-host
    /// exclusion as connection history: opting a host out has to mean out of
    /// everything, or the setting is worthless.
    /// Reads the history file, falling back to whatever the library still
    /// carries from before history moved out — then writes the sidecar and
    /// leaves the library to drop the old keys on its next save.
    /// Reads the local sidecar, falling back to whatever the library still
    /// carries from before local state moved out.
    ///
    /// Deliberately gentler than the library's load. An unreadable local file
    /// is preserved and then ignored: it holds a window layout and a font
    /// size, so refusing to start — or refusing to save — over it would cost
    /// far more than it protects. The library gets quarantined; this gets a
    /// shrug and a log line.
    private func loadLocal(migratingFrom doc: Document?) {
        if let data = try? Data(contentsOf: localFileURL) {
            do {
                let local = try JSONDecoder().decode(LocalDocument.self, from: data)
                workspace = local.workspace ?? WorkspaceSnapshot()
                appearance = local.appearance ?? .default
                customThemes = local.customThemes ?? []
                terminal = local.terminal ?? TerminalSettings()
                logging = local.logging ?? LoggingSettings()
                recents = local.recents ?? []
                return
            } catch {
                let backup = localFileURL.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: backup, options: .atomic)
                NSLog("Portside: local state at \(localFileURL.path) could not be read — preserved at \(backup.path)")
            }
        }
        // No sidecar (or an unreadable one): take what the library has. On a
        // first upgrade that is the real state; on a fresh library it is
        // defaults, which is also right.
        workspace = doc?.workspace ?? WorkspaceSnapshot()
        appearance = doc?.appearance ?? .default
        customThemes = doc?.customThemes ?? []
        terminal = doc?.terminal ?? TerminalSettings()
        logging = doc?.logging ?? LoggingSettings()
        recents = doc?.recents ?? []

        let hadLegacyLocal = doc?.workspace != nil || doc?.appearance != nil
            || doc?.customThemes != nil || doc?.terminal != nil
            || doc?.logging != nil || doc?.recents != nil
        if hadLegacyLocal {
            // Keep the pre-migration library, once, before anything is stripped.
            //
            // The migration is one-way and runs unattended on first launch, so
            // this is the restore point if it turns out to be wrong — and the
            // one a *downgrade* needs, which is the case that isn't obvious:
            // an older Portside doesn't know about fields added since, so
            // opening this library on one and letting it save would drop them
            // silently. A copy taken before the change is the only thing that
            // makes going back safe.
            preserveLibraryBeforeMigrating()
            // Sidecar first, library second. If anything fails between them the
            // library still holds the originals, so the worst case is that the
            // migration runs again — never that the state is gone from both.
            saveLocal()
            needsLegacyLocalCleanup = true
        }
    }

    /// Where the library was copied before the local split migrated it, if it
    /// was. Nil on a library that never needed migrating.
    private(set) var preMigrationLibraryPath: String?

    /// Copies the library aside before the split rewrites it.
    ///
    /// Never overwrites an existing copy: if a first attempt migrated and
    /// something later went wrong, the file worth keeping is the one from
    /// *before* the first attempt, not from before the third.
    private func preserveLibraryBeforeMigrating() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let backup = fileURL.deletingPathExtension()
            .appendingPathExtension("pre-local-split.json")
        guard !FileManager.default.fileExists(atPath: backup.path) else {
            preMigrationLibraryPath = backup.path
            return
        }
        do {
            try FileManager.default.copyItem(at: fileURL, to: backup)
            preMigrationLibraryPath = backup.path
            NSLog("Portside: library copied to \(backup.path) before the local-state split")
        } catch {
            NSLog("Portside: could not preserve the pre-split library — \(error)")
        }
    }

    private func saveLocal() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(LocalDocument(
                workspace: workspace, appearance: appearance, customThemes: customThemes,
                terminal: terminal, logging: logging, recents: recents
            )).write(to: localFileURL, options: .atomic)
        } catch {
            NSLog("Portside: could not save local state — \(error)")
        }
    }

    private func loadHistory(migratingFrom doc: Document) {
        if let data = try? Data(contentsOf: historyFileURL) {
            do {
                let history = try JSONDecoder().decode(HistoryDocument.self, from: data)
                connectionStats = history.connectionStats ?? []
                connectionLog = history.connectionLog ?? []
                commandHistory = history.commandHistory ?? []
                return
            } catch {
                // Same rule as the library: an unreadable file is preserved
                // rather than quietly replaced by whatever we fall back to.
                // History is less precious than the library, so this doesn't
                // block the app — but it doesn't get silently destroyed either.
                let backup = historyFileURL.deletingPathExtension()
                    .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? data.write(to: backup, options: .atomic)
                NSLog("Portside: history at \(historyFileURL.path) could not be read — preserved at \(backup.path)")
                connectionStats = []
                connectionLog = []
                commandHistory = []
                seedStatsFromRecentsIfNeeded()
                return
            }
        }
        connectionStats = doc.connectionStats ?? []
        connectionLog = doc.connectionLog ?? []
        commandHistory = doc.commandHistory ?? []
        seedStatsFromRecentsIfNeeded()
        let hadLegacyHistory = !(connectionStats.isEmpty && connectionLog.isEmpty && commandHistory.isEmpty)
        if hadLegacyHistory {
            flushHistory()
            // Deliberately NOT save() here. This runs part-way through load(),
            // before workspace/keyBindings/credentialProfiles/defaultProfileID
            // have been read out of the document -- saving now would write
            // their empty defaults over the real ones, losing a user's
            // credential profiles on the first launch after upgrading.
            needsLegacyHistoryCleanup = true
        }
    }

    /// Upgrading users arrive with up to 20 recents and no aggregate stats.
    /// Without seeding, their first new connection creates the only stat, and
    /// Quick Connect -- which prefers ranked stats once any exist -- would show
    /// that single host and drop everything else they'd been using.
    ///
    /// Each recent seeds one connection at its recorded time, which is exactly
    /// what's known: it happened once, then.
    private func seedStatsFromRecentsIfNeeded() {
        guard connectionStats.isEmpty, !recents.isEmpty else { return }
        for recent in recents {
            connectionStats = ConnectionHistory.recording(
                entryID: recent.entryID, at: recent.date, into: connectionStats
            )
        }
    }

    /// How long a burst of history events is allowed to accumulate before the
    /// file is rewritten.
    ///
    /// Every write re-encodes the whole document — stats, log, and up to
    /// `commandLimit` (5,000) command events — then atomically replaces the
    /// file. That was happening once *per recorded command*, so a MultiExec
    /// grid with shell integration on turned one broadcast into one full
    /// rewrite per included pane.
    private static let historySaveWindow: TimeInterval = 0.75
    private var pendingHistorySave: DispatchWorkItem?
    private let coalescesHistoryWrites: Bool

    /// Coalesces high-churn history writes (commands, connections).
    ///
    /// A fixed window, deliberately not a trailing-edge debounce. Cancelling
    /// and rearming on every event reads as "write once the burst stops", but
    /// a stream of events spaced closer than the window postpones the write
    /// indefinitely — precisely under sustained activity, which is when
    /// unwritten history is worth the most. The first event opens the window
    /// and later ones join it, so the write lands a bounded
    /// `historySaveWindow` after the first unsaved event no matter how long
    /// the stream runs. It encodes live state when it fires, so joining the
    /// window costs nothing.
    ///
    /// The bound is therefore real: killing the app loses at most this much
    /// history, and every ordinary exit path flushes.
    private func scheduleHistorySave() {
        guard coalescesHistoryWrites else { return writeHistory() }
        guard pendingHistorySave == nil else { return }   // window already open
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHistorySave = nil
            self.writeHistory()
        }
        pendingHistorySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.historySaveWindow, execute: work)
    }

    /// Writes now, dropping any coalesced write still in flight.
    ///
    /// Used by the paths where the *point* is durability — clearing history,
    /// and opting out of the log or command capture. A pending save holding
    /// pre-clear data must not be allowed to land afterwards and resurrect it.
    func flushHistory() {
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        writeHistory()
    }

    private func writeHistory() {
        do {
            let encoder = JSONEncoder()
            // Not pretty-printed: this file is machine-written on every
            // command and read back by the app, and the indentation was a
            // large multiple on the bytes rewritten each time. `sortedKeys`
            // stays — stable key order keeps diffs and backups sane.
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(HistoryDocument(
                connectionStats: connectionStats,
                connectionLog: connectionLog,
                commandHistory: commandHistory
            )).write(to: historyFileURL, options: .atomic)
        } catch {
            NSLog("Portside: could not save history — \(error)")
        }
    }

    func recordCommand(_ event: CommandEvent) {
        guard history.keepCommandHistory else { return }
        if history.excludeProtectedHosts,
           let id = event.entryID, entry(id: id)?.isProtected == true {
            return
        }
        commandHistory.append(event)
        if commandHistory.count > history.commandLimit {
            commandHistory.removeFirst(commandHistory.count - history.commandLimit)
        }
        scheduleHistorySave()
    }

    func commands(forEntry entryID: UUID? = nil, limit: Int = 500) -> [CommandEvent] {
        let scoped = entryID.map { id in commandHistory.filter { $0.entryID == id } } ?? commandHistory
        return Array(scoped.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// Hosts ordered by frecency, joined against the library so deleted ones
    /// drop out.
    func frecentEntries(limit: Int, now: Date = Date()) -> [SessionEntry] {
        var result: [SessionEntry] = []
        for id in ConnectionHistory.ranked(connectionStats, now: now) {
            guard let entry = entry(id: id) else { continue }
            result.append(resolved(entry))
            if result.count == limit { break }
        }
        return result
    }

    func stat(for entryID: UUID) -> ConnectionStat? {
        connectionStats.first { $0.entryID == entryID }
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
        saveLocal()
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
        saveLocal()
        return theme
    }

    func updateDefaults(_ defaults: ConnectionDefaults) {
        self.defaults = defaults
        save()
    }

    func updateLogging(_ logging: LoggingSettings) {
        self.logging = logging
        saveLocal()
    }

    func updateTerminal(_ terminal: TerminalSettings) {
        self.terminal = terminal
        saveLocal()
    }

    func updateKeyBindings(_ keyBindings: KeyBindings) {
        self.keyBindings = keyBindings
        save()
    }

    /// Records the open session layout for restore-on-launch. No-op when the
    /// snapshot is unchanged so churning tabs don't rewrite disk needlessly.
    ///
    /// Writes the local sidecar, not the library. This is the change the split
    /// exists for: every tab opened, closed, split or selected used to rewrite
    /// the entire host library — every host, folder, macro, group and profile —
    /// to record which tabs were open.
    func saveWorkspace(_ snapshot: WorkspaceSnapshot) {
        guard snapshot != workspace else { return }
        workspace = snapshot
        saveLocal()
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

    /// Merges a Portside export. Entries get fresh ids, standalone folders
    /// merge by path, and macros dedupe by name. Returns what was added.
    ///
    /// Credential profile definitions are merged *first*, deliberately: the
    /// per-entry credential policy decides what an imported host may
    /// authenticate with by asking whether its profile resolves locally, so a
    /// profile arriving in the same file has to already be present by the time
    /// the entries are walked. Merging them afterwards would clear every
    /// reference and then restore the profiles they pointed at — the exact
    /// failure this phase exists to fix.
    @discardableResult
    func importExport(entries importedEntries: [SessionEntry],
                      folders importedFolders: [String],
                      macros importedMacros: [Macro],
                      credentialProfiles importedProfiles: [CredentialProfile] = [])
        -> (sessions: Int, macros: Int, profiles: Int)
    {
        let (addedProfiles, profileRemapping) = mergeImportedProfiles(importedProfiles)

        for folder in importedFolders {
            let clean = normalize(folder)
            if !clean.isEmpty, !explicitFolders.contains(clean) {
                explicitFolders.append(clean)
            }
        }

        // The key set grows as the batch is consumed. Snapshotting it only
        // against the *existing* library deduped imports against what was
        // already here but not against themselves, so a file listing the same
        // host twice added it twice.
        var knownKeys = Set(entries.map { importKey(for: $0) })
        var addedSessions = 0
        for var entry in importedEntries {
            guard knownKeys.insert(importKey(for: entry)).inserted else { continue }
            entry.id = UUID()
            if let old = entry.credentialProfileID, let new = profileRemapping[old] {
                entry.credentialProfileID = new
            }
            applyImportedCredentialPolicy(to: &entry)
            entries.append(entry)
            addedSessions += 1
        }

        var knownMacroNames = Set(macros.map(\.name))
        var addedMacros = 0
        for macro in importedMacros {
            guard knownMacroNames.insert(macro.name).inserted else { continue }
            var copy = macro
            copy.id = UUID()
            macros.append(copy)
            addedMacros += 1
        }

        save()
        return (addedSessions, addedMacros, addedProfiles)
    }

    /// Merges incoming profile definitions, returning how many were added and
    /// any id remapping imported entries need to follow.
    ///
    /// Three cases, and the middle one is the reason this returns a mapping:
    ///
    /// - **Same id already here.** Keep the local profile untouched. It may
    ///   hold a Keychain secret the incoming definition can't carry, so
    ///   overwriting it with the same fields minus the password would be a
    ///   pure loss.
    /// - **Same name, different id.** The library was rebuilt by hand on this
    ///   Mac — "Ops" exists, just not as the same record. Adding a second
    ///   "Ops" gives two identical-looking profiles where only one holds the
    ///   password, which is worse than either merging or refusing. Point the
    ///   imported entries at the local one instead; the name is a deliberate
    ///   user choice and the strongest signal available that these are meant
    ///   to be the same credential.
    /// - **Neither.** Genuinely new — take it, id and all, so a future import
    ///   from the same source lines up on the first case rather than drifting.
    private func mergeImportedProfiles(
        _ imported: [CredentialProfile]
    ) -> (added: Int, remapping: [UUID: UUID]) {
        var remapping: [UUID: UUID] = [:]
        var added = 0
        for profile in imported {
            if credentialProfiles.contains(where: { $0.id == profile.id }) { continue }
            if let local = credentialProfiles.first(where: { $0.name.matchesProfileName(profile.name) }) {
                remapping[profile.id] = local.id
                continue
            }
            credentialProfiles.append(profile)
            added += 1
        }
        return (added, remapping)
    }

    /// Adds imported entries, skipping exact duplicates (name + host + folder)
    /// both against the library and within the incoming batch itself.
    @discardableResult
    func addImported(entries newEntries: [SessionEntry], macros newMacros: [Macro]) -> (sessions: Int, macros: Int) {
        var knownKeys = Set(entries.map { importKey(for: $0) })
        let fresh = newEntries.filter { knownKeys.insert(importKey(for: $0)).inserted }
        entries.append(contentsOf: fresh)

        var knownMacroNames = Set(macros.map(\.name))
        let freshMacros = newMacros.filter { knownMacroNames.insert($0.name).inserted }
        macros.append(contentsOf: freshMacros)

        if !fresh.isEmpty || !freshMacros.isEmpty { save() }
        return (fresh.count, freshMacros.count)
    }

    /// Identity for import dedup: two entries naming the same host, under the
    /// same name, in the same folder are the same session.
    ///
    /// A struct rather than a joined string because folder and name are free
    /// text: any separator character can appear inside them, so `a|b` + `c`
    /// and `a` + `b|c` would collide and silently skip a distinct session.
    private struct ImportKey: Hashable {
        let folder: String
        let name: String
        let hostname: String
    }

    private func importKey(for entry: SessionEntry) -> ImportKey {
        ImportKey(folder: entry.folder, name: entry.name, hostname: entry.hostname)
    }

    /// Decides what an imported entry may authenticate with.
    ///
    /// The two credential sources are keyed differently, and that's the whole
    /// rule. A host-specific password is keyed by the entry's id — import
    /// assigns a *fresh* id, so no such password can exist here and claiming
    /// one would be a lie. A profile password is keyed by the profile, which
    /// lives in this library: if the profile resolves locally, its secret is
    /// genuinely available and the reference is worth keeping.
    ///
    /// So a resolvable profile keeps its id and switches `savePassword` on,
    /// which is what makes restoring your own backup actually authenticate
    /// rather than merely look right. Anything else clears the id and turns
    /// saved-password use off, so an import can neither carry a dangling
    /// reference nor quietly inherit this machine's default profile.
    ///
    /// Forcing the flag on normalises rather than overrides. "Profile
    /// assigned, saved passwords off" is not a state the app can reach —
    /// `applyCredentialProfile` and the editor's profile binding both set the
    /// flag on assignment, and the editor hides the toggle entirely while a
    /// profile is assigned. It's reachable only by hand-editing the JSON, and
    /// carrying it through would be actively misleading: the editor reports
    /// "password is set by the X profile" whenever a profile resolves, while
    /// the resolver would return nothing.
    private func applyImportedCredentialPolicy(to entry: inout SessionEntry) {
        guard let id = entry.credentialProfileID,
              credentialProfiles.contains(where: { $0.id == id }) else {
            entry.credentialProfileID = nil
            entry.savePassword = false
            return
        }
        entry.savePassword = true
    }

    // MARK: - Persistence

    /// Set when the library existed but could not be decoded. Saving is
    /// suppressed while true, so a bad read can never become a bad write.
    private(set) var loadFailure: String?
    /// Where the unreadable library was preserved.
    private(set) var quarantinedLibraryPath: String?

    private func load() {
        knownModificationDate = currentModificationDate
        let existingData = try? Data(contentsOf: fileURL)
        if let existingData {
            do {
                let doc = try JSONDecoder().decode(Document.self, from: existingData)
                apply(doc)
                if seedsFromSSHConfig { migrateLegacyDefault() }
                return
            } catch {
                // A library that exists but won't decode is NOT a first launch.
                // Treating it as one reseeded from ~/.ssh/config and saved over
                // the top, destroying a library that a schema bug, a bad hand
                // edit, or a newer build might otherwise have recovered.
                quarantine(existingData, error: error)
                // The library is unreadable; the local sidecar probably isn't,
                // and a broken host list is no reason to lose the window
                // layout and font size too.
                loadLocal(migratingFrom: nil)
                return
            }
        }
        // No library yet — a first run, or a library still to be created.
        // The sidecar stands on its own and may already exist.
        loadLocal(migratingFrom: nil)
        loadFresh()
        if seedsFromSSHConfig { migrateLegacyDefault() }
    }

    /// Copies the undecodable library aside and refuses to write until the user
    /// decides what to do. Nothing is lost, and nothing is overwritten.
    private func quarantine(_ data: Data, error: Error) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let suffix = stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingPathExtension()
            .appendingPathExtension("unreadable-\(suffix).json")
        try? data.write(to: backup, options: .atomic)

        quarantinedLibraryPath = backup.path
        loadFailure = "\(error)"
        NSLog("Portside: library at \(fileURL.path) could not be read — preserved at \(backup.path)")
    }

    private func loadFresh() {
        if seedsFromSSHConfig {
            entries = SSHConfigImporter.importEntries()
            save()
        }
    }

    private func apply(_ doc: Document) {
            entries = doc.entries
            macros = doc.macros
            groups = doc.groups?.elements ?? []
            forwards = doc.forwards ?? []
            recents = doc.recents ?? []
            explicitFolders = doc.explicitFolders ?? []
            defaults = doc.defaults ?? ConnectionDefaults()
            history = doc.history ?? HistorySettings()
            // Local before history, deliberately: `recents` lives in the
            // local sidecar now, and history seeds the aggregate stats from it
            // on upgrade. The other order silently seeded from an empty list.
            loadLocal(migratingFrom: doc)
            loadHistory(migratingFrom: doc)
            keyBindings = doc.keyBindings ?? KeyBindings()
            credentialProfiles = doc.credentialProfiles ?? []
            defaultProfileID = doc.defaultProfileID
            // Both cleanups rewrite the library, and only after everything
            // above has been read out of the document — rewriting mid-load
            // would persist the fields not yet applied as their empty defaults.
            if needsLegacyHistoryCleanup || needsLegacyLocalCleanup {
                needsLegacyHistoryCleanup = false
                needsLegacyLocalCleanup = false
                save()
            }
    }

    /// The library file's modification date as of the last read or write we
    /// did. Anything else on disk means someone changed the file underneath us.
    private var knownModificationDate: Date?

    /// Set when the file on disk changed outside this app since we last read
    /// or wrote it, so saving would silently discard whatever that change was.
    /// Cleared by `reloadAfterExternalChange()` or `overwriteExternalChange()`.
    @Published private(set) var externalChange: Bool = false

    private var currentModificationDate: Date? {
        try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    private func save() {
        // A library we couldn't read must never be written over by the empty
        // state that failure left us in.
        guard loadFailure == nil else {
            NSLog("Portside: refusing to save over an unreadable library")
            return
        }
        // The same principle, one case further along. `save()` writes the whole
        // library, so if the file changed since we read it — another Portside,
        // a sync client bringing down a copy edited on a second Mac, a hand
        // edit — writing now discards that change with no trace. It matters
        // more now that PORTSIDE_LIBRARY_DIR can point the library at a synced
        // folder, where two machines really can hold it open at once.
        //
        //     a bad read can never become a bad write
        //   → a stale read can never become a clobbering write
        //
        // Deliberately compares against the date of *our* last read or write
        // rather than a timestamp of when we started: our own atomic writes
        // replace the file and move the date forward every time, so anything
        // else would refuse to save after the first one.
        if let known = knownModificationDate, let onDisk = currentModificationDate,
           onDisk != known {
            if !externalChange {
                NSLog("Portside: library changed on disk since it was read — not saving over it")
            }
            externalChange = true
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Local state and history are deliberately nil here. They still
            // exist on `Document` so a library written before the split can be
            // read and migrated, but writing them back would put the file
            // straight back to mixing three lifetimes — and would undo the
            // migration on the next save.
            try encoder.encode(Document(entries: entries, macros: macros, groups: LenientArray(groups),
                                        forwards: forwards,
                                        recents: nil,
                                        explicitFolders: explicitFolders, appearance: nil,
                                        customThemes: nil, defaults: defaults, logging: nil,
                                        terminal: nil, workspace: nil, keyBindings: keyBindings,
                                        credentialProfiles: credentialProfiles, defaultProfileID: defaultProfileID,
                                        connectionStats: nil, connectionLog: nil,
                                        history: history))
                .write(to: fileURL, options: .atomic)
            // Our own write moved the date on; adopt it so the next save
            // compares against this one rather than refusing.
            knownModificationDate = currentModificationDate
        } catch {
            NSLog("Portside: failed to save library: \(error)")
        }
    }

    /// Takes the on-disk copy, discarding whatever is in memory.
    ///
    /// The safe answer to an external change: their edit is on disk and ours
    /// is not, so re-reading loses the least. Everything in memory that
    /// matters has already been saved — the conflict only blocks writes made
    /// *after* the file moved.
    func reloadAfterExternalChange() {
        externalChange = false
        knownModificationDate = currentModificationDate
        load()
    }

    /// Writes over the newer file on disk, on purpose.
    ///
    /// Offered because refusing forever is its own failure mode — a stale
    /// timestamp from a sync client that never settles would otherwise leave
    /// the library permanently read-only.
    func overwriteExternalChange() {
        externalChange = false
        knownModificationDate = currentModificationDate
        save()
    }
}
