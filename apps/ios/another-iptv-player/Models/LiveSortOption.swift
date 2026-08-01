import Foundation

/// Shared parser for Xtream rating strings ("7.5", "7,5", "N/A", "").
/// Missing/invalid → -1 so unrated items sort to the bottom.
nonisolated enum CatalogRatingValue {
    static func parse(_ raw: String?) -> Double {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return -1 }
        return Double(raw.replacingOccurrences(of: ",", with: ".")) ?? -1
    }
}

/// Live channel sort options. Live has no rating/added, so only name-based
/// sorting is data-backed.
nonisolated enum LiveSortOption: String, CaseIterable, Identifiable {
    /// Identity: preserve caller's ordering (sortIndex or search relevance).
    case defaultOrder
    case nameAsc
    case nameDesc

    var id: String { rawValue }

    static let storageKey = "live.sortOption"

    var titleKey: String {
        switch self {
        case .defaultOrder: return "sort.default"
        case .nameAsc: return "sort.name_asc"
        case .nameDesc: return "sort.name_desc"
        }
    }

    var systemImage: String {
        switch self {
        case .defaultOrder: return "list.number"
        case .nameAsc: return "arrow.up"
        case .nameDesc: return "arrow.down"
        }
    }

    func apply(to items: [LiveStreamWithCategory]) -> [LiveStreamWithCategory] {
        switch self {
        case .defaultOrder:
            return items
        case .nameAsc:
            return items.sorted {
                $0.stream.name.localizedCaseInsensitiveCompare($1.stream.name) == .orderedAscending
            }
        case .nameDesc:
            return items.sorted {
                $0.stream.name.localizedCaseInsensitiveCompare($1.stream.name) == .orderedDescending
            }
        }
    }
}

/// Toggle filters for live channels, backed by fields present at import.
nonisolated struct LiveStreamFilter: OptionSet {
    let rawValue: Int
    static let catchup = LiveStreamFilter(rawValue: 1 << 0)   // tvArchive > 0
    static let hasEPG = LiveStreamFilter(rawValue: 1 << 1)    // epgChannelId present

    static func apply(_ items: [LiveStreamWithCategory], _ filter: LiveStreamFilter) -> [LiveStreamWithCategory] {
        guard !filter.isEmpty else { return items }
        return items.filter { item in
            if filter.contains(.catchup), item.stream.tvArchive <= 0 { return false }
            if filter.contains(.hasEPG), (item.stream.epgChannelId ?? "").isEmpty { return false }
            return true
        }
    }
}
