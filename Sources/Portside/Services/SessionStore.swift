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
    /// Team inventories subscribed to over git — see `InventorySource`.
    @Published private(set) var inventorySources: [InventorySource] = []
    /// The user's own settings on shared hosts, keyed by Portside entry id.
    @Published private(set) var sharedOverlays: [UUID: SharedOverlay] = [:]
    /// Each source's last-read contents and pull status, keyed by source id.
    @Published private(set) var sharedState: [UUID: SharedInventoryState] = [:]
    /// Every shared host as this user connects to it — overlays applied — in
    /// source order. Rebuilt whenever a source, its contents or an overlay
    /// changes, rather than computed per read: the sidebar, search and every
    /// `entry(id:)` lookup go through it.
    @Published private(set) var sharedEntries: [SessionEntry] = []
    /// Which source each shared host came from.
    private(set) var sharedSourceByEntry: [UUID: UUID] = [:]
    /// Local folders that publish to a source — see `PublishLink`.
    @Published private(set) var publishLinks: [PublishLink] = []

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
        var inventorySources: LenientArray<InventorySource>?
        var sharedOverlays: LenientArray<SharedOverlay>?
        var publishLinks: LenientArray<PublishLink>?
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
        usesDefaultLibraryLocation = (override == nil)
        load()
        observeTermination()
        purgeOrphanedCredentials()
    }

    /// Whether this store is the user's real library at its real location.
    ///
    /// Gates the Keychain sweep, and nothing else. The sweep deletes every
    /// password whose host it cannot see, so pointing it at a throwaway library
    /// would wipe the passwords for the user's actual hosts — and
    /// `PORTSIDE_LIBRARY_DIR` runs through the same initialiser as the real
    /// thing, so "which initialiser was called" is not the distinction that
    /// matters here.
    private let usesDefaultLibraryLocation: Bool

    /// Cleans up Keychain passwords left behind by a delete that was still
    /// undoable when the app went away.
    ///
    /// Two guards, both load-bearing. `usesDefaultLibraryLocation` keeps the
    /// sweep off throwaway libraries — a dev build under PORTSIDE_LIBRARY_DIR
    /// shares the one Keychain with the installed app, so sweeping there would
    /// delete the passwords for every real host, none of which it can see.
    /// `loadFailure` covers the same hazard from the other direction: a library
    /// that wouldn't decode has no host list to speak of, and sweeping against
    /// it is indistinguishable from sweeping against nothing.
    private func purgeOrphanedCredentials() {
        guard usesDefaultLibraryLocation, loadFailure == nil else { return }
        // Shared hosts count as live through their overlays: a saved password
        // needs one, and overlays persist even while a source is unreachable
        // or its manifest won't parse — when its hosts aren't loaded at all.
        CredentialStore.purgeOrphanedPasswords(
            keeping: Set(entries.map(\.id)).union(sharedOverlays.keys))
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
        self.usesDefaultLibraryLocation = false
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
            // The undo ring doesn't outlive the app, so neither should the
            // passwords it was keeping alive.
            self?.finalizePendingDeletions()
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
        if isShared(entry.id) {
            updateSharedOverlay(from: entry)
            return
        }
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
        delete(ids: [entry.id])
    }

    // MARK: - Undoing a delete

    /// Recent deletions, newest last. Published so the menu can name what it
    /// would bring back and disable itself when there is nothing to.
    @Published private(set) var deletedItems = DeletedItemRing()

    /// Files a deletion as undoable, and finishes off whatever that pushed out
    /// of the ring.
    ///
    /// This is where a deleted host's Keychain password actually goes. Removing
    /// it at delete time would mean undo restored a host that could no longer
    /// authenticate — it would look completely correct and then fail, which is
    /// worse than not offering undo at all. The alternative, stashing the
    /// plaintext to write back later, moves a secret out of the Keychain, so
    /// instead the item simply stays until the delete is beyond taking back.
    private func recordDeletion(_ batch: DeletedItems) {
        for expired in deletedItems.record(batch) {
            for host in expired.hosts { CredentialStore.deletePassword(for: host.id) }
        }
    }

    /// Puts back the most recent deletion. Returns what came back, for the
    /// caller to say so.
    @discardableResult
    func undoLastDelete() -> DeletedItems? {
        guard let batch = deletedItems.takeMostRecent() else { return nil }
        restore(batch)
        return batch
    }

    /// Puts back one specific deletion, for a menu listing several.
    @discardableResult
    func undoDelete(id: DeletedItems.ID) -> DeletedItems? {
        guard let batch = deletedItems.take(id: id) else { return nil }
        restore(batch)
        return batch
    }

    /// Restores a batch, re-creating any folder it referred to.
    ///
    /// The folders are the subtle part: deleting the last host in a folder can
    /// leave that folder with nothing to anchor it, so putting the host back
    /// without its folder would silently move it to the top level — an undo
    /// that doesn't undo. Skips anything whose id came back some other way
    /// (a re-import, a second window) rather than creating a duplicate.
    private func restore(_ batch: DeletedItems) {
        for host in batch.hosts where !entries.contains(where: { $0.id == host.id }) {
            entries.append(host)
            registerFolder(host.folder)
        }
        for group in batch.groups where !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
            registerFolder(group.folder)
        }
        for macro in batch.macros where !macros.contains(where: { $0.id == macro.id }) {
            macros.append(macro)
        }
        save()
    }

    private func registerFolder(_ path: String) {
        let clean = normalize(path)
        guard !clean.isEmpty, !explicitFolders.contains(clean) else { return }
        explicitFolders.append(clean)
    }

    /// Forgets every undoable delete, finishing each one off.
    ///
    /// The Keychain passwords go with them, which is the point rather than a
    /// side effect: this is the answer to "I deleted that host, get rid of its
    /// password now" instead of waiting for the ring to evict it. No
    /// confirmation — the deletes themselves were already asked for and
    /// confirmed, and this only stops offering to reverse them.
    func clearDeletedItems() {
        guard !deletedItems.isEmpty else { return }
        finalizePendingDeletions()
    }

    /// Finishes every deletion the ring was holding open. Called at quit: the
    /// ring doesn't survive a launch, so a password kept alive only by an undo
    /// that is no longer offered would be a leak.
    func finalizePendingDeletions() {
        for expired in deletedItems.drain() {
            for host in expired.hosts { CredentialStore.deletePassword(for: host.id) }
        }
    }

    /// Deletes every entry whose id is in `ids`, saving once. No-op (and no
    /// save) when nothing matches, so a stray empty selection can't churn disk.
    ///
    /// The Keychain passwords are *not* removed here — see `recordDeletion`.
    func delete(ids: Set<UUID>) {
        let removed = entries.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        recordDeletion(DeletedItems(hosts: removed))
        save()
    }

    /// Deletes hosts, groups and macros as one undoable action.
    ///
    /// A selection spanning kinds has to come back as one, so it has to go as
    /// one: two separate deletes would need two undos, and the second would
    /// restore half of something the user thinks they already took back.
    func delete(entryIDs: Set<UUID>, groupIDs: Set<UUID>, macroIDs: Set<UUID>) {
        let removedHosts = entries.filter { entryIDs.contains($0.id) }
        let removedGroups = groups.filter { groupIDs.contains($0.id) }
        let removedMacros = macros.filter { macroIDs.contains($0.id) }
        let batch = DeletedItems(hosts: removedHosts, groups: removedGroups, macros: removedMacros)
        guard !batch.isEmpty else { return }
        entries.removeAll { entryIDs.contains($0.id) }
        groups.removeAll { groupIDs.contains($0.id) }
        macros.removeAll { macroIDs.contains($0.id) }
        recordDeletion(batch)
        save()
    }

    /// Bulk-flips "Save password in Keychain" for every entry whose id is in
    /// `ids` — for imported libraries where most hosts should have it on but
    /// weren't created through the editor's per-host toggle. Only sets the
    /// flag; it doesn't (can't) invent an actual password for the Keychain —
    /// each host still needs its password entered once in the editor.
    func setSavePassword(_ on: Bool, ids: Set<UUID>) {
        var changed = updateOverlays(ids) { $0.savePassword = on }
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
        allEntries.filter(\.isFavorite)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Favorited groups, alphabetical — the welcome screen's Groups section.
    var favoriteGroups: [SessionGroup] {
        groups.filter(\.isFavorite)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func toggleFavorite(groupID: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].isFavorite.toggle()
        save()
    }

    func toggleFavorite(_ id: UUID) {
        if isShared(id) {
            updateOverlays([id]) { $0.isFavorite.toggle() }
            return
        }
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].isFavorite.toggle()
        save()
    }

    /// Bulk-sets favorite status across a multi-selection, mirroring
    /// `setSavePassword(_:ids:)`.
    /// Bulk environment tagging, for classifying a large imported inventory
    /// without editing hosts one at a time.
    func setEnvironment(_ environment: HostEnvironment, ids: Set<UUID>) {
        var changed = updateOverlays(ids) { $0.environment = environment }
        for i in entries.indices where ids.contains(entries[i].id) && entries[i].environment != environment {
            entries[i].environment = environment
            changed = true
        }
        guard changed else { return }
        save()
    }

    func setFavorite(_ on: Bool, ids: Set<UUID>) {
        var changed = updateOverlays(ids) { $0.isFavorite = on }
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
    ///
    /// Assigning used to flip `savePassword` on as well, purely because
    /// `CredentialResolver` gated every password behind that toggle and the
    /// profile would otherwise never be consulted. The resolver treats an
    /// assigned profile as its own consent now, so the flip is gone: the toggle
    /// means what it says — "use a password saved against this host" — and
    /// assigning a profile no longer silently opts a host into an unrelated
    /// credential it happens to have lying in the Keychain.
    func applyCredentialProfile(_ id: UUID?, to ids: Set<UUID>) {
        var changed = updateOverlays(ids) { $0.credentialProfileID = id }
        for i in entries.indices where ids.contains(entries[i].id) {
            if entries[i].credentialProfileID != id {
                entries[i].credentialProfileID = id
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
        // Copying a shared host into your own library isn't a duplicate — it
        // lands in a different tree, so it keeps its name.
        copy.name = isShared(entry.id) ? entry.name : entry.name + " copy"
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
        // The folder arrives as typed. Normalizing here means a stray "/prod/"
        // files under the same folder hosts use rather than a near-duplicate,
        // and registering it keeps the folder in the sidebar when the group is
        // the only thing in it.
        copy.folder = normalize(copy.folder)
        if !copy.folder.isEmpty, !explicitFolders.contains(copy.folder) {
            explicitFolders.append(copy.folder)
        }
        if let i = groups.firstIndex(where: { $0.id == group.id }) {
            groups[i] = copy
        } else {
            groups.append(copy)
        }
        save()
    }

    func delete(_ group: SessionGroup) {
        guard let removed = groups.first(where: { $0.id == group.id }) else { return }
        groups.removeAll { $0.id == group.id }
        recordDeletion(DeletedItems(groups: [removed]))
        save()
    }

    func group(id: UUID) -> SessionGroup? { groups.first { $0.id == id } }

    /// Files a group under `folder` — "" for the top level.
    ///
    /// `SessionGroup.folder` and the sidebar's folder rendering both existed
    /// from the start, but nothing could set it: the save sheet passed only a
    /// name and groups aren't draggable, so every group was stuck at the root
    /// however many you made.
    func move(groupID: UUID, toFolder folder: String) {
        move(groupIDs: [groupID], toFolder: folder)
    }

    /// Batch form, for a drag carrying more than one group — one write rather
    /// than one per group.
    func move(groupIDs ids: Set<UUID>, toFolder folder: String) {
        let clean = normalize(folder)
        var changed = false
        for i in groups.indices where ids.contains(groups[i].id) && groups[i].folder != clean {
            groups[i].folder = clean
            changed = true
        }
        guard changed else { return }
        if !clean.isEmpty, !explicitFolders.contains(clean) { explicitFolders.append(clean) }
        save()
    }

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

    /// How much a folder holds, including everything in its subfolders.
    ///
    /// Hosts *and* groups. The sidebar's folder badge answers "how much is in
    /// here", and counting only hosts meant a folder made to hold groups showed
    /// nothing at all — which reads as an empty folder rather than a folder the
    /// badge doesn't know about.
    ///
    /// Counts rather than reusing `entriesInFolder`, which resolves every host
    /// against its credential profile on the way out — real work, repeated for
    /// every folder row on every redraw, to produce a number.
    func itemCount(inFolder path: String) -> Int {
        if let shared = SharedFolderPath.parse(path) {
            return sharedEntries(inSource: shared.sourceID, folder: shared.folder).count
        }
        let prefix = path + "/"
        func isInside(_ folder: String) -> Bool { folder == path || folder.hasPrefix(prefix) }
        return entries.count(where: { isInside($0.folder) })
             + groups.count(where: { isInside($0.folder) })
    }

    /// Groups whose folder is `folder`, name-sorted for the sidebar.
    func groups(inFolder folder: String) -> [SessionGroup] {
        groups.filter { $0.folder == folder }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func delete(_ macro: Macro) {
        guard let removed = macros.first(where: { $0.id == macro.id }) else { return }
        macros.removeAll { $0.id == macro.id }
        recordDeletion(DeletedItems(macros: [removed]))
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
        return entries.first { $0.id == id } ?? sharedEntries.first { $0.id == id }
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
        if let shared = SharedFolderPath.parse(path) {
            return sharedEntries(inSource: shared.sourceID, folder: shared.folder)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(resolved)
        }
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
        let usesAlias = !(e.sshAlias?.isEmpty ?? true)

        if let assigned = credentialProfile(id: e.credentialProfileID) {
            if let u = assigned.user, !u.isEmpty, !usesAlias { e.user = u }
            if let key = assigned.identityFile, !key.isEmpty { e.identityFile = key }
        }
        // The default profile fills blanks — it never overrides, which is the
        // difference between "the profile this host uses" and "what to fall
        // back on". It supplied its *password* and nothing else until now, so a
        // host with no user of its own connected as the local account name and
        // had a perfectly correct password rejected. Skipped entirely for an
        // aliased host: `~/.ssh/config` owns that connection's user and key,
        // and `-i` from a library-wide default would override the config's
        // choice on every aliased host at once.
        if !usesAlias, let fallback = credentialProfile(id: defaultProfileID) {
            if e.user?.isEmpty ?? true, let u = fallback.user, !u.isEmpty { e.user = u }
            if e.identityFile?.isEmpty ?? true, let key = fallback.identityFile, !key.isEmpty {
                e.identityFile = key
            }
        }
        if (e.user?.isEmpty ?? true), !usesAlias, let u = defaults.user, !u.isEmpty {
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
        // Groups live in folders too. Without this a rename left them behind in
        // a path nothing else referenced, so the old folder stayed in the
        // sidebar containing only orphans.
        for i in groups.indices {
            if groups[i].folder == path {
                groups[i].folder = newPath
            } else if groups[i].folder.hasPrefix(prefix) {
                groups[i].folder = newPath + "/" + String(groups[i].folder.dropFirst(prefix.count))
            }
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
        for i in groups.indices where groups[i].folder == path || groups[i].folder.hasPrefix(prefix) {
            groups[i].folder = parent
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

    // MARK: - Shared inventory

    /// Your own hosts and every subscribed source's, for anything that should
    /// see both: search, Quick Connect, link matching, favourites.
    var allEntries: [SessionEntry] { entries + sharedEntries }

    func isShared(_ id: UUID) -> Bool { sharedSourceByEntry[id] != nil }

    func inventorySource(id: UUID?) -> InventorySource? {
        guard let id else { return nil }
        return inventorySources.first { $0.id == id }
    }

    /// The source a shared host came from, or nil for a host of your own.
    func inventorySource(forEntry id: UUID) -> InventorySource? {
        inventorySource(id: sharedSourceByEntry[id])
    }

    /// A shared host exactly as its source publishes it, before the overlay.
    func publishedEntry(id: UUID) -> SessionEntry? {
        guard let sourceID = sharedSourceByEntry[id] else { return nil }
        return sharedState[sourceID]?.entries.first { $0.id == id }
    }

    /// A source's hosts, optionally only those in `folder` and beneath it
    /// ("" is the whole source).
    func sharedEntries(inSource sourceID: UUID, folder: String = "") -> [SessionEntry] {
        let prefix = folder + "/"
        return sharedEntries.filter {
            sharedSourceByEntry[$0.id] == sourceID
                && (folder.isEmpty || $0.folder == folder || $0.folder.hasPrefix(prefix))
        }
    }

    /// Each source as a sidebar root, in subscription order.
    var sharedSidebarRoots: [FolderNode] {
        inventorySources.map { source in
            FolderTree.sourceNode(id: source.id, name: source.name,
                                  entries: sharedEntries(inSource: source.id),
                                  folders: sharedState[source.id]?.folders ?? [])
        }
    }

    /// The directory the library lives in — where its sidecars, the agent
    /// socket's settings and its audit log go too.
    var libraryDirectory: URL { fileURL.deletingLastPathComponent() }

    /// Where each source's clone lives — beside the library, so a throwaway
    /// `PORTSIDE_LIBRARY_DIR` or a test's temp file gets throwaway clones too.
    var sourcesDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("sources", isDirectory: true)
    }

    func cloneDirectory(for sourceID: UUID) -> URL {
        sourcesDirectory.appendingPathComponent(sourceID.uuidString, isDirectory: true)
    }

    /// Subscribes to a source. Returns why it can't be added, or nil.
    /// Doesn't pull; the caller does, so the UI can show the pull happening.
    @discardableResult
    func addInventorySource(_ source: InventorySource) -> String? {
        if let problem = source.validationProblem { return problem }
        var source = source
        source.name = source.name.trimmingCharacters(in: .whitespaces)
        source.remote = source.remote.trimmingCharacters(in: .whitespaces)
        inventorySources.append(source)
        sharedState[source.id] = SharedInventoryState()
        save()
        return nil
    }

    /// Edits a source. A new remote or branch means a new history, which a
    /// fast-forward can never reach, so the clone is discarded and the next
    /// pull starts fresh — a deliberate edit, unlike a force-push upstream.
    @discardableResult
    func updateInventorySource(_ source: InventorySource) -> String? {
        if let problem = source.validationProblem { return problem }
        guard let i = inventorySources.firstIndex(where: { $0.id == source.id }) else { return nil }
        let old = inventorySources[i]
        inventorySources[i] = source
        if old.remote != source.remote || old.ref != source.ref {
            try? FileManager.default.removeItem(at: cloneDirectory(for: source.id))
            sharedState[source.id] = SharedInventoryState()
        } else if old.path != source.path {
            loadShared(from: source)
        }
        rebuildShared()
        save()
        return nil
    }

    /// Unsubscribes: the source, its clone, and every overlay on its hosts.
    func removeInventorySource(id: UUID) {
        guard inventorySources.contains(where: { $0.id == id }) else { return }
        let hosts = Set(sharedState[id]?.entries.map(\.id) ?? [])
        for host in hosts where sharedOverlays[host]?.savePassword == true {
            CredentialStore.deletePassword(for: host)
        }
        sharedOverlays = sharedOverlays.filter { !hosts.contains($0.key) }
        inventorySources.removeAll { $0.id == id }
        sharedState[id] = nil
        publishLinks.removeAll { $0.sourceID == id }
        try? FileManager.default.removeItem(at: cloneDirectory(for: id))
        try? FileManager.default.removeItem(at: InventoryPublisher.directory(for: id, in: sourcesDirectory))
        try? FileManager.default.removeItem(at: baseURL(for: id))
        rebuildShared()
        save()
    }

    /// Pulls every source, one after another.
    @MainActor
    func refreshInventorySources() async {
        for source in inventorySources { await refreshInventorySource(id: source.id) }
    }

    /// Fetches, fast-forwards and re-reads one source. A failure keeps what
    /// was there and records why.
    @MainActor
    func refreshInventorySource(id: UUID) async {
        guard let source = inventorySource(id: id), sharedState[id]?.isSyncing != true else { return }
        sharedState[id, default: SharedInventoryState()].isSyncing = true
        let directory = cloneDirectory(for: id)
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> Swift.Result<(InventoryGit.Result, SharedManifest.Parsed), InventoryGit.Failure> in
            do {
                let pulled = try InventoryGit.sync(source, into: directory)
                let data = try InventoryGit.readManifest(source, in: directory)
                return .success((pulled, try SharedManifest.parse(data, sourceID: source.id)))
            } catch {
                return .failure(error as? InventoryGit.Failure
                                ?? InventoryGit.Failure(message: error.localizedDescription))
            }
        }.value
        // Removed while the pull was running: nothing to update.
        guard inventorySource(id: id) != nil else { return }
        var state = sharedState[id] ?? SharedInventoryState()
        state.isSyncing = false
        switch outcome {
        case .success(let (pulled, parsed)):
            state.entries = parsed.entries
            state.folders = parsed.folders
            state.skipped = parsed.skipped
            state.commit = pulled.commit
            state.lastSynced = Date()
            state.error = nil
        case .failure(let failure):
            state.error = failure.message
        }
        sharedState[id] = state
        rebuildShared()
    }

    /// Reads each source's manifest from its existing clone, with no network —
    /// so shared hosts are there at launch, offline included.
    private func loadSharedFromDisk() {
        sharedState = [:]
        for source in inventorySources { loadShared(from: source) }
        rebuildShared()
    }

    private func loadShared(from source: InventorySource) {
        var state = SharedInventoryState()
        let directory = cloneDirectory(for: source.id)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
            do {
                let parsed = try SharedManifest.parse(InventoryGit.readManifest(source, in: directory),
                                                      sourceID: source.id)
                state.entries = parsed.entries
                state.folders = parsed.folders
                state.skipped = parsed.skipped
            } catch {
                state.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        sharedState[source.id] = state
    }

    private func rebuildShared() {
        var byEntry: [UUID: UUID] = [:]
        var resolved: [SessionEntry] = []
        for source in inventorySources {
            for entry in sharedState[source.id]?.entries ?? [] where byEntry[entry.id] == nil {
                byEntry[entry.id] = source.id
                resolved.append(sharedOverlays[entry.id]?.applied(to: entry) ?? entry)
            }
        }
        sharedSourceByEntry = byEntry
        if resolved != sharedEntries { sharedEntries = resolved }
    }

    /// Applies `change` to the overlay of each *shared* host in `ids`, saving
    /// if anything moved. Your own hosts in the same selection are left to the
    /// caller, so a mixed selection works in one action.
    @discardableResult
    private func updateOverlays(_ ids: Set<UUID>, _ change: (inout SharedOverlay) -> Void) -> Bool {
        var changed = false
        for id in ids where isShared(id) {
            var overlay = sharedOverlays[id] ?? SharedOverlay(entryID: id)
            let before = overlay
            change(&overlay)
            guard overlay != before else { continue }
            sharedOverlays[id] = overlay.isEmpty ? nil : overlay
            changed = true
        }
        guard changed else { return false }
        rebuildShared()
        save()
        return true
    }

    /// An edited shared host, saved as far as it can be: the fields a user
    /// owns go into the overlay, and everything the source owns is ignored.
    private func updateSharedOverlay(from edited: SessionEntry) {
        guard let published = publishedEntry(id: edited.id) else { return }
        updateOverlays([edited.id]) { overlay in
            overlay.environment = edited.environment == published.environment ? nil : edited.environment
            // Only what the user adds: the source's protection isn't theirs to lift.
            overlay.isProtected = edited.isProtected && !published.isProtected
            overlay.isFavorite = edited.isFavorite
            overlay.credentialProfileID = edited.credentialProfileID
            overlay.savePassword = edited.savePassword
            let command = edited.runOnConnect?.trimmingCharacters(in: .whitespacesAndNewlines)
            overlay.runOnConnect = (command?.isEmpty ?? true) ? nil : edited.runOnConnect
            overlay.forwardAgent = edited.forwardAgent
            overlay.forwardX11 = edited.forwardX11
        }
    }

    // MARK: - Publishing

    func publishLink(forSource id: UUID) -> PublishLink? { publishLinks.first { $0.sourceID == id } }

    func publishLink(forFolder path: String) -> PublishLink? { publishLinks.first { $0.folder == path } }

    /// The merge base for a source: the team's manifest as of the last
    /// publish or link. Beside the clone rather than in the library — it is
    /// as large as the inventory and changes on every publish.
    private func baseURL(for sourceID: UUID) -> URL {
        sourcesDirectory.appendingPathComponent("\(sourceID.uuidString).base.json")
    }

    private func storedBase(for sourceID: UUID) -> SharedManifest.Parsed? {
        guard let data = try? Data(contentsOf: baseURL(for: sourceID)) else { return nil }
        return try? SharedManifest.parseKeepingIDs(data)
    }

    private func storeBase(_ hosts: [SessionEntry], folders: [String], for sourceID: UUID) {
        guard let data = try? LibraryTransfer.encodeSessions(entries: hosts, folders: folders,
                                                             credentialProfiles: []) else { return }
        try? FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try? data.write(to: baseURL(for: sourceID), options: .atomic)
    }

    func setDirectPush(_ on: Bool, forSource id: UUID) {
        guard let i = publishLinks.firstIndex(where: { $0.sourceID == id }) else { return }
        publishLinks[i].directPush = on
        save()
    }

    /// Stops publishing from a folder. The folder and its hosts stay.
    func unlinkPublishing(sourceID: UUID) {
        publishLinks.removeAll { $0.sourceID == sourceID }
        try? FileManager.default.removeItem(at: baseURL(for: sourceID))
        save()
    }

    /// A new shared inventory made from one of your folders: subscribes to the
    /// repository, links the folder, and publishes its first version. The
    /// repository may be empty; one that already holds an inventory is
    /// refused — link a folder to it instead, so nothing of the team's is
    /// overwritten.
    @MainActor
    func createSharedInventory(_ source: InventorySource, fromFolder folder: String)
        async -> Result<InventoryPublisher.Result, InventoryGit.Failure> {
        if let problem = source.validationProblem { return .failure(.init(message: problem)) }
        guard !folder.isEmpty else {
            return .failure(.init(message: "Choose a folder to publish; the top level can't be linked."))
        }
        if publishLink(forFolder: folder) != nil {
            return .failure(.init(message: "That folder already publishes to a shared inventory."))
        }
        let dir = InventoryPublisher.directory(for: source.id, in: sourcesDirectory)
        let existing = await Task.detached { () -> Result<Data?, InventoryGit.Failure> in
            do {
                try InventoryPublisher.fetch(source, into: dir)
                return .success(InventoryPublisher.remoteManifest(source, in: dir))
            } catch { return .failure(error as? InventoryGit.Failure ?? .init(message: "\(error)")) }
        }.value
        switch existing {
        case .failure(let failure): return .failure(failure)
        case .success(.some): return .failure(.init(message: "That repository already has an inventory at "
            + "\(source.path). Subscribe to it and use Link Folder for Publishing instead."))
        case .success(.none): break
        }
        guard addInventorySource(source) == nil else { return .failure(.init(message: "Couldn't add the source.")) }
        publishLinks.append(PublishLink(sourceID: source.id, folder: folder))
        save()
        let result: Result<InventoryPublisher.Result, InventoryGit.Failure>
        switch await planPublish(sourceID: source.id) {
        case .failure(let failure): result = .failure(failure)
        case .success(let plan): result = await publish(plan, message: "Create \(source.name) inventory")
        }
        if case .failure = result {
            // Don't leave a half-made source behind.
            removeInventorySource(id: source.id)
        }
        return result
    }

    /// Links a folder to an inventory someone else already publishes, so you
    /// can propose changes to it. The team's hosts are copied into the folder
    /// as your own editable hosts — that's what you edit — and their
    /// manifest ids are remembered so edits publish as changes, not new hosts.
    @MainActor
    func linkFolderForPublishing(sourceID: UUID, folder: String) async -> InventoryGit.Failure? {
        guard let source = inventorySource(id: sourceID) else { return .init(message: "No such source.") }
        if publishLink(forSource: sourceID) != nil { return .init(message: "That source already has a linked folder.") }
        let path = normalize(folder)
        guard !path.isEmpty else { return .init(message: "Choose a folder name.") }
        if itemCount(inFolder: path) > 0 {
            return .init(message: "Choose a new or empty folder; its contents would be published as additions.")
        }
        let dir = InventoryPublisher.directory(for: sourceID, in: sourcesDirectory)
        let fetched = await Task.detached { () -> Result<Data?, InventoryGit.Failure> in
            do {
                try InventoryPublisher.fetch(source, into: dir)
                return .success(InventoryPublisher.remoteManifest(source, in: dir))
            } catch { return .failure(error as? InventoryGit.Failure ?? .init(message: "\(error)")) }
        }.value
        let team: SharedManifest.Parsed
        switch fetched {
        case .failure(let failure): return failure
        case .success(let data):
            team = (try? data.map(SharedManifest.parseKeepingIDs)) ?? SharedManifest.Parsed(entries: [], folders: [], skipped: 0)
        }
        var link = PublishLink(sourceID: sourceID, folder: path)
        link.manifestIDs = adopt(team.entries, folders: team.folders, into: path, mapping: [:])
        publishLinks.append(link)
        storeBase(team.entries, folders: team.folders, for: sourceID)
        if !explicitFolders.contains(path) { explicitFolders.append(path) }
        save()
        return nil
    }

    /// Fetches the team's latest and lines it up against the folder.
    @MainActor
    func planPublish(sourceID: UUID) async -> Result<InventoryPublishing.Plan, InventoryGit.Failure> {
        guard let source = inventorySource(id: sourceID), let link = publishLink(forSource: sourceID) else {
            return .failure(.init(message: "That source has no linked folder."))
        }
        let dir = InventoryPublisher.directory(for: sourceID, in: sourcesDirectory)
        let fetched = await Task.detached { () -> Result<(Bool, Data?), InventoryGit.Failure> in
            do {
                let exists = try InventoryPublisher.fetch(source, into: dir)
                return .success((exists, InventoryPublisher.remoteManifest(source, in: dir)))
            } catch { return .failure(error as? InventoryGit.Failure ?? .init(message: "\(error)")) }
        }.value
        guard case .success(let (exists, data)) = fetched else {
            if case .failure(let f) = fetched { return .failure(f) }
            return .failure(.init(message: "Couldn't read the repository."))
        }
        let theirs = (try? data.map(SharedManifest.parseKeepingIDs))
            ?? SharedManifest.Parsed(entries: [], folders: [], skipped: 0)
        let base = storedBase(for: sourceID) ?? SharedManifest.Parsed(entries: [], folders: [], skipped: 0)
        let mine = InventoryPublishing.prepare(entries: entries, folders: folders, root: link.folder,
                                               manifestIDs: link.manifestIDs)
        return .success(InventoryPublishing.Plan(source: source, link: link,
                                                 base: base.entries, baseFolders: base.folders,
                                                 mine: mine, theirs: theirs.entries, theirFolders: theirs.folders,
                                                 remoteBranchExists: exists))
    }

    /// Sends a planned publish.
    ///
    /// Refuses with conflicts still unanswered or anything secret-looking in
    /// the folder. Afterwards the folder takes in the team's changes, and the
    /// base moves on: to what was pushed after a direct push; to the team's
    /// version it branched from after a review branch — so a change still
    /// waiting in review is never read, next time, as the team removing it.
    @MainActor
    func publish(_ plan: InventoryPublishing.Plan, resolutions: [UUID: InventoryPublishing.Side] = [:],
                 message: String) async -> Result<InventoryPublisher.Result, InventoryGit.Failure> {
        let merge = plan.merged(resolutions)
        let open = merge.conflicts.filter { resolutions[$0.id] == nil }
        guard open.isEmpty else {
            return .failure(.init(message: "Choose mine or theirs for \(open.map(\.name).joined(separator: ", ")) first."))
        }
        if let secret = plan.secrets.first {
            return .failure(.init(message: "Not published: \(secret.host) \u{2014} \(secret.text). Remove it and try again."))
        }
        guard let data = try? LibraryTransfer.encodeSessions(entries: merge.hosts, folders: merge.folders,
                                                             credentialProfiles: []) else {
            return .failure(.init(message: "Couldn't write the manifest."))
        }
        let source = plan.source
        let mode: InventoryPublisher.Mode = plan.link.directPush ? .direct : .branch
        let dir = InventoryPublisher.directory(for: source.id, in: sourcesDirectory)
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = InventoryPublisher.branchName()
        let outcome = await Task.detached { () -> Result<InventoryPublisher.Result, InventoryGit.Failure> in
            do {
                return .success(try InventoryPublisher.publish(source, manifest: data,
                                                               message: text.isEmpty ? "Update hosts" : text,
                                                               mode: mode, branchName: branch, in: dir))
            } catch { return .failure(error as? InventoryGit.Failure ?? .init(message: "\(error)")) }
        }.value
        guard case .success(let result) = outcome else { return outcome }

        let landedOnSourceBranch = result.branch == source.ref
        if landedOnSourceBranch {
            storeBase(merge.hosts, folders: merge.folders, for: source.id)
        } else {
            storeBase(plan.theirs, folders: plan.theirFolders, for: source.id)
        }
        if var link = publishLink(forSource: source.id) {
            link.manifestIDs = adopt(merge.hosts, folders: merge.folders, into: link.folder, mapping: link.manifestIDs)
            if let i = publishLinks.firstIndex(where: { $0.sourceID == source.id }) { publishLinks[i] = link }
        }
        save()
        await refreshInventorySource(id: source.id)
        return .success(result)
    }

    /// Makes the linked folder match `hosts` (manifest form): updates the
    /// published fields of hosts already there — leaving your personal
    /// settings on them alone — adds the team's new ones as your own hosts,
    /// and removes hosts the merge dropped. Removal goes through the undoable
    /// delete. Hosts the folder holds that can't be published (a serial port,
    /// say) aren't touched. Returns the updated local → manifest id map.
    private func adopt(_ hosts: [SessionEntry], folders newFolders: [String], into root: String,
                       mapping: [UUID: UUID]) -> [UUID: UUID] {
        var map = mapping
        func join(_ sub: String) -> String { sub.isEmpty ? root : root + "/" + sub }
        let published = InventoryPublishing.prepare(entries: entries, folders: [], root: root, manifestIDs: map)
        // Local id for each manifest id, from this folder's publishable hosts.
        var localFor: [UUID: UUID] = [:]
        let localByManifest = Dictionary(published.hosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in entries where e.folder == root || e.folder.hasPrefix(root + "/") {
            let manifestID = map[e.id] ?? e.id
            if localByManifest[manifestID] != nil { localFor[manifestID] = e.id }
        }
        let keep = Set(hosts.map(\.id))
        var removed: Set<UUID> = []
        for manifestID in localByManifest.keys where !keep.contains(manifestID) {
            if let local = localFor[manifestID] { removed.insert(local) }
        }
        for host in hosts {
            if let local = localFor[host.id], let i = entries.firstIndex(where: { $0.id == local }) {
                var e = entries[i]
                e.name = host.name
                e.folder = join(host.folder)
                e.hostname = host.hostname
                e.user = host.user
                e.port = host.port
                e.sshAlias = host.sshAlias
                e.identityFile = host.identityFile
                e.environment = host.environment
                e.isProtected = host.isProtected
                e.preferMosh = host.preferMosh
                e.keepAliveSeconds = host.keepAliveSeconds
                if e != entries[i] { entries[i] = e }
            } else {
                var e = host
                e.id = UUID()
                e.folder = join(host.folder)
                entries.append(e)
                map[e.id] = host.id
            }
        }
        if !removed.isEmpty {
            let gone = entries.filter { removed.contains($0.id) }
            entries.removeAll { removed.contains($0.id) }
            recordDeletion(DeletedItems(hosts: gone))
            for id in removed { map[id] = nil }
        }
        for f in newFolders.map(join) where !explicitFolders.contains(f) { explicitFolders.append(f) }
        return map
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
            inventorySources = doc.inventorySources?.elements ?? []
            sharedOverlays = Dictionary((doc.sharedOverlays?.elements ?? []).map { ($0.entryID, $0) },
                                        uniquingKeysWith: { first, _ in first })
            publishLinks = doc.publishLinks?.elements ?? []
            loadSharedFromDisk()
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
                                        history: history,
                                        inventorySources: LenientArray(inventorySources),
                                        sharedOverlays: LenientArray(sharedOverlays.values
                                            .sorted { $0.entryID.uuidString < $1.entryID.uuidString }),
                                        publishLinks: LenientArray(publishLinks)))
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
