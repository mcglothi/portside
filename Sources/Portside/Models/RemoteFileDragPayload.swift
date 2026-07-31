import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// Identifies a remote file being dragged *within* Portside.
    ///
    /// The drag already carries an `NSFilePromiseProvider` so it can be
    /// dropped into Finder. That promise is useless for a host-to-host copy —
    /// it only knows how to write bytes to a local URL — so the drag carries
    /// this alongside it: enough to name the source file without downloading
    /// anything, letting a pane decide whether it can accept the drop before
    /// a single byte moves.
    static let portsideRemoteFile = UTType(exportedAs: "net.timmcg.portside.remote-file")
}

/// The source side of a host-to-host copy, as it travels on the pasteboard.
///
/// Deliberately just identifiers: the entry is looked up in the store at drop
/// time rather than encoded here, so a drag cannot carry a stale copy of a
/// host's credentials or address across a config change mid-gesture.
struct RemoteFileDragPayload: Codable, Transferable, Equatable {
    let entryID: UUID
    let remotePath: String
    let name: String
    let size: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .portsideRemoteFile)
    }
}
