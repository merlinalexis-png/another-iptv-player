import Foundation
import Testing
@testable import another_iptv_player

@Suite("CatchupAvailability")
struct CatchupAvailabilityTests {

    private let now = Date(timeIntervalSince1970: 1_784_900_000)

    @Test
    func playableWithinArchiveWindow() {
        let start = now.addingTimeInterval(-2 * 3600) // 2h ago
        #expect(CatchupAvailability.isPlayable(tvArchive: 1, tvArchiveDurationDays: 3, programmeStart: start, now: now))
    }

    @Test
    func notPlayableWhenNoArchive() {
        let start = now.addingTimeInterval(-2 * 3600)
        #expect(!CatchupAvailability.isPlayable(tvArchive: 0, tvArchiveDurationDays: 3, programmeStart: start, now: now))
        #expect(!CatchupAvailability.isPlayable(tvArchive: 1, tvArchiveDurationDays: 0, programmeStart: start, now: now))
    }

    @Test
    func notPlayableBeforeWindowStart() {
        let start = now.addingTimeInterval(-4 * 86_400) // 4 days ago, window is 3 days
        #expect(!CatchupAvailability.isPlayable(tvArchive: 1, tvArchiveDurationDays: 3, programmeStart: start, now: now))
    }

    @Test
    func notPlayableForFuture() {
        let start = now.addingTimeInterval(3600) // in the future
        #expect(!CatchupAvailability.isPlayable(tvArchive: 1, tvArchiveDurationDays: 3, programmeStart: start, now: now))
    }

    @Test
    func watchFromStartOnlyForInProgress() {
        let start = now.addingTimeInterval(-1800)
        let stop = now.addingTimeInterval(1800)
        #expect(CatchupAvailability.isWatchFromStart(programmeStart: start, programmeStop: stop, now: now))
        // Fully past → not "watch from start".
        #expect(!CatchupAvailability.isWatchFromStart(programmeStart: now.addingTimeInterval(-7200),
                                                      programmeStop: now.addingTimeInterval(-3600), now: now))
    }

    @Test
    func durationClampsToElapsedForInProgress() {
        let start = now.addingTimeInterval(-1800) // started 30 min ago
        let stop = now.addingTimeInterval(1800)   // ends 30 min from now
        // Should request only the elapsed 30 minutes, not the full 60.
        #expect(CatchupAvailability.requestDurationMinutes(programmeStart: start, programmeStop: stop, now: now) == 30)
    }

    @Test
    func durationFullForEndedProgramme() {
        let start = now.addingTimeInterval(-3600)
        let stop = now.addingTimeInterval(-1800) // ended 30 min ago, 30 min long
        #expect(CatchupAvailability.requestDurationMinutes(programmeStart: start, programmeStop: stop, now: now) == 30)
    }

    @Test
    func durationNeverZero() {
        #expect(CatchupAvailability.requestDurationMinutes(programmeStart: now, programmeStop: now, now: now) == 1)
    }
}
