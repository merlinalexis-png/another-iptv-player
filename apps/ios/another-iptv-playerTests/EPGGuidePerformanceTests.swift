import Foundation
import GRDB
import Testing
@testable import another_iptv_player

@Suite("EPG guide performance guards")
struct EPGGuidePerformanceTests {

    @Test
    func groupsLargeGuideByChannelWithoutLosingRows() {
        let channelCount = 1_000
        let programmesPerChannel = 30
        var rows: [EPGGuideProgrammeRecord] = []
        rows.reserveCapacity(channelCount * programmesPerChannel)
        for index in 0..<(channelCount * programmesPerChannel) {
            rows.append(EPGGuideProgrammeRecord(
                channelKey: "channel-\(index % channelCount)",
                startTs: Int64(index * 1_800),
                stopTs: Int64(index * 1_800 + 1_800),
                title: "Programme \(index)"
            ))
        }

        let grouped = EPGStore.groupGuideProgrammes(rows)

        #expect(grouped.count == channelCount)
        #expect(grouped.values.reduce(0) { $0 + $1.count } == rows.count)
    }

    @Test
    func layoutsAreStoredOnlyForChannelsWithGuideData() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(86_400)
        let programme = EPGProgramme(
            channelKey: "with-guide",
            title: "News",
            start: start.addingTimeInterval(3_600),
            stop: start.addingTimeInterval(7_200)
        )
        var wanted = Set((0..<20_000).map { "no-data-\($0)" })
        wanted.insert("with-guide")

        let layouts = EPGGuideViewModel.makeLayouts(
            byKey: [
                "with-guide": [programme],
                "stale-channel": [programme]
            ],
            wantedKeys: wanted,
            dayStart: start,
            dayEnd: end,
            hourWidth: 120,
            version: 1
        )

        #expect(layouts.count == 1)
        #expect(layouts["with-guide"]?.cells.contains { $0.programme?.title == "News" } == true)
        #expect(layouts["stale-channel"] == nil)
    }

    @Test
    func databaseCreatesAtomicRefreshStagingTables() async throws {
        let database = AppDatabase.empty()
        let names = try await database.read { db in
            try Set(String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name IN ('epgProgrammeStaging', 'epgChannelStaging')
                """))
        }

        #expect(names == ["epgProgrammeStaging", "epgChannelStaging"])
    }

    @Test
    func publishingStagedGuideReplacesLiveGuideAndClearsStaging() async throws {
        let database = AppDatabase.empty()
        let playlistId = UUID()

        try await database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playlist (id, name, serverURL, username, password)
                    VALUES (?, 'Test', 'https://example.com', '', '')
                    """,
                arguments: [playlistId]
            )
            try db.execute(
                sql: """
                    INSERT INTO epgProgramme
                        (playlistId, channelKey, startTs, stopTs, title)
                    VALUES (?, 'news', 100, 200, 'Old programme')
                    """,
                arguments: [playlistId]
            )
            try db.execute(
                sql: """
                    INSERT INTO epgProgrammeStaging
                        (playlistId, channelKey, startTs, stopTs, title)
                    VALUES (?, 'news', 200, 300, 'New programme')
                    """,
                arguments: [playlistId]
            )

            try EPGRefreshCoordinator.publishStagedGuide(in: db, playlistId: playlistId)
        }

        let result = try await database.read { db in
            let liveTitles = try String.fetchAll(
                db,
                sql: "SELECT title FROM epgProgramme WHERE playlistId = ? ORDER BY startTs",
                arguments: [playlistId]
            )
            let stagedCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM epgProgrammeStaging WHERE playlistId = ?",
                arguments: [playlistId]
            ) ?? -1
            return (liveTitles, stagedCount)
        }

        #expect(result.0 == ["New programme"])
        #expect(result.1 == 0)
    }
}
