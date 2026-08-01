import SwiftUI
import Combine

/// One channel row in the guide.
struct EPGGuideRow: Identifiable, Equatable, Hashable {
    let id: String            // unique per channel
    let channelKey: String    // resolved stored key for programme lookup
    let displayName: String
    let iconURL: URL?
    let liveStream: DBLiveStream?   // Xtream only (catch-up + live play)
    /// Category the channel belongs to, used to group rows under collapsible
    /// headers. `categoryId` is the stable grouping key; `categoryTitle` is shown.
    let categoryId: String
    let categoryTitle: String
    /// Lowercased display name, precomputed once so search never re-lowercases
    /// thousands of names on every keystroke.
    let searchName: String

    init(id: String, channelKey: String, displayName: String, iconURL: URL?,
         liveStream: DBLiveStream?, categoryId: String, categoryTitle: String) {
        self.id = id
        self.channelKey = channelKey
        self.displayName = displayName
        self.iconURL = iconURL
        self.liveStream = liveStream
        self.categoryId = categoryId
        self.categoryTitle = categoryTitle
        self.searchName = displayName.lowercased()
    }
}

/// A collapsible category header row in the guide.
struct EPGGuideSectionHeader: Identifiable, Equatable {
    let id: String
    let title: String
    let channelCount: Int
    let collapsed: Bool
}

/// One rendered row of the guide: either a category header or a channel.
enum EPGGuideItem: Identifiable, Equatable {
    case header(EPGGuideSectionHeader)
    case channel(EPGGuideRow)

    var id: String {
        switch self {
        case .header(let header): return "hdr:" + header.id
        case .channel(let row): return row.id
        }
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
    /// The flat sequence the grid renders: category headers interleaved with the
    /// channels of each (expanded) category. Recomputed only when the row set,
    /// search query, or a collapse toggle changes — never per scroll frame.
    @Published private(set) var items: [EPGGuideItem] = []
    /// Category ids the user has collapsed. Persisted per playlist so the guide
    /// reopens in the same shape.
    @Published private(set) var collapsedCategories: Set<String>
    @Published private(set) var layouts: [String: EPGRowLayout] = [:]
    @Published var selectedDay: Date
    @Published private(set) var state: GuideState = .loading
    @Published var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            recomputeItems()
        }
    }

    /// Categories in display order with their channels. Built once per row set;
    /// `items` is derived from this plus the search query and collapse state.
    private var orderedSections: [(id: String, title: String, rows: [EPGGuideRow])] = []

    /// Grouping key/title for channels that belong to no category.
    private static let uncategorizedId = "__epg_uncategorized__"

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
        self.collapsedCategories = Self.loadCollapsed(playlistId: source.playlist.id)
    }

    var playlist: Playlist { source.playlist }
    var dayStart: Date { calendar.startOfDay(for: selectedDay) }

    /// Available day chips: yesterday … +7 days.
    var availableDays: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (-1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// True when there is more than one category to show — headers are only worth
    /// drawing then; a single-category playlist renders as a flat list.
    var hasCategories: Bool { orderedSections.count > 1 }

    /// Groups `rows` into categories in first-appearance order. Called once per row
    /// set; cheap re-derivations (search, collapse) work off the result.
    private func rebuildSections() {
        var order: [String] = []
        var byId: [String: (title: String, rows: [EPGGuideRow])] = [:]
        for row in rows {
            if byId[row.categoryId] == nil {
                order.append(row.categoryId)
                byId[row.categoryId] = (row.categoryTitle, [row])
            } else {
                byId[row.categoryId]?.rows.append(row)
            }
        }
        orderedSections = order.map { (id: $0, title: byId[$0]?.title ?? $0, rows: byId[$0]?.rows ?? []) }
    }

    /// Rebuilds `items` from the sections, honouring the search query and collapse
    /// state. While searching, collapse is ignored so matches are always visible.
    private func recomputeItems() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searching = !q.isEmpty
        let showHeaders = orderedSections.count > 1
        var result: [EPGGuideItem] = []
        for section in orderedSections {
            let sectionRows = searching ? section.rows.filter { $0.searchName.contains(q) } : section.rows
            guard !sectionRows.isEmpty else { continue }
            let collapsed = !searching && collapsedCategories.contains(section.id)
            if showHeaders {
                result.append(.header(EPGGuideSectionHeader(
                    id: section.id, title: section.title,
                    channelCount: sectionRows.count, collapsed: collapsed)))
            }
            if !collapsed {
                result.append(contentsOf: sectionRows.map { EPGGuideItem.channel($0) })
            }
        }
        items = result
    }

    func toggleCategory(_ id: String) {
        if collapsedCategories.contains(id) {
            collapsedCategories.remove(id)
        } else {
            collapsedCategories.insert(id)
        }
        persistCollapsed()
        recomputeItems()
    }

    func setAllCollapsed(_ collapsed: Bool) {
        collapsedCategories = collapsed ? Set(orderedSections.map(\.id)) : []
        persistCollapsed()
        recomputeItems()
    }

    /// Grouping key + display title for a channel's category, folding empty ids and
    /// names into a shared "Uncategorized" bucket.
    private static func category(id: String?, name: String?) -> (id: String, title: String) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedId = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedName.isEmpty && trimmedId.isEmpty {
            return (uncategorizedId, L("content.uncategorized"))
        }
        let key = trimmedId.isEmpty ? trimmedName : trimmedId
        let title = trimmedName.isEmpty ? trimmedId : trimmedName
        return (key, title)
    }

    // MARK: - Collapse persistence

    private static func collapseKey(_ playlistId: UUID) -> String {
        "epg.collapsedCategories.\(playlistId.uuidString)"
    }

    private static func loadCollapsed(playlistId: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: collapseKey(playlistId)) ?? [])
    }

    private func persistCollapsed() {
        UserDefaults.standard.set(Array(collapsedCategories), forKey: Self.collapseKey(playlist.id))
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
            let entries = PlaylistContentStore.shared.liveStreams
            rows = entries.map { entry in
                let stream = entry.stream
                let idKey = EPGConstants.normalizeChannelKey(stream.epgChannelId)
                let nameKey = EPGConstants.normalizeChannelKey(stream.name)
                let key = epg.storedKey(idKey: idKey, nameKey: nameKey) ?? idKey ?? nameKey ?? "#stream:\(stream.streamId)"
                let category = Self.category(id: stream.categoryId, name: entry.categoryName)
                return EPGGuideRow(id: stream.id, channelKey: key, displayName: stream.name,
                                   iconURL: stream.streamIcon.flatMap { URL(string: $0) }, liveStream: stream,
                                   categoryId: category.id, categoryTitle: category.title)
            }
        case .m3u:
            let channels = M3UContentStore.shared.channels.filter { isLiveChannel($0) }
            rows = channels.map { channel in
                let idKey = EPGConstants.normalizeChannelKey(channel.tvgId)
                let nameKey = EPGConstants.normalizeChannelKey(channel.tvgName ?? channel.name)
                let key = epg.storedKey(idKey: idKey, nameKey: nameKey) ?? idKey ?? nameKey ?? channel.id
                let category = Self.category(id: channel.groupTitle, name: channel.groupTitle)
                return EPGGuideRow(id: channel.id, channelKey: key, displayName: channel.name,
                                   iconURL: channel.tvgLogo.flatMap { URL(string: $0) }, liveStream: nil,
                                   categoryId: category.id, categoryTitle: category.title)
            }
        }
        rebuildSections()
        recomputeItems()
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
        // Use the real elapsed hours between dayStart/dayEnd rather than a fixed 24
        // so DST transition days (23h/25h) don't misplace the trailing filler cell.
        let dayWidth = CGFloat(dayEnd.timeIntervalSince(dayStart) / 3600) * hourWidth
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
