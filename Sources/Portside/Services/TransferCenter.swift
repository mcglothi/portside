import Foundation

/// Every byte-moving operation in the SFTP pane, in one place: pane downloads
/// and uploads, plus drag-out-to-Finder, which runs detached from any view and
/// previously had nowhere to report. A transfer nobody can see or stop is the
/// difference between a mis-drag being an annoyance and being a 20-minute
/// mystery, so registration here is what makes it visible and cancellable.
@MainActor
final class TransferCenter: ObservableObject {
    static let shared = TransferCenter()

    struct Transfer: Identifiable {
        let id: UUID
        /// Which host's pane should show it.
        let entryID: UUID
        /// Remote path, used to spot a duplicate request for the same file.
        let remotePath: String
        var label: String
        var transferred: Int = 0
        /// 0 when the size isn't knowable (uploads), so the view shows a
        /// spinner rather than a bar frozen at 0%.
        var total: Int = 0

        var fraction: Double? {
            guard total > 0 else { return nil }
            return min(1, Double(transferred) / Double(total))
        }
    }

    @Published private(set) var transfers: [Transfer] = []

    /// Cancellation hooks kept beside the value type rather than inside it, so
    /// `Transfer` stays a plain struct the views can diff.
    private var cancels: [UUID: () -> Void] = [:]

    func transfers(for entryID: UUID) -> [Transfer] {
        transfers.filter { $0.entryID == entryID }
    }

    /// Transfers filed against any of `entryIDs`.
    ///
    /// A fan-out is filed under the host the file came *from*, and the only
    /// place transfers were ever rendered is inside the SFTP browser, filtered
    /// to whichever host that browser happens to be showing. Dropping onto
    /// another pane moves focus, which rebinds the browser to the
    /// destination — so a broadcast copy reported its progress somewhere
    /// nothing was looking.
    func transfers(forAny entryIDs: Set<UUID>) -> [Transfer] {
        transfers.filter { entryIDs.contains($0.entryID) }
    }

    /// True when this exact file is already being fetched for this host.
    /// Dragging the same 18GB model out twice should not start a second
    /// download competing with the first for the same pipe.
    func isTransferring(remotePath: String, entryID: UUID) -> Bool {
        transfers.contains { $0.remotePath == remotePath && $0.entryID == entryID }
    }

    @discardableResult
    func begin(
        entryID: UUID, remotePath: String, label: String, total: Int = 0,
        cancel: @escaping () -> Void
    ) -> UUID {
        let id = UUID()
        transfers.append(Transfer(
            id: id, entryID: entryID, remotePath: remotePath, label: label, total: total
        ))
        cancels[id] = cancel
        return id
    }

    func update(_ id: UUID, transferred: Int) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferred = transferred
    }

    /// Re-bases a transfer onto different units.
    ///
    /// A relay changes what it is counting partway through: bytes while the
    /// file comes down, then hosts while it goes out to a broadcast group.
    /// Without this the bar would keep the byte total and read as stuck at
    /// 100% for the whole second half.
    func rescale(_ id: UUID, transferred: Int, total: Int) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].transferred = transferred
        transfers[index].total = total
    }

    func relabel(_ id: UUID, _ label: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].label = label
    }

    func finish(_ id: UUID) {
        transfers.removeAll { $0.id == id }
        cancels[id] = nil
    }

    func cancel(_ id: UUID) {
        cancels[id]?()
        finish(id)
    }
}
