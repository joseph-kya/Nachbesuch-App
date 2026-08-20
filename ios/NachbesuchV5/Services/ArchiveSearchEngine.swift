import Foundation

nonisolated struct ArchiveSearchResult: Identifiable, Sendable {
    /// Carries the id, not the model. `ArchiveSearchResult` used to be declared
    /// `Sendable` while holding a live `@Model` reference — an unsound conformance
    /// that told the compiler it was safe to move a context-bound object across
    /// isolation domains.
    let gebietID: UUID
    let score: Int

    var id: UUID { gebietID }
}

nonisolated enum ArchiveSearchEngine {
    /// Every keyword table is folded **at declaration**, so folded query tokens are
    /// compared against folded keywords. The old code compared folded tokens against
    /// raw literals and patched around it by hand-writing both spellings for some
    /// words — and missing others entirely, which is why "übermorgen" could never
    /// match anything.
    private static let openKeywords = Set(["offen", "niemand", "nachbesuch", "rot"].map(SearchText.fold))
    private static let joinedKeywords = Set(["dabei", "beitritt", "erfolg", "herz"].map(SearchText.fold))
    private static let earlyNoKeywords = Set(["frühes nein", "früh", "fruh", "frühes", "abgelehnt"].map(SearchText.fold))
    private static let lateNoKeywords = Set(["spätes nein", "spät", "spat", "spätes"].map(SearchText.fold))
    private static let doneKeywords = Set(["fertig", "abgeschlossen", "erledigt", "komplett"].map(SearchText.fold))

    private static let relativeDays: [(word: String, offset: Int)] = [
        ("heute", 0), ("morgen", 1), ("übermorgen", 2),
        ("gestern", -1), ("vorgestern", -2)
    ].map { (SearchText.fold($0.0), $0.1) }

    static func search(query: String, index: ArchiveIndex, order: [UUID]) -> [ArchiveSearchResult] {
        let tokens = SearchText.tokenize(query)
        guard !tokens.isEmpty else {
            return order.map { ArchiveSearchResult(gebietID: $0, score: 0) }
        }

        var results: [ArchiveSearchResult] = []
        results.reserveCapacity(order.count)
        for id in order {
            guard let entry = index.entry(for: id) else { continue }
            var total = 0
            var matchedAll = true
            for token in tokens {
                let score = score(token: token, entry: entry)
                if score == 0 { matchedAll = false; break }
                total += score
            }
            guard matchedAll else { continue }
            results.append(ArchiveSearchResult(gebietID: id, score: total))
        }
        // Stable: equal scores keep the incoming (newest-first) order.
        return results.enumerated()
            .sorted { lhs, rhs in
                lhs.element.score == rhs.element.score
                    ? lhs.offset < rhs.offset
                    : lhs.element.score > rhs.element.score
            }
            .map(\.element)
    }

    private static func score(token: String, entry: ArchiveEntry) -> Int {
        // Cheap, high-signal checks first: the relative-date table used to be the
        // very last check, so the most common query ("heute") only reached it after
        // scanning every address in the territory.
        if let match = relativeDays.first(where: { $0.word == token }) {
            let calendar = Gebiet.campaignCalendar
            guard let target = calendar.date(
                byAdding: .day,
                value: match.offset,
                to: calendar.startOfDay(for: .now)
            ) else { return 0 }
            let dates = [entry.day1Date, entry.day2Date].compactMap { $0 }
            return dates.contains(where: { calendar.isDate($0, inSameDayAs: target) }) ? 90 : 0
        }

        if openKeywords.contains(token) { return entry.overall.open > 0 ? 80 : 0 }
        if joinedKeywords.contains(token) { return entry.overall.joined > 0 ? 80 : 0 }
        if earlyNoKeywords.contains(token) { return entry.overall.earlyNo > 0 ? 70 : 0 }
        if lateNoKeywords.contains(token) { return entry.overall.lateNo > 0 ? 70 : 0 }
        if doneKeywords.contains(token) { return entry.isComplete ? 70 : 0 }

        if entry.dateText.contains(token) { return 60 }
        if entry.searchText.contains(token) {
            // A prefix hit is almost always the territory's own name.
            return entry.searchText.hasPrefix(token) ? 100 : 40
        }
        return 0
    }
}
