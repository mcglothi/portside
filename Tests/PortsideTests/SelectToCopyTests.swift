import XCTest
import AppKit
import SwiftTerm
@testable import Portside

/// Settings › Terminal › Copy & Paste: the select-to-copy, right-click-to-paste
/// option. SwiftTerm's `copy(_:)` always writes the system clipboard, so the
/// tests that copy snapshot it first and put it back exactly as it was.
@MainActor
final class SelectToCopyTests: XCTestCase {
    private struct Snapshot {
        let items: [[(NSPasteboard.PasteboardType, Data)]]
        init(_ board: NSPasteboard) {
            items = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        func restore(to board: NSPasteboard) {
            board.clearContents()
            let restored = items.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { board.writeObjects(restored) }
        }
    }

    override func tearDown() async throws {
        LoggingTerminalView.clipboardStyle = .mac
    }

    private func view() -> LoggingTerminalView {
        let view = LoggingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.transportWriter = { _ in }
        return view
    }

    private func rightClick(_ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: modifiers,
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    // MARK: Setting

    func testDefaultsToMacStyle() {
        XCTAssertEqual(TerminalSettings().clipboardStyle, .mac)
    }

    func testOlderLibraryWithoutTheFieldLoadsAsMac() throws {
        let t = try JSONDecoder().decode(TerminalSettings.self, from: Data(#"{"scrollbackLines":5000}"#.utf8))
        XCTAssertEqual(t.clipboardStyle, .mac)
        XCTAssertEqual(t.scrollbackLines, 5000)
    }

    func testUnknownValueFromANewerBuildFallsBackWithoutFailingTheLoad() throws {
        let t = try JSONDecoder().decode(TerminalSettings.self,
                                         from: Data(#"{"scrollbackLines":5000,"clipboardStyle":"middleClick"}"#.utf8))
        XCTAssertEqual(t.clipboardStyle, .mac)
        XCTAssertEqual(t.scrollbackLines, 5000)
    }

    func testSelectToCopyRoundTrips() throws {
        var t = TerminalSettings()
        t.clipboardStyle = .selectToCopy
        let back = try JSONDecoder().decode(TerminalSettings.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back.clipboardStyle, .selectToCopy)
    }

    // MARK: Right-click

    func testRightClickPastesOnlyInSelectToCopyWithoutOption() {
        XCTAssertFalse(LoggingTerminalView.rightClickPastes(style: .mac, modifiers: []))
        XCTAssertTrue(LoggingTerminalView.rightClickPastes(style: .selectToCopy, modifiers: []))
        XCTAssertFalse(LoggingTerminalView.rightClickPastes(style: .selectToCopy, modifiers: .option))
    }

    func testMacStyleRightClickStillOpensTheMenu() {
        let menu = view().menu(for: rightClick())
        XCTAssertEqual(menu?.items.map(\.title), ["Copy", "Paste"])
    }

    func testSelectToCopyRightClickPastesIntoTheSessionAndShowsNoMenu() {
        let before = Snapshot(.general)
        defer { before.restore(to: .general) }
        let marker = "pasted-\(UUID().uuidString.prefix(6))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(marker, forType: .string)
        LoggingTerminalView.clipboardStyle = .selectToCopy
        let view = view()
        final class Box { var bytes: [UInt8] = [] }
        let box = Box()
        view.transportWriter = { box.bytes += $0 }

        XCTAssertNil(view.menu(for: rightClick()))
        ClipboardPolicyTests.drainMain()
        XCTAssertTrue(String(decoding: box.bytes, as: UTF8.self).contains(marker),
                      "right-click didn't paste: \(String(decoding: box.bytes, as: UTF8.self).debugDescription)")
    }

    func testOptionRightClickInSelectToCopyStillOpensTheMenu() {
        LoggingTerminalView.clipboardStyle = .selectToCopy
        XCTAssertEqual(view().menu(for: rightClick(.option))?.items.map(\.title), ["Copy", "Paste"])
    }

    func testSelectToCopyRightClickGoesThroughThePasteGate() {
        let before = Snapshot(.general)
        defer { before.restore(to: .general) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("rm -rf /tmp/x", forType: .string)
        LoggingTerminalView.clipboardStyle = .selectToCopy
        final class Box { var bytes: [UInt8] = [] }
        let box = Box()
        let view = view()
        view.transportWriter = { box.bytes += $0 }
        view.shouldAllowPaste = { _ in false }

        XCTAssertNil(view.menu(for: rightClick()))
        ClipboardPolicyTests.drainMain()
        XCTAssertTrue(box.bytes.isEmpty, "a vetoed paste reached the session")
    }

    // MARK: Select to copy

    func testFinishingASelectionCopiesItInSelectToCopy() {
        let before = Snapshot(.general)
        defer { before.restore(to: .general) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("old", forType: .string)
        LoggingTerminalView.clipboardStyle = .selectToCopy
        let view = view()
        view.feed(text: "hello-select")
        view.selectAll(nil)

        XCTAssertTrue(view.copySelectionIfSelectToCopy())
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("hello-select") == true)
    }

    func testMacStyleSelectionLeavesTheClipboardAlone() {
        let before = Snapshot(.general)
        defer { before.restore(to: .general) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("old", forType: .string)
        let view = view()
        view.feed(text: "hello-select")
        view.selectAll(nil)

        XCTAssertFalse(view.copySelectionIfSelectToCopy())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "old")
    }

    func testNoSelectionCopiesNothing() {
        LoggingTerminalView.clipboardStyle = .selectToCopy
        XCTAssertFalse(view().copySelectionIfSelectToCopy())
    }
}
