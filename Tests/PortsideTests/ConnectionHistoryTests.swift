import Foundation
import XCTest
@testable import Portside

final class ConnectionHistoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    // MARK: - Frecency

    func testFrequentHostOutranksOneTouchedOnceYesterday() {
        // The whole point: a host you hit constantly should beat a one-off,
        // even when the one-off is slightly more recent.
        let daily = ConnectionHistory.frecency(count: 50, lastConnected: daysAgo(2), now: now)
        let onceYesterday = ConnectionHistory.frecency(count: 1, lastConnected: daysAgo(1), now: now)
        XCTAssertGreaterThan(daily, onceYesterday)
    }

    func testRecencyStillBeatsAncientVolume() {
        // ...but volume shouldn't win forever, or the ranking never adapts.
        let ancient = ConnectionHistory.frecency(count: 50, lastConnected: daysAgo(365), now: now)
        let recent = ConnectionHistory.frecency(count: 3, lastConnected: daysAgo(0), now: now)
        XCTAssertGreaterThan(recent, ancient)
    }

    func testScoreHalvesEveryHalfLife() {
        let fresh = ConnectionHistory.frecency(count: 8, lastConnected: now, now: now, halfLifeDays: 7)
        let aWeekOld = ConnectionHistory.frecency(count: 8, lastConnected: daysAgo(7), now: now, halfLifeDays: 7)
        XCTAssertEqual(aWeekOld, fresh / 2, accuracy: 0.0001)
    }

    func testNeverConnectedScoresZeroAndIsUnranked() {
        XCTAssertEqual(ConnectionHistory.frecency(count: 0, lastConnected: now, now: now), 0)
        let stat = ConnectionStat(entryID: UUID(), count: 0, lastConnected: now)
        XCTAssertTrue(ConnectionHistory.ranked([stat], now: now).isEmpty)
    }

    func testRankedOrdersStrongestFirst() {
        let a = ConnectionStat(entryID: UUID(), count: 1, lastConnected: daysAgo(30))
        let b = ConnectionStat(entryID: UUID(), count: 40, lastConnected: daysAgo(1))
        let c = ConnectionStat(entryID: UUID(), count: 5, lastConnected: daysAgo(1))
        XCTAssertEqual(
            ConnectionHistory.ranked([a, b, c], now: now),
            [b.entryID, c.entryID, a.entryID]
        )
    }

    // MARK: - Recording

    func testFirstConnectionCreatesAStat() {
        let id = UUID()
        let stats = ConnectionHistory.recording(entryID: id, at: now, into: [])
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].count, 1)
        XCTAssertEqual(stats[0].lastConnected, now)
    }

    func testRepeatConnectionsAccumulate() {
        let id = UUID()
        var stats = ConnectionHistory.recording(entryID: id, at: daysAgo(2), into: [])
        stats = ConnectionHistory.recording(entryID: id, at: now, into: stats)
        XCTAssertEqual(stats.count, 1, "should update in place, not duplicate")
        XCTAssertEqual(stats[0].count, 2)
        XCTAssertEqual(stats[0].lastConnected, now)
    }

    func testLastConnectedNeverGoesBackwards() {
        // A clock that jumps backwards (NTP correction, timezone fiddling)
        // must not make a host you just used look stale.
        let id = UUID()
        var stats = ConnectionHistory.recording(entryID: id, at: now, into: [])
        stats = ConnectionHistory.recording(entryID: id, at: daysAgo(5), into: stats)
        XCTAssertEqual(stats[0].lastConnected, now)
        XCTAssertEqual(stats[0].count, 2, "the connection still counts")
    }

    // MARK: - Staleness

    func testHostsPastTheCutoffAreStale() {
        let old = ConnectionStat(entryID: UUID(), count: 3, lastConnected: daysAgo(120))
        let fresh = ConnectionStat(entryID: UUID(), count: 3, lastConnected: daysAgo(10))
        let stale = ConnectionHistory.staleEntryIDs([old, fresh], staleAfterDays: 90, now: now)
        XCTAssertEqual(stale, [old.entryID])
    }

    func testHostWithNoHistoryIsNotStale() {
        // Unknown is not the same as neglected — the coverage view reports
        // "never connected" separately, and calling it stale would assert a
        // fact we don't have.
        XCTAssertTrue(ConnectionHistory.staleEntryIDs([], staleAfterDays: 90, now: now).isEmpty)
    }

    // MARK: - Log trimming

    func testLogTrimsOldestFirst() {
        let id = UUID()
        let log = (0..<10).map { ConnectionLogEntry(entryID: id, at: daysAgo(Double($0))) }
        let trimmed = ConnectionHistory.trimmed(log, to: 3)
        XCTAssertEqual(trimmed.count, 3)
        XCTAssertEqual(trimmed.map(\.at), [daysAgo(0), daysAgo(1), daysAgo(2)])
    }

    func testTrimmingIsANoOpBelowTheLimit() {
        let log = [ConnectionLogEntry(entryID: UUID(), at: now)]
        XCTAssertEqual(ConnectionHistory.trimmed(log, to: 100).count, 1)
    }

    func testZeroLimitEmptiesTheLog() {
        let log = [ConnectionLogEntry(entryID: UUID(), at: now)]
        XCTAssertTrue(ConnectionHistory.trimmed(log, to: 0).isEmpty)
    }

    // MARK: - Defaults

    func testFullLogIsOptInAndAggregateIsNot() {
        let settings = HistorySettings()
        XCTAssertFalse(settings.keepFullLog, "the per-connection log must be opt-in")
        XCTAssertFalse(
            settings.excludeProtectedHosts,
            "staleness is most useful on prod, so protected hosts are included unless excluded deliberately"
        )
    }
}

/// The transcript window that makes command history a table of contents for
/// the session log.
final class TranscriptExcerptTests: XCTestCase {

    private func writeLog(_ contents: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-excerpt-\(UUID().uuidString).log")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testExcerptReturnsTheRegionAroundTheOffset() {
        let path = writeLog(String(repeating: "A", count: 500)
                            + "NEEDLE"
                            + String(repeating: "B", count: 500))
        let text = LogManager.excerpt(path: path, around: 500, span: 200)
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.contains("NEEDLE"))
    }

    func testMissingTranscriptIsReportedRatherThanCrashing() {
        // Recorded commands outlive their transcripts: logs get compressed,
        // cleaned up, or were never enabled.
        XCTAssertNil(LogManager.excerpt(path: "/nonexistent/portside.log", around: 100))
    }

    func testOffsetBeyondEndOfFileYieldsNothing() {
        let path = writeLog("short")
        XCTAssertNil(LogManager.excerpt(path: path, around: 100_000))
    }

    func testWindowSplittingAMultibyteCharacterStillDecodes() {
        // A byte window can start or end mid-UTF-8; the ragged edges are
        // trimmed rather than failing the whole excerpt.
        let path = writeLog(String(repeating: "é", count: 400))
        let text = LogManager.excerpt(path: path, around: 401, span: 101)
        XCTAssertNotNil(text, "a window across multibyte boundaries must still decode")
        XCTAssertTrue(text!.allSatisfy { $0 == "é" })
    }
}
