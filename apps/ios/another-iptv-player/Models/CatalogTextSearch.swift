import Foundation

/// GRDB `localized_*` SQL fonksiyonlarıyla aynı mantık (Persistence.swift).
/// Pure stateless namespace — used from detached filtering tasks, so it must not be MainActor.
nonisolated enum CatalogTextSearch {
    private static let foldLocale = Locale(identifier: "en_US_POSIX")
    private static let alphanumericSet = CharacterSet.alphanumerics

    /// Locale-invariant fold: tr_TR lowercasing maps "I"→"ı" and breaks queries like
    /// "history" against ALL-CAPS catalog names ("HISTORY HD" → "hıstory hd").
    /// The extra "ı"→"i" pass keeps Turkish dotless-ı queries matching ALL-CAPS
    /// Turkish text ("IŞIK" and "ışık" both normalize to "isik").
    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldLocale)
        return folded
            .replacingOccurrences(of: "ı", with: "i")
            .components(separatedBy: alphanumericSet.inverted)
            .joined()
    }

    static func matches(search: String, text: String) -> Bool {
        let normalizedText = normalize(text)
        let queryWords = search
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        if queryWords.isEmpty { return true }
        return queryWords.allSatisfy { word in
            normalizedText.contains(normalize(word))
        }
    }

    static func equals(search: String, text: String) -> Bool {
        normalize(text) == normalize(search)
    }

    static func startsWith(search: String, text: String) -> Bool {
        normalize(text).hasPrefix(normalize(search))
    }

    static func sortLiveByRelevance(_ items: [LiveStreamWithCategory], search: String) -> [LiveStreamWithCategory] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return items.sorted { $0.stream.sortIndex < $1.stream.sortIndex }
        }
        return items.sorted { a, b in
            let n1 = a.stream.name, n2 = b.stream.name
            let e1 = equals(search: trimmed, text: n1), e2 = equals(search: trimmed, text: n2)
            if e1 != e2 { return e1 && !e2 }
            let s1 = startsWith(search: trimmed, text: n1), s2 = startsWith(search: trimmed, text: n2)
            if s1 != s2 { return s1 && !s2 }
            return n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
        }
    }

    static func sortVODByRelevance(_ items: [VODWithCategory], search: String) -> [VODWithCategory] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return items.sorted { $0.stream.sortIndex < $1.stream.sortIndex }
        }
        return items.sorted { a, b in
            let n1 = a.stream.name, n2 = b.stream.name
            let e1 = equals(search: trimmed, text: n1), e2 = equals(search: trimmed, text: n2)
            if e1 != e2 { return e1 && !e2 }
            let s1 = startsWith(search: trimmed, text: n1), s2 = startsWith(search: trimmed, text: n2)
            if s1 != s2 { return s1 && !s2 }
            return n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
        }
    }

    static func sortSeriesByRelevance(_ items: [SeriesWithCategory], search: String) -> [SeriesWithCategory] {
        let trimmed = search.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return items.sorted { $0.series.sortIndex < $1.series.sortIndex }
        }
        return items.sorted { a, b in
            let n1 = a.series.name, n2 = b.series.name
            let e1 = equals(search: trimmed, text: n1), e2 = equals(search: trimmed, text: n2)
            if e1 != e2 { return e1 && !e2 }
            let s1 = startsWith(search: trimmed, text: n1), s2 = startsWith(search: trimmed, text: n2)
            if s1 != s2 { return s1 && !s2 }
            return n1.localizedCaseInsensitiveCompare(n2) == .orderedAscending
        }
    }
}
