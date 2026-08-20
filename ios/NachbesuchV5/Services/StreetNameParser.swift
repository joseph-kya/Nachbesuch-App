import Foundation

/// Extracts the street name from a free-form Austrian address.
/// „Thaliastraße 12a/3“ → „Thaliastraße“, „Am Augarten 3“ → „Am Augarten“.
nonisolated enum StreetNameParser {
    nonisolated static func street(from address: String) -> String {
        // The app's own OSM importer emits "<Straße> <Nr>, <PLZ> <Ort>". Without
        // truncating at the comma, an address with no house number ("Am Hof, 1010
        // Wien") took the postal code for the house number and produced the street
        // "Am Hof," — a trailing comma, and therefore a second section in the list
        // sitting right next to the correct one.
        let head = address.split(separator: ",", maxSplits: 1).first.map(String.init) ?? address
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Splits on any whitespace, not just U+0020: geocoded and pasted addresses
        // regularly contain non-breaking spaces, which used to collapse the whole
        // string into one token.
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return cleaned(trimmed) }

        // The first token after the start that begins with a digit is the house
        // number; everything before it is the street. A leading number is left alone
        // so "12 Hauptstraße" stays intact.
        for index in tokens.indices.dropFirst() where tokens[index].first?.isNumber == true {
            let street = tokens[..<index].joined(separator: " ")
            if !street.isEmpty { return cleaned(street) }
        }
        return cleaned(trimmed)
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
