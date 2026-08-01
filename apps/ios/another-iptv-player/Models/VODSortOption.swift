import Foundation

/// Movie list sort options that rely only on data already persisted at import
/// time (name, rating, added, containerExtension). No metadata fetch required.
nonisolated enum VODSortOption: String, CaseIterable, Identifiable {
    /// Keep the incoming order untouched (store's `sortIndex`, or search relevance
    /// when a query is active). Acts as an identity sort.
    case defaultOrder
    case nameAsc
    case nameDesc
    case ratingDesc
    case recentlyAdded

    var id: String { rawValue }

    static let storageKey = "vod.sortOption"

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

    func apply(to items: [VODWithCategory]) -> [VODWithCategory] {
        switch self {
        case .defaultOrder:
            // Identity: preserve caller's ordering (sortIndex or search relevance).
            return items
        case .nameAsc:
            return items.sorted {
                $0.stream.name.localizedCaseInsensitiveCompare($1.stream.name) == .orderedAscending
            }
        case .nameDesc:
            return items.sorted {
                $0.stream.name.localizedCaseInsensitiveCompare($1.stream.name) == .orderedDescending
            }
        case .ratingDesc:
            return items.sorted { a, b in
                let r1 = CatalogRatingValue.parse(a.stream.rating)
                let r2 = CatalogRatingValue.parse(b.stream.rating)
                if r1 != r2 { return r1 > r2 }
                // Stable tie-break by API order so equal/unrated items stay grouped.
                return a.stream.sortIndex < b.stream.sortIndex
            }
        case .recentlyAdded:
            return items.sorted { a, b in
                let t1 = a.stream.added.flatMap(Int.init) ?? Int.min
                let t2 = b.stream.added.flatMap(Int.init) ?? Int.min
                if t1 != t2 { return t1 > t2 }
                return a.stream.sortIndex < b.stream.sortIndex
            }
        }
    }
}

/// Helpers for the container-extension (file type) filter.
/// Pure stateless namespace — called from background filtering tasks.
nonisolated enum VODFileType {
    static func normalized(_ ext: String?) -> String? {
        guard let ext = ext?.trimmingCharacters(in: .whitespaces).lowercased(), !ext.isEmpty else { return nil }
        return ext
    }

    /// Distinct file types present in a list, sorted alphabetically. Returns fewer
    /// than 2 entries when there's nothing meaningful to filter on.
    static func available(in items: [VODWithCategory]) -> [String] {
        var set = Set<String>()
        for item in items {
            if let e = normalized(item.stream.containerExtension) { set.insert(e) }
        }
        return set.sorted()
    }

    /// Keeps only items whose file type is in `selection`. Empty selection = all.
    static func filter(_ items: [VODWithCategory], selection: Set<String>) -> [VODWithCategory] {
        guard !selection.isEmpty else { return items }
        return items.filter { item in
            guard let e = normalized(item.stream.containerExtension) else { return false }
            return selection.contains(e)
        }
    }
}
