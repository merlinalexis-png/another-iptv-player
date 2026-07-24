import Foundation
import GRDB
import Combine

/// Content-type scope for catalog sync/refresh: pull-to-refresh syncs only the
/// pulled tab's data instead of the whole catalog.
enum CatalogContentType {
    case live, vod, series
}

/// Aktif playlist kataloğunu bellekte tutar; açılışta veritabanından yükler, gerekirse API ile doldurur.
@MainActor
final class PlaylistContentStore: ObservableObject {
    static let shared = PlaylistContentStore()

    @Published private(set) var activePlaylistId: UUID?
    @Published var isLoading = false
    @Published var loadingMessage: String?
    @Published var loadError: String?
    /// Kategoriler yüklendi ama içerik (stream) verileri henüz yüklenmedi
    @Published private(set) var streamsLoaded = false

    @Published private(set) var liveCategories: [DBCategory] = []
    @Published private(set) var vodCategories: [DBCategory] = []
    @Published private(set) var seriesCategories: [DBCategory] = []
    @Published private(set) var liveStreams: [LiveStreamWithCategory] = []
    @Published private(set) var vodStreams: [VODWithCategory] = []
    @Published private(set) var seriesItems: [SeriesWithCategory] = []

    @Published private(set) var liveStreamsByCategoryId: [String: [LiveStreamWithCategory]] = [:]
    @Published private(set) var vodStreamsByCategoryId: [String: [VODWithCategory]] = [:]
    @Published private(set) var seriesItemsByCategoryId: [String: [SeriesWithCategory]] = [:]

    private var loadToken: UUID?
    private init() {}

    private func clearLists() {
        liveCategories = []
        vodCategories = []
        seriesCategories = []
        liveStreams = []
        vodStreams = []
        seriesItems = []
        liveStreamsByCategoryId = [:]
        vodStreamsByCategoryId = [:]
        seriesItemsByCategoryId = [:]
        streamsLoaded = false
    }

    // MARK: - Filtreleme (UI)

    /// O(1) dictionary lookup yerine O(n) full-array scan yapan eski yaklaşım kaldırıldı.
    func liveStreams(inCategoryId categoryId: String, searchText: String) -> [LiveStreamWithCategory] {
        let base = liveStreamsByCategoryId[categoryId] ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        let filtered = base.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortLiveByRelevance(filtered, search: q)
    }

    func vodStreams(inCategoryId categoryId: String, searchText: String) -> [VODWithCategory] {
        let base = vodStreamsByCategoryId[categoryId] ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        let filtered = base.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortVODByRelevance(filtered, search: q)
    }

    func seriesItems(inCategoryId categoryId: String, searchText: String) -> [SeriesWithCategory] {
        let base = seriesItemsByCategoryId[categoryId] ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        let filtered = base.filter { CatalogTextSearch.matches(search: q, text: $0.series.name) }
        return CatalogTextSearch.sortSeriesByRelevance(filtered, search: q)
    }

    func liveStreams(searchText: String) -> [LiveStreamWithCategory] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let filtered = liveStreams.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortLiveByRelevance(filtered, search: q)
    }

    func vodStreams(searchText: String) -> [VODWithCategory] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let filtered = vodStreams.filter { CatalogTextSearch.matches(search: q, text: $0.stream.name) }
        return CatalogTextSearch.sortVODByRelevance(filtered, search: q)
    }

    func seriesItems(searchText: String) -> [SeriesWithCategory] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let filtered = seriesItems.filter { CatalogTextSearch.matches(search: q, text: $0.series.name) }
        return CatalogTextSearch.sortSeriesByRelevance(filtered, search: q)
    }

    // MARK: - Açılış

    func loadPlaylist(_ playlist: Playlist) async {
        let token = UUID()
        loadToken = token
        loadError = nil
        loadingMessage = nil

        if activePlaylistId != playlist.id {
            clearLists()
            activePlaylistId = playlist.id
            isLoading = true
        } else if liveCategories.isEmpty {
            isLoading = true
        }

        do {
            let needsSync = try await Self.needsNetworkBootstrap(playlistId: playlist.id)
            if needsSync {
                isLoading = true
                loadingMessage = L("phase.preparing")
                try await syncFromNetworkReplacingLocal(playlist: playlist) { msg in
                    guard self.loadToken == token else { return }
                    self.loadingMessage = msg
                }
                guard loadToken == token else { return }
                loadingMessage = L("phase.preparing_list")
            }

            // Faz 1: Sadece kategoriler (çok hızlı – genellikle < 5 ms)
            let cats = try await AppDatabase.shared.read { db in
                try Self.fetchCategoriesOnly(playlistId: playlist.id, db: db)
            }
            guard loadToken == token else { return }
            liveCategories = cats.live
            vodCategories = cats.vod
            seriesCategories = cats.series
            streamsLoaded = false
            loadingMessage = nil
            isLoading = false   // ← UI kategorilerle hemen gösterilir

            // Faz 2: İçerikler paralel olarak yüklenir (arka planda)
            async let liveTask   = AppDatabase.shared.read { db in try Self.fetchLiveStreamsData(playlistId: playlist.id, db: db) }
            async let vodTask    = AppDatabase.shared.read { db in try Self.fetchVODStreamsData(playlistId: playlist.id, db: db) }
            async let seriesTask = AppDatabase.shared.read { db in try Self.fetchSeriesData(playlistId: playlist.id, db: db) }

            let (ls, vs, si) = try await (liveTask, vodTask, seriesTask)
            guard loadToken == token else { return }
            liveStreams = ls.streams
            liveStreamsByCategoryId = ls.byCategory
            vodStreams = vs.streams
            vodStreamsByCategoryId = vs.byCategory
            seriesItems = si.items
            seriesItemsByCategoryId = si.byCategory
            streamsLoaded = true
        } catch {
            guard loadToken == token else { return }
            loadError = error.localizedDescription
            loadingMessage = nil
            isLoading = false
        }
    }

    /// Film detay fetch'i DB'ye yazıldıktan sonra bellek kataloğundaki kopyayı da
    /// güncelle — yoksa aynı filme her yeniden girişte metadataLoaded=false görünüp
    /// gereksiz ağ isteği ve spinner flaşı yaşanıyordu.
    func applyVODMetadata(_ updated: DBVODStream) {
        guard activePlaylistId == updated.playlistId else { return }
        if let i = vodStreams.firstIndex(where: { $0.stream.streamId == updated.streamId }) {
            vodStreams[i] = VODWithCategory(stream: updated, categoryName: vodStreams[i].categoryName)
        }
        // Uncategorized remap'i nedeniyle bucket anahtarı categoryId'den farklı olabilir.
        for key in [updated.categoryId ?? "", Self.uncategorizedCategoryId] {
            if var bucket = vodStreamsByCategoryId[key],
               let j = bucket.firstIndex(where: { $0.stream.streamId == updated.streamId }) {
                bucket[j] = VODWithCategory(stream: updated, categoryName: bucket[j].categoryName)
                vodStreamsByCategoryId[key] = bucket
                break
            }
        }
    }

    /// Dashboard'dan playlist seçicisine dönünce çağrılır: yüz binlerce satırlık
    /// katalog kopyaları (flat + kategori sözlükleri) singleton'da kalmasın.
    /// Yeniden girişte `loadPlaylist` zaten sıfırdan yükler.
    func unload() {
        loadToken = nil
        activePlaylistId = nil
        clearLists()
        loadError = nil
        loadingMessage = nil
        isLoading = false
    }

    /// Pull-to-refresh: tam ağ senkronu + bellek yenileme. Ayarlardaki "Tümünü yenile"
    /// ile aynı yol; hata loadError'a yazılır (senkron atomik olduğu için başarısızlıkta
    /// yerel içerik korunur).
    func refreshFromNetwork(playlist: Playlist) async {
        do {
            try await syncFromNetworkReplacingLocal(playlist: playlist) { [weak self] msg in
                self?.loadingMessage = msg
            }
            await reloadFromDatabaseIfActive(playlistId: playlist.id)
        } catch {
            loadError = error.localizedDescription
        }
        loadingMessage = nil
    }

    /// Scoped pull-to-refresh: only the pulled tab's content type is refetched and
    /// rewritten (e.g. the Movies tab syncs VOD categories + streams); the other
    /// types keep their local data untouched.
    func refreshFromNetwork(playlist: Playlist, only type: CatalogContentType) async {
        do {
            try await syncFromNetworkReplacingLocal(playlist: playlist, only: type) { [weak self] msg in
                self?.loadingMessage = msg
            }
            await reloadFromDatabaseIfActive(playlistId: playlist.id, only: type)
        } catch {
            loadError = error.localizedDescription
        }
        loadingMessage = nil
    }

    /// Ayarlar’dan tam yenileme sonrası belleği güncelle.
    func reloadFromDatabaseIfActive(playlistId: UUID) async {
        guard activePlaylistId == playlistId else { return }
        do {
            try await reloadFromDatabase(playlistId: playlistId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Scoped in-memory reload: refreshes only one content type's categories and
    /// items, applying the same uncategorized merge as the full reload.
    func reloadFromDatabaseIfActive(playlistId: UUID, only type: CatalogContentType) async {
        guard activePlaylistId == playlistId else { return }
        do {
            switch type {
            case .live:
                async let catsTask = AppDatabase.shared.read { db in
                    try Self.fetchCategories(playlistId: playlistId, type: "live", db: db)
                }
                async let dataTask = AppDatabase.shared.read { db in
                    try Self.fetchLiveStreamsData(playlistId: playlistId, db: db)
                }
                let (cats, ls) = try await (catsTask, dataTask)
                let by = Self.mergeUncategorized(ls.byCategory, validIds: Set(cats.map(\.id)))
                liveCategories = Self.appendingUncategorized(cats, byCategory: by, type: "live", playlistId: playlistId)
                liveStreams = ls.streams
                liveStreamsByCategoryId = by
            case .vod:
                async let catsTask = AppDatabase.shared.read { db in
                    try Self.fetchCategories(playlistId: playlistId, type: "vod", db: db)
                }
                async let dataTask = AppDatabase.shared.read { db in
                    try Self.fetchVODStreamsData(playlistId: playlistId, db: db)
                }
                let (cats, vs) = try await (catsTask, dataTask)
                let by = Self.mergeUncategorized(vs.byCategory, validIds: Set(cats.map(\.id)))
                vodCategories = Self.appendingUncategorized(cats, byCategory: by, type: "vod", playlistId: playlistId)
                vodStreams = vs.streams
                vodStreamsByCategoryId = by
            case .series:
                async let catsTask = AppDatabase.shared.read { db in
                    try Self.fetchCategories(playlistId: playlistId, type: "series", db: db)
                }
                async let dataTask = AppDatabase.shared.read { db in
                    try Self.fetchSeriesData(playlistId: playlistId, db: db)
                }
                let (cats, si) = try await (catsTask, dataTask)
                let by = Self.mergeUncategorized(si.byCategory, validIds: Set(cats.map(\.id)))
                seriesCategories = Self.appendingUncategorized(cats, byCategory: by, type: "series", playlistId: playlistId)
                seriesItems = si.items
                seriesItemsByCategoryId = by
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func needsNetworkBootstrap(playlistId: UUID) async throws -> Bool {
        try await AppDatabase.shared.read { db in
            let cat = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category WHERE playlistId = ?", arguments: [playlistId]) ?? 0
            return cat == 0
        }
    }

    func reloadFromDatabase(playlistId: UUID) async throws {
        // Faz 1: Kategoriler (hızlı)
        let cats = try await AppDatabase.shared.read { db in
            try Self.fetchCategoriesOnly(playlistId: playlistId, db: db)
        }
        liveCategories = cats.live
        vodCategories = cats.vod
        seriesCategories = cats.series
        streamsLoaded = false

        // Faz 2: İçerikler paralel
        async let liveTask   = AppDatabase.shared.read { db in try Self.fetchLiveStreamsData(playlistId: playlistId, db: db) }
        async let vodTask    = AppDatabase.shared.read { db in try Self.fetchVODStreamsData(playlistId: playlistId, db: db) }
        async let seriesTask = AppDatabase.shared.read { db in try Self.fetchSeriesData(playlistId: playlistId, db: db) }

        let (ls, vs, si) = try await (liveTask, vodTask, seriesTask)
        // Yetim/kategorisiz streamleri sentetik "Kategorisiz" bucket'ında topla ve
        // gerektiğinde kategori listesine görünür bir giriş ekle.
        let liveBy = Self.mergeUncategorized(ls.byCategory, validIds: Set(cats.live.map(\.id)))
        let vodBy = Self.mergeUncategorized(vs.byCategory, validIds: Set(cats.vod.map(\.id)))
        let seriesBy = Self.mergeUncategorized(si.byCategory, validIds: Set(cats.series.map(\.id)))
        liveCategories = Self.appendingUncategorized(cats.live, byCategory: liveBy, type: "live", playlistId: playlistId)
        vodCategories = Self.appendingUncategorized(cats.vod, byCategory: vodBy, type: "vod", playlistId: playlistId)
        seriesCategories = Self.appendingUncategorized(cats.series, byCategory: seriesBy, type: "series", playlistId: playlistId)
        liveStreams = ls.streams
        liveStreamsByCategoryId = liveBy
        vodStreams = vs.streams
        vodStreamsByCategoryId = vodBy
        seriesItems = si.items
        seriesItemsByCategoryId = seriesBy
        streamsLoaded = true
    }

    // MARK: - DB Fetch Helpers

    private struct CategoriesBundle {
        let live: [DBCategory]
        let vod: [DBCategory]
        let series: [DBCategory]
    }

    private struct LiveStreamsData {
        let streams: [LiveStreamWithCategory]
        let byCategory: [String: [LiveStreamWithCategory]]
    }

    private struct VODStreamsData {
        let streams: [VODWithCategory]
        let byCategory: [String: [VODWithCategory]]
    }

    private struct SeriesData {
        let items: [SeriesWithCategory]
        let byCategory: [String: [SeriesWithCategory]]
    }

    private static func fetchCategories(playlistId: UUID, type: String, db: Database) throws -> [DBCategory] {
        try DBCategory
            .filter(Column("playlistId") == playlistId && Column("type") == type)
            .order(Column("sortIndex"))
            .fetchAll(db)
    }

    private static func fetchCategoriesOnly(playlistId: UUID, db: Database) throws -> CategoriesBundle {
        CategoriesBundle(
            live: try fetchCategories(playlistId: playlistId, type: "live", db: db),
            vod: try fetchCategories(playlistId: playlistId, type: "vod", db: db),
            series: try fetchCategories(playlistId: playlistId, type: "series", db: db)
        )
    }

    /// Kategorisi olmayan/yetim streamlerin toplandığı sentetik kategori id'si.
    /// HiddenCategoryStore bu id ile persist edebilsin diye sabittir.
    nonisolated static let uncategorizedCategoryId = "__uncategorized__"

    // Xtream panelleri category_id'si null/'0'/kategori listesinde olmayan streamler
    // döndürebilir. INNER JOIN bunları tüm ekranlardan sessizce düşürüyordu; LEFT JOIN +
    // COALESCE ile korunur ve "Kategorisiz" başlığı altında gösterilirler.
    private static func fetchLiveStreamsData(playlistId: UUID, db: Database) throws -> LiveStreamsData {
        let sql = """
        SELECT liveStream.*, COALESCE(category.name, ?) AS categoryName
        FROM liveStream
        LEFT JOIN category ON liveStream.categoryId = category.id
                     AND liveStream.playlistId = category.playlistId
                     AND category.type = 'live'
        WHERE liveStream.playlistId = ?
        ORDER BY liveStream.sortIndex
        """
        let streams = try LiveStreamWithCategory.fetchAll(db, sql: sql, arguments: [L("content.uncategorized"), playlistId])
        return LiveStreamsData(streams: streams, byCategory: Dictionary(grouping: streams) { $0.stream.categoryId ?? "" })
    }

    private static func fetchVODStreamsData(playlistId: UUID, db: Database) throws -> VODStreamsData {
        let sql = """
        SELECT vodStream.*, COALESCE(category.name, ?) AS categoryName
        FROM vodStream
        LEFT JOIN category ON vodStream.categoryId = category.id
                     AND vodStream.playlistId = category.playlistId
                     AND category.type = 'vod'
        WHERE vodStream.playlistId = ?
        ORDER BY vodStream.sortIndex
        """
        let streams = try VODWithCategory.fetchAll(db, sql: sql, arguments: [L("content.uncategorized"), playlistId])
        return VODStreamsData(streams: streams, byCategory: Dictionary(grouping: streams) { $0.stream.categoryId ?? "" })
    }

    private static func fetchSeriesData(playlistId: UUID, db: Database) throws -> SeriesData {
        let sql = """
        SELECT series.*, COALESCE(category.name, ?) AS categoryName
        FROM series
        LEFT JOIN category ON series.categoryId = category.id
                     AND series.playlistId = category.playlistId
                     AND category.type = 'series'
        WHERE series.playlistId = ?
        ORDER BY series.sortIndex
        """
        let items = try SeriesWithCategory.fetchAll(db, sql: sql, arguments: [L("content.uncategorized"), playlistId])
        return SeriesData(items: items, byCategory: Dictionary(grouping: items) { $0.series.categoryId ?? "" })
    }

    /// Kategorisi bilinen id'lerde olmayan (nil veya yetim) bucket'ları sentetik
    /// "Kategorisiz" anahtarında birleştirir.
    private static func mergeUncategorized<T>(
        _ byCategory: [String: [T]], validIds: Set<String>
    ) -> [String: [T]] {
        var result: [String: [T]] = [:]
        for (key, items) in byCategory {
            let target = (key.isEmpty || !validIds.contains(key)) ? uncategorizedCategoryId : key
            result[target, default: []].append(contentsOf: items)
        }
        return result
    }

    /// Sentetik "Kategorisiz" bucket'ı doluysa kategori listesinin sonuna görünür bir
    /// kategori ekler; boşsa listeyi aynen döndürür.
    private static func appendingUncategorized(
        _ categories: [DBCategory],
        byCategory: [String: [some Any]],
        type: String,
        playlistId: UUID
    ) -> [DBCategory] {
        guard let orphans = byCategory[uncategorizedCategoryId], !orphans.isEmpty else { return categories }
        var result = categories
        result.append(DBCategory(
            id: uncategorizedCategoryId,
            name: L("content.uncategorized"),
            parentId: nil,
            type: type,
            sortIndex: (categories.map(\.sortIndex).max() ?? -1) + 1,
            playlistId: playlistId
        ))
        return result
    }

    // MARK: - Ağ senkronu (Xtream → SQLite)

    /// Ayarlar ekranı: aşamalı ilerleme mesajı ile tam yenileme.
    /// Yerel içerik, tüm ağ istekleri başarıyla tamamlanana kadar SİLİNMEZ: silme ve yeniden
    /// yazma tek transaction'da yapılır ki panel/ağ hatası çalışan kütüphaneyi boşaltmasın.
    func syncFromNetworkReplacingLocal(playlist: Playlist, progress: @escaping (String) -> Void) async throws {
        let client = XtreamAPIClient(playlist: playlist)
        let pid = playlist.id

        // Altı endpoint bağımsız — paralel çekim yenileme süresini ciddi kısaltır.
        progress(L("phase.fetch_categories"))
        async let liveCatsTask = client.getLiveCategories()
        async let vodCatsTask = client.getVODCategories()
        async let seriesCatsTask = client.getSeriesCategories()
        async let liveStreamsTask = client.getLiveStreams()
        async let vodsTask = client.getVODStreams()
        async let seriesTask = client.getSeries()
        let (liveCats, vodCats, seriesCats, liveStreamsAPI, vods, series) = try await (
            liveCatsTask, vodCatsTask, seriesCatsTask, liveStreamsTask, vodsTask, seriesTask
        )

        let filterAdult = playlist.filterAdultContent
        progress(L("phase.save_db"))
        try await AppDatabase.shared.write { db in
            // Delete-then-insert inside one transaction: rolls back together on any error.
            try Self.replaceLiveCatalog(db: db, pid: pid, categories: liveCats, streams: liveStreamsAPI, filterAdult: filterAdult)
            try Self.replaceVODCatalog(db: db, pid: pid, categories: vodCats, streams: vods, filterAdult: filterAdult)
            try Self.replaceSeriesCatalog(db: db, pid: pid, categories: seriesCats, series: series, filterAdult: filterAdult)
        }
    }

    /// Scoped sync: refetches and rewrites a single content type; the other types'
    /// rows are left untouched. Same atomic delete-then-insert guarantee per type.
    func syncFromNetworkReplacingLocal(
        playlist: Playlist, only type: CatalogContentType, progress: @escaping (String) -> Void
    ) async throws {
        let client = XtreamAPIClient(playlist: playlist)
        let pid = playlist.id
        let filterAdult = playlist.filterAdultContent

        progress(L("phase.fetch_categories"))
        switch type {
        case .live:
            async let catsTask = client.getLiveCategories()
            async let streamsTask = client.getLiveStreams()
            let (cats, streams) = try await (catsTask, streamsTask)
            progress(L("phase.save_db"))
            try await AppDatabase.shared.write { db in
                try Self.replaceLiveCatalog(db: db, pid: pid, categories: cats, streams: streams, filterAdult: filterAdult)
            }
        case .vod:
            async let catsTask = client.getVODCategories()
            async let streamsTask = client.getVODStreams()
            let (cats, streams) = try await (catsTask, streamsTask)
            progress(L("phase.save_db"))
            try await AppDatabase.shared.write { db in
                try Self.replaceVODCatalog(db: db, pid: pid, categories: cats, streams: streams, filterAdult: filterAdult)
            }
        case .series:
            async let catsTask = client.getSeriesCategories()
            async let seriesTask = client.getSeries()
            let (cats, items) = try await (catsTask, seriesTask)
            progress(L("phase.save_db"))
            try await AppDatabase.shared.write { db in
                try Self.replaceSeriesCatalog(db: db, pid: pid, categories: cats, series: items, filterAdult: filterAdult)
            }
        }
    }

    // MARK: - DB rewrite helpers (shared by full and scoped sync)

    private static func replaceLiveCatalog(
        db: Database, pid: UUID, categories: [XtreamCategory], streams: [XtreamLiveStream], filterAdult: Bool
    ) throws {
        let adultCatIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: categories) : []
        try db.execute(sql: "DELETE FROM category WHERE playlistId = ? AND type = 'live'", arguments: [pid])
        try db.execute(sql: "DELETE FROM liveStream WHERE playlistId = ?", arguments: [pid])
        for (index, cat) in categories.enumerated() {
            if filterAdult, let name = cat.categoryName, AdultContentFilter.isAdultCategoryName(name) { continue }
            let dbCat = DBCategory(id: cat.id, name: cat.categoryName ?? L("content.unnamed"), parentId: cat.parentId, type: "live", sortIndex: index, playlistId: pid)
            try dbCat.save(db)
        }
        for (index, stream) in streams.enumerated() {
            if filterAdult, AdultContentFilter.isAdultLiveStream(stream, adultCategoryIds: adultCatIds) { continue }
            let dbStream = DBLiveStream(streamId: stream.id, name: stream.name ?? L("content.unnamed"), streamIcon: stream.streamIcon, epgChannelId: stream.epgChannelId, categoryId: stream.categoryId, sortIndex: index, playlistId: pid, tvArchive: stream.tvArchive ?? 0, tvArchiveDuration: stream.tvArchiveDuration ?? 0)
            try dbStream.save(db)
        }
    }

    private static func replaceVODCatalog(
        db: Database, pid: UUID, categories: [XtreamCategory], streams: [XtreamVODStream], filterAdult: Bool
    ) throws {
        let adultCatIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: categories) : []
        try db.execute(sql: "DELETE FROM category WHERE playlistId = ? AND type = 'vod'", arguments: [pid])
        try db.execute(sql: "DELETE FROM vodStream WHERE playlistId = ?", arguments: [pid])
        for (index, cat) in categories.enumerated() {
            if filterAdult, let name = cat.categoryName, AdultContentFilter.isAdultCategoryName(name) { continue }
            let dbCat = DBCategory(id: cat.id, name: cat.categoryName ?? L("content.unnamed"), parentId: cat.parentId, type: "vod", sortIndex: index, playlistId: pid)
            try dbCat.save(db)
        }
        for (index, stream) in streams.enumerated() {
            if filterAdult, AdultContentFilter.isAdultVODStream(stream, adultCategoryIds: adultCatIds) { continue }
            var dbVOD = DBVODStream(streamId: stream.id, name: stream.name ?? L("content.unnamed"), streamIcon: stream.streamIcon, categoryId: stream.categoryId, rating: stream.rating, containerExtension: stream.containerExtension, sortIndex: index, playlistId: pid)
            dbVOD.added = stream.added
            try dbVOD.save(db)
        }
    }

    private static func replaceSeriesCatalog(
        db: Database, pid: UUID, categories: [XtreamCategory], series: [XtreamSeries], filterAdult: Bool
    ) throws {
        let adultCatIds = filterAdult ? AdultContentFilter.adultCategoryIds(from: categories) : []
        try db.execute(sql: "DELETE FROM category WHERE playlistId = ? AND type = 'series'", arguments: [pid])
        try db.execute(sql: "DELETE FROM series WHERE playlistId = ?", arguments: [pid])
        for (index, cat) in categories.enumerated() {
            if filterAdult, let name = cat.categoryName, AdultContentFilter.isAdultCategoryName(name) { continue }
            let dbCat = DBCategory(id: cat.id, name: cat.categoryName ?? L("content.unnamed"), parentId: cat.parentId, type: "series", sortIndex: index, playlistId: pid)
            try dbCat.save(db)
        }
        for (index, s) in series.enumerated() {
            if filterAdult, let cid = s.categoryId, adultCatIds.contains(cid) { continue }
            let dbSeries = DBSeries(
                seriesId: s.id,
                name: s.name ?? L("content.unnamed"),
                cover: s.cover,
                plot: s.plot,
                cast: s.cast,
                director: s.director,
                genre: s.genre,
                releaseDate: s.releaseDate,
                rating: s.rating,
                lastModified: s.lastModified,
                youtubeTrailer: s.youtubeTrailer,
                categoryId: s.categoryId,
                sortIndex: index,
                playlistId: pid
            )
            try dbSeries.save(db)
        }
    }
}
