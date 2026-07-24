import Foundation

/// Pure predicates deciding whether a programme can be played back from the
/// Xtream timeshift archive. Kept free of UI/DB types so it is unit-testable.
nonisolated enum CatchupAvailability {
    /// A past programme is playable when the channel advertises an archive, the
    /// programme has started, and its start is still inside the archive window.
    static func isPlayable(tvArchive: Int,
                           tvArchiveDurationDays: Int,
                           programmeStart: Date,
                           now: Date = Date()) -> Bool {
        guard tvArchive == 1, tvArchiveDurationDays > 0 else { return false }
        guard programmeStart < now else { return false }
        let earliest = now.addingTimeInterval(-Double(tvArchiveDurationDays) * 86_400)
        return programmeStart >= earliest
    }

    /// An in-progress programme (started, not yet ended) can be watched from the
    /// start via timeshift — the "watch from start" affordance.
    static func isWatchFromStart(programmeStart: Date,
                                 programmeStop: Date,
                                 now: Date = Date()) -> Bool {
        programmeStart <= now && now < programmeStop
    }

    /// Clamps the requested timeshift duration to the elapsed portion of an
    /// in-progress programme — panels reject/truncate durations extending past
    /// "now", so a "watch from start" request must stop at the live edge.
    static func requestDurationMinutes(programmeStart: Date,
                                       programmeStop: Date,
                                       now: Date = Date()) -> Int {
        let end = Swift.min(programmeStop, Swift.max(now, programmeStart))
        let seconds = end.timeIntervalSince(programmeStart)
        return Swift.max(1, Int((seconds / 60).rounded(.up)))
    }
}
