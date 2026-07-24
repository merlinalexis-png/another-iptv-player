import SwiftUI
import Combine

/// One channel row in the guide.
struct EPGGuideRow: Identifiable, Equatable, Hashable {
    let id: String            // unique per channel
    let channelKey: String    // resolved stored key for programme lookup
    let displayName: String
    let iconURL: URL?
    let liveStream: DBLiveStream?   // Xtream only (catch-up + live play)
    /// Lowercased display name, precomputed once so search never re-lowercases
    /// thousands of names on every keystroke.
    let searchName: String

    init(id: String, channelKey: String, displayName: String, iconURL: URL?, liveStream: DBLiveStream?) {
        self.id = id
        self.channelKey = channelKey
        self.displayName = displayName
        self.iconURL = iconURL
        self.liveStream = liveStream
        self.searchName = displayName.lowercased()
    }
}

/// A positioned programme cell (or a "no data" filler when `programme == nil`).
struct EPGCellLayout: Identifiable, Equatable, Sendable {
    let id: String
    let programme: EPGProgramme?
    let x: CGFloat
    let width: CGFloat
}

struct EPGRowLayout: Equatable, Sendable {
    let cells: [EPGCellLayout]
    let version: Int
}

@MainActor
final class EPGGuideViewModel: ObservableObject {
    enum Source: Equatable {
        case xtream(Playlist)
        case m3u(Playlist)

        var playlist: Playlist {
            switch self {
            case .xtream(let p), .m3u(let p): return p
            }
        }
    }

    enum GuideState: Equatable { case loading, notConfigured, empty, ready }

    let source: Source
    @Published private(set) var rows: [EPGGuideRow] = []
    /// Cached result of applying `searchQuery` to `rows`. Recomputed only when the
    /// query or the row set changes — never per scroll frame, which is why the grid
    /// reads this instead of filtering inside its body.
    @Published private(set) var filteredRows: [EPGGuideRow] = []
    @Published private(set) var layouts: [String: EPGRowLayout] = [:]
    @Published var selectedDay: Date
    @Published private(set) var state: GuideState = .loading
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            recomputeFilteredRows()
        }
    }

    private var layoutVersion = 0
    private let calendar = Calendar.current
    private var loadGeneration = 0
    private var programmeTask: Task<[String: [EPGProgramme]], Error>?
    private var layoutTask: Task<[String: EPGRowLayout], Never>?

    /// Shared fallback for channels without listings. Keeping one value avoids a
    /// dictionary entry and cell array for every no-data channel.
    private(set) var emptyLayout = EPGRowLayout(cells: [], version: 0)

    init(source: Source) {
        self.source = source
        self.selectedDay = Calendar.current.startOfDay(for: Date())
    }

    var playlist: Playlist { source.playlist }
    var dayStart: Date { calendar.startOfDay(for: selectedDay) }

    /// Available day chips: yesterday … +7 days.
    var availableDays: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (-1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private func recomputeFilteredRows() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { filteredRows = rows; return }
        filteredRows = rows.filter { $0.searchName.contains(q) }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        buildRows()
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if rows.isEmpty {
            // Distinguish "no EPG source configured" from "no channels".
            if playlist.kind == .m3u, playlist.effectiveEPGURL == nil {
                state = .notConfigured
            } else {
                state = .empty
            }
            return
        }
        await rebuildLayouts(generation: generation)
    }

    func selectDay(_ day: Date) async {
        selectedDay = calendar.startOfDay(for: day)
        loadGeneration += 1
        await rebuildLayouts(generation: loadGeneration)
    }

    func cancelLoading() {
        loadGeneration += 1
        programmeTask?.cancel()
        layoutTask?.cancel()
        programmeTask = nil
        layoutTask = nil
    }

    private func buildRows() {
        let epg = EPGStore.shared
        switch source {
        case .xtream:
            let streams = PlaylistContentStore.shared.liveStreams.map(\.stream)
            rows = streams.map { stream in
                let idKey = EPGConstants.normalizeChannelKey(stream.epgChannelId)
                let nameKey = EPGConstants.normalizeChannelKey(stream.name)
                let key = epg.storedKey(idKey: idKey, nameKey: nameKey) ?? idKey ?? nameKey ?? "#stream:\(stream.streamId)"
                return EPGGuideRow(id: stream.id, channelKey: key, displayName: stream.name,
                                   iconURL: stream.streamIcon.flatMap { URL(string: $0) }, liveStream: stream)
            }
        case .m3u:
            let channels = M3UContentStore.shared.channels.filter { isLiveChannel($0) }
            rows = channels.map { channel in
                let idKey = EPGConstants.normalizeChannelKey(channel.tvgId)
                let nameKey = EPGConstants.normalizeChannelKey(channel.tvgName ?? channel.name)
                let key = epg.storedKey(idKey: idKey, nameKey: nameKey) ?? idKey ?? nameKey ?? channel.id
                return EPGGuideRow(id: channel.id, channelKey: key, displayName: channel.name,
                                   iconURL: channel.tvgLogo.flatMap { URL(string: $0) }, liveStream: nil)
            }
        }
        recomputeFilteredRows()
    }

    private func isLiveChannel(_ channel: DBM3UChannel) -> Bool {
        guard let url = M3UParser.sanitizedURL(from: channel.url) else { return true }
        return M3UStreamClassifier.classify(url: url, groupTitle: channel.groupTitle).isLive
    }

    private func rebuildLayouts(generation: Int) async {
        let start = dayStart
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let wantedKeys = Set(rows.map(\.channelKey))
        let byKey: [String: [EPGProgramme]]
        do {
            // Fetch the whole playlist's day window and group locally — cheaper than a
            // multi-thousand-placeholder IN clause for large playlists.
            programmeTask?.cancel()
            let query = Task {
                try await EPGStore.shared.programmes(playlistId: playlist.id, from: start, to: end)
            }
            programmeTask = query
            byKey = try await query.value
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            state = rows.isEmpty ? .empty : .ready
            return
        }

        guard generation == loadGeneration, !Task.isCancelled else { return }

        layoutVersion += 1
        let version = layoutVersion
        let metrics = EPGGuideMetrics(compact: true)
        let hourWidth = metrics.hourWidth
        emptyLayout = EPGRowLayout(
            cells: [EPGCellLayout(id: "empty", programme: nil, x: 0, width: metrics.dayWidth)],
            version: version
        )
        // Precompute frames off the main actor — for large playlists this is
        // thousands of channels × dozens of cells.
        layoutTask?.cancel()
        let task = Task.detached(priority: .userInitiated) { () -> [String: EPGRowLayout] in
            EPGGuideViewModel.makeLayouts(
                byKey: byKey,
                wantedKeys: wantedKeys,
                dayStart: start,
                dayEnd: end,
                hourWidth: hourWidth,
                version: version
            )
        }
        layoutTask = task
        let newLayouts = await task.value
        guard generation == loadGeneration, !Task.isCancelled, !task.isCancelled else { return }
        layouts = newLayouts
        state = .ready
    }

    func layout(for channelKey: String) -> EPGRowLayout {
        layouts[channelKey] ?? emptyLayout
    }

    nonisolated static func makeLayouts(
        byKey: [String: [EPGProgramme]],
        wantedKeys: Set<String>,
        dayStart: Date,
        dayEnd: Date,
        hourWidth: CGFloat,
        version: Int
    ) -> [String: EPGRowLayout] {
        var result: [String: EPGRowLayout] = [:]
        result.reserveCapacity(min(byKey.count, wantedKeys.count))
        for (key, unsortedProgrammes) in byKey where wantedKeys.contains(key) {
            guard !Task.isCancelled else { return [:] }
            let programmes = unsortedProgrammes.sorted { $0.start < $1.start }
            result[key] = EPGRowLayout(
                cells: cells(
                    for: programmes,
                    dayStart: dayStart,
                    dayEnd: dayEnd,
                    hourWidth: hourWidth
                ),
                version: version
            )
        }
        return result
    }

    /// Builds positioned cells for a row, clamped to the day bounds. A leading
    /// filler is added when the first programme starts after the day start.
    /// `nonisolated static` so layout precompute can run off the main actor.
    nonisolated static func cells(for programmes: [EPGProgramme], dayStart: Date, dayEnd: Date, hourWidth: CGFloat) -> [EPGCellLayout] {
        let dayWidth = hourWidth * 24
        func x(_ date: Date) -> CGFloat {
            CGFloat(date.timeIntervalSince(dayStart) / 3600) * hourWidth
        }
        var result: [EPGCellLayout] = []
        var cursor = dayStart
        for programme in programmes {
            let cellStart = max(programme.start, dayStart)
            let cellEnd = min(programme.stop, dayEnd)
            guard cellEnd > cellStart else { continue }
            // Gap filler.
            if cellStart > cursor {
                let gx = x(cursor)
                result.append(EPGCellLayout(id: "gap-\(gx)", programme: nil, x: gx, width: x(cellStart) - gx))
            }
            let sx = x(cellStart)
            result.append(EPGCellLayout(id: programme.id, programme: programme, x: sx, width: max(2, x(cellEnd) - sx)))
            cursor = cellEnd
        }
        // Trailing filler to the end of the day.
        if cursor < dayEnd {
            let gx = x(cursor)
            result.append(EPGCellLayout(id: "gap-tail", programme: nil, x: gx, width: dayWidth - gx))
        }
        if result.isEmpty {
            result.append(EPGCellLayout(id: "empty", programme: nil, x: 0, width: dayWidth))
        }
        return result
    }
}
