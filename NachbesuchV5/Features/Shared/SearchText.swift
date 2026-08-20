import Foundation

/// Text normalisation shared by every search in the app.
nonisolated enum SearchText {
    /// Diacritic- and case-insensitive, so "modling" finds "Mödling".
    nonisolated static func fold(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "de_AT")
        )
    }

    /// Splits a query into folded tokens. All tokens must match.
    nonisolated static func tokenize(_ query: String) -> [String] {
        // Folding happens once here, and every keyword table is folded at
        // declaration — comparing a raw literal against a folded token is why
        // "übermorgen" could never match anything.
        fold(query)
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }
}
