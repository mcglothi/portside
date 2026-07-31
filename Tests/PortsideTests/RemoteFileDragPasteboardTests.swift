import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import Portside

/// The drag that carries a remote file between panes is an
/// `NSFilePromiseProvider` with an extra type bolted on. Getting that type
/// onto the pasteboard is what makes host-to-host copy possible at all, and
/// it failed twice during development in ways the UI hid completely: the drag
/// kept drawing a copy badge — the promise draws that, not us — while the
/// drop handler never ran at all.
///
/// So this asserts the pasteboard contract directly, at the seam where the
/// two halves of the feature actually meet.
final class RemoteFileDragPasteboardTests: XCTestCase {

    private func makeProvider() throws -> (RemoteFilePromiseProvider, SessionEntry) {
        let entry = SessionEntry(name: "dns2", hostname: "dns2.internal", kind: .host)
        let delegate = RemoteFilePromiseDelegate(
            entry: entry, remotePath: "/home/mcglothi/pihole-sync.sh",
            name: "pihole-sync.sh", size: 100
        )
        let provider = RemoteFilePromiseProvider(
            fileType: UTType.data.identifier, delegate: delegate
        )
        provider.payload = try JSONEncoder().encode(
            RemoteFileDragPayload(
                entryID: entry.id, remotePath: "/home/mcglothi/pihole-sync.sh",
                name: "pihole-sync.sh", size: 100
            )
        )
        return (provider, entry)
    }

    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("portside-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    /// The drop target reads the pasteboard directly (`data(forType:)`),
    /// because that is the only accessor that sees a lazily-written promise
    /// type — `NSPasteboardItem.types` and the `NSItemProvider` bridge both
    /// come back without it, which is why neither SwiftUI drop API could be
    /// used here. If this stops returning bytes, host-to-host copy is dead
    /// and nothing in the UI will say so.
    func testPayloadIsReadableFromThePasteboard() throws {
        let (provider, entry) = try makeProvider()
        let pb = pasteboard()
        pb.writeObjects([provider])

        let data = try XCTUnwrap(
            pb.data(forType: .portsideRemoteFile),
            "the payload never reached the pasteboard"
        )
        let decoded = try JSONDecoder().decode(RemoteFileDragPayload.self, from: data)
        XCTAssertEqual(decoded.entryID, entry.id)
        XCTAssertEqual(decoded.name, "pihole-sync.sh")
        XCTAssertEqual(decoded.remotePath, "/home/mcglothi/pihole-sync.sh")
    }

    func testCustomTypeIsAdvertisedAlongsideThePromiseTypes() throws {
        let (provider, _) = try makeProvider()
        let pb = pasteboard()
        let types = provider.writableTypes(for: pb)
        XCTAssertTrue(
            types.contains(.portsideRemoteFile),
            "custom type missing from writableTypes: \(types.map(\.rawValue))"
        )
        XCTAssertTrue(
            types.contains { $0.rawValue.contains("FilePromise") },
            "the ordinary file promise must survive so drops into Finder still work"
        )
    }

    /// A provider with no payload has to look exactly like a plain promise,
    /// or an external target could be offered a type carrying nothing.
    func testProviderWithoutAPayloadAdvertisesOnlyPromiseTypes() throws {
        let (provider, _) = try makeProvider()
        provider.payload = nil
        let pb = pasteboard()
        XCTAssertFalse(provider.writableTypes(for: pb).contains(.portsideRemoteFile))
    }

    /// The identifier lives in three places — this pasteboard type, the
    /// `UTType` extension, and `UTExportedTypeDeclarations` in
    /// `Scripts/make_app.sh`. The drop silently stops matching if they drift.
    func testPasteboardTypeMatchesTheDeclaredUTI() {
        XCTAssertEqual(
            NSPasteboard.PasteboardType.portsideRemoteFile.rawValue,
            "net.timmcg.portside.remote-file"
        )
    }
}
