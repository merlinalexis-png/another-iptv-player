import Foundation

/// Series list sort options using only data persisted at import time
/// (name, rating, lastModified). No metadata fetch required.
nonisolated enum SeriesSortOption: String, CaseIterable, Identifiable {
    /// Identity: preserve caller's ordering (sortIndex or search relevance).
    case defaultOrder
    case nameAsc
    case nameDesc
    case ratingDesc
    case recentlyAdded

    var id: String { rawValue }

    static let storageKey = "series.sortOption"

    var titleKey: String {
        switch self {
        case .defaultOrder: return "sort.default"
        case .nameAsc: return "sort.name_asc"
        case .nameDesc: return "sort.name_desc"
        case .ratingDesc: return "sort.rating_desc"
        case .recentlyAdded: return "sort.recently_added"
        }
    }

    var systemImage: String {
        switch self {
        case .defaultOrder: return "list.number"
        case .nameAsc: return "arrow.up"
        case .nameDesc: return "arrow.down"
        case .ratingDesc: return "star"
        case .recentlyAdded: return "clock"
        }
    }

    func apply(to items: [SeriesWithCategory]) -> [SeriesWithCategory] {
        switch self {
        case .defaultOrder:
            return items
        case .nameAsc:
            return items.sorted {
                $0.series.name.localizedCaseInsensitiveCompare($1.series.name) == .orderedAscending
            }
        case .nameDesc:
            return items.sorted {
                $0.series.name.localizedCaseInsensitiveCompare($1.series.name) == .orderedDescending
            }
        case .ratingDesc:
            return items.sorted { a, b in
                let r1 = CatalogRatingValue.parse(a.series.rating)
                let r2 = CatalogRatingValue.parse(b.series.rating)
                if r1 != r2 { return r1 > r2 }
                return a.series.sortIndex < b.series.sortIndex
            }
        case .recentlyAdded:
            return items.sorted { a, b in
                // Series uses `lastModified` (unix-ts string) as its "added" analog.
                let t1 = a.series.lastModified.flatMap(Int.init) ?? Int.min
                let t2 = b.series.lastModified.flatMap(Int.init) ?? Int.min
                if t1 != t2 { return t1 > t2 }
                return a.series.sortIndex < b.series.sortIndex
            }
        }
    }
}

/// Genre filter for series. `genre` is populated at import, so this needs no
/// metadata backfill. Handles the common comma/slash/pipe-separated form.
/// Pure stateless namespace — called from background filtering tasks.
nonisolated enum SeriesGenre {
    static func split(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func available(in items: [SeriesWithCategory]) -> [String] {
        var set = Set<String>()
        for item in items {
            for genre in split(item.series.genre) { set.insert(genre) }
        }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func filter(_ items: [SeriesWithCategory], selection: Set<String>) -> [SeriesWithCategory] {
        guard !selection.isEmpty else { return items }
        return items.filter { item in
            !Set(split(item.series.genre)).isDisjoint(with: selection)
        }
    }
}
