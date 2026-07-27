import Foundation

/// Library actions that need to be invokable from more than one place: the
/// sidebar's toolbar menus, the menu bar, and (for the folder ones) a context
/// menu.
///
/// The actions themselves live in `SidebarView`, which owns the sheets, file
/// panels and alerts they drive — but the menu bar is built up in `PortsideApp`
/// and can't reach that state. Rather than reimplement each command in both
/// places and let them drift, every surface bumps a token here and the sidebar
/// performs it. One implementation, several entry points.
///
/// Tokens rather than booleans because these are *events*: "import again" has
/// to fire even though the last import already finished.
@MainActor
final class LibraryCommands: ObservableObject {
    @Published private(set) var newSession = 0
    @Published private(set) var newFolder = 0
    @Published private(set) var importFile = 0
    @Published private(set) var exportSessions = 0
    @Published private(set) var exportMacros = 0
    @Published private(set) var reimportSSHConfig = 0
    @Published private(set) var expandAllFolders = 0
    @Published private(set) var collapseAllFolders = 0
    @Published private(set) var showCoverage = 0
    @Published private(set) var showHistory = 0

    func requestNewSession() { newSession += 1 }
    func requestNewFolder() { newFolder += 1 }
    func requestImport() { importFile += 1 }
    func requestExportSessions() { exportSessions += 1 }
    func requestExportMacros() { exportMacros += 1 }
    func requestReimportSSHConfig() { reimportSSHConfig += 1 }
    func requestExpandAllFolders() { expandAllFolders += 1 }
    func requestCollapseAllFolders() { collapseAllFolders += 1 }
    func requestShowCoverage() { showCoverage += 1 }
    func requestShowHistory() { showHistory += 1 }
}
