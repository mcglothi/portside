import Foundation

/// Per-host connection totals. Cheap, bounded by the size of the library, and
/// enough on its own for both frecency ranking and stale-host detection — which
/// is why this is the always-on half of history.
struct ConnectionStat: Codable, Hashable, Identifiable {
    var id: UUID { entryID }
    var entryID: UUID
    var count: Int
    var lastConnected: Date
}

/// How a connection attempt turned out.
///
/// Recording every *attempt* as a success made a host you repeatedly fail to
/// reach look like your most active one: the count climbed, it never went
/// stale, and it rose up Quick Connect's ranking — precisely backwards.
enum ConnectionOutcome: String, Codable, Hashable {
    /// Launched, but nothing yet says it worked.
    case attempted
    /// Positive evidence the session came up.
    case connected
    /// Ended before it could reasonably have connected.
    case failed

    /// Tolerant decode: an unrecognised outcome from a newer build reads as
    /// `attempted` rather than failing the whole history file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConnectionOutcome(rawValue: raw) ?? .attempted
    }
}

/// A single timestamped connection. Only recorded when the full log is switched
/// on: unlike the aggregate, this is a running record of which infrastructure
/// was touched and when, which on a work machine is a meaningful artifact —
/// so it's opt-in rather than something the app starts keeping on its own.
struct ConnectionLogEntry: Codable, Hashable, Identifiable {
    var id: UUID { eventID }
    var eventID = UUID()
    var entryID: UUID
    var at: Date
    /// Absent in entries written before outcomes were tracked.
    var outcome: ConnectionOutcome?
}

struct HistorySettings: Codable, Equatable {
    /// Aggregate stats are always kept; this adds the per-connection log.
    var keepFullLog = false
    /// Leaves protected hosts out of history entirely, aggregate included.
    /// Off by default: staleness is *most* useful on production hosts, so
    /// excluding them by default would blunt the feature for the people most
    /// likely to want it. Available for anyone who'd rather not have the
    /// record exist.
    var excludeProtectedHosts = false
    /// Cap on the full log, oldest trimmed first.
    var logLimit = 2_000

    /// Hosts untouched for at least this long count as stale.
    var staleAfterDays = 90

    /// Records each command run, with timing and exit status, via the OSC 133
    /// markers the shell-integration snippet emits. Opt-in and off by default:
    /// command lines routinely contain secrets typed inline, and this writes
    /// them to the library file in plain text.
    var keepCommandHistory = false
    var commandLimit = 5_000
}

/// Ranking and staleness. Pure so it tests without a store or a GUI.
enum ConnectionHistory {

    /// Blends how often a host is used with how recently, so a host connected
    /// to constantly outranks one touched once yesterday. Recency decays on a
    /// half-life rather than a cliff, so ordering shifts gradually instead of
    /// reshuffling the moment a threshold is crossed.
    ///
    /// Score = count × 2^(−age in days / halfLife).
    static func frecency(
        count: Int, lastConnected: Date, now: Date = Date(), halfLifeDays: Double = 7
    ) -> Double {
        guard count > 0 else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(lastConnected) / 86_400)
        return Double(count) * pow(2, -ageDays / halfLifeDays)
    }

    /// Entry IDs ordered by frecency, strongest first. Hosts with no history
    /// are omitted — the caller decides what to do with the rest.
    static func ranked(
        _ stats: [ConnectionStat], now: Date = Date(), halfLifeDays: Double = 7
    ) -> [UUID] {
        stats
            .map { ($0.entryID, frecency(count: $0.count, lastConnected: $0.lastConnected,
                                         now: now, halfLifeDays: halfLifeDays)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Applies one connection to the aggregate, returning the updated set.
    static func recording(
        entryID: UUID, at date: Date, into stats: [ConnectionStat]
    ) -> [ConnectionStat] {
        var updated = stats
        if let index = updated.firstIndex(where: { $0.entryID == entryID }) {
            updated[index].count += 1
            // Guard against a clock that went backwards: last-connected must
            // never regress, or a host could look stale right after use.
            updated[index].lastConnected = max(updated[index].lastConnected, date)
        } else {
            updated.append(ConnectionStat(entryID: entryID, count: 1, lastConnected: date))
        }
        return updated
    }

    /// Hosts not connected to within `staleAfterDays`. A host with no history
    /// at all is *not* stale — it's unknown, which the coverage view reports
    /// separately; calling it stale would imply a fact we don't have.
    static func staleEntryIDs(
        _ stats: [ConnectionStat], staleAfterDays: Int, now: Date = Date()
    ) -> Set<UUID> {
        let cutoff = now.addingTimeInterval(-Double(staleAfterDays) * 86_400)
        return Set(stats.filter { $0.lastConnected < cutoff }.map(\.entryID))
    }

    /// Hosts Portside has ever recorded a confirmed connection to.
    ///
    /// `nil` when there is no history at all, which is not the same as "nothing
    /// has been connected to": recording may be off, or this may be a library
    /// imported five minutes ago. The coverage view uses the distinction to
    /// stay quiet rather than declare the whole fleet unvisited.
    static func connectedEntryIDs(_ stats: [ConnectionStat]) -> Set<UUID>? {
        guard !stats.isEmpty else { return nil }
        return Set(stats.map(\.entryID))
    }

    /// Trims the log to `limit`, dropping oldest first.
    static func trimmed(_ log: [ConnectionLogEntry], to limit: Int) -> [ConnectionLogEntry] {
        guard limit > 0 else { return [] }
        guard log.count > limit else { return log }
        return Array(log.sorted { $0.at > $1.at }.prefix(limit))
    }
}
