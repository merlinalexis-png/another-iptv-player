import Foundation
import GRDB
import GRDBQuery
import Combine

/// Reactive per-channel programme feed — the channel EPG detail screen live-updates
/// when a refresh lands new rows.
struct ChannelEPGRequest: Queryable, Equatable {
    static var defaultValue: [DBEPGProgramme] { [] }

    let playlistId: UUID
    let channelKey: String
    let fromTs: Int64
    let toTs: Int64

    func publisher(in appDatabase: AppDatabase) -> AnyPublisher<[DBEPGProgramme], Never> {
        ValueObservation
            .tracking { db in
                try DBEPGProgramme.fetchAll(db, sql: """
                    SELECT * FROM epgProgramme
                    WHERE playlistId = ? AND channelKey = ? AND stopTs > ? AND startTs < ?
                    ORDER BY startTs
                    """, arguments: [playlistId, channelKey, fromTs, toTs])
            }
            .publisher(in: appDatabase.reader)
            .catch { _ in Just([]) }
            .eraseToAnyPublisher()
    }
}
