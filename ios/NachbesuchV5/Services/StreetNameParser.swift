import Foundation

/// Splits a free-form Austrian address into the part that names the street and the
/// part that names the door.
/// „Thaliastraße 12a/3“ → „Thaliastraße“ + „12a/3“, „Am Augarten 3“ → „Am Augarten“ + „3“.
nonisolated enum StreetNameParser {
    nonisolated static func street(from address: String) -> String {
        split(address).street
    }

    /// What identifies the door once the street is already known.
    ///
    /// The list groups by street and puts the name in the section header, so every
    /// row underneath repeating it — followed by a postal code and a city that are
    /// the same for the entire territory — is forty characters that push the one
    /// piece of new information onto a second line. `nil` when the address carries
    /// no number at all, so the caller can fall back to something that still names
    /// the row.
    nonisolated static func houseNumber(from address: String) -> String? {
        split(address).number
    }

    /// The address with the postal code and the city dropped: everything up to the
    /// first comma. Used where the street is *not* already on screen.
    nonisolated static func withoutLocality(_ address: String) -> String {
        head(of: address)
    }

    // MARK: Shared parse

    /// One tokenisation for both halves, so the street and the number can never
    /// disagree about where the address divides.
    private static func split(_ address: String) -> (street: String, number: String?) {
        let trimmed = head(of: address)
        guard !trimmed.isEmpty else { return (trimmed, nil) }

        // Splits on any whitespace, not just U+0020: geocoded and pasted addresses
        // regularly contain non-breaking spaces, which used to collapse the whole
        // string into one token.
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return (cleaned(trimmed), nil) }

        // The first token after the start that begins with a digit is the house
        // number; everything before it is the street, everything from it on is the
        // number and whatever qualifies it ("12a/3", "5 Stiege 2"). A leading number
        // is left alone so "12 Hauptstraße" stays intact.
        for index in tokens.indices.dropFirst() where tokens[index].first?.isNumber == true {
            let street = tokens[..<index].joined(separator: " ")
            guard !street.isEmpty else { break }
            // Deliberately not `cleaned`: that strips punctuation, and the slash in
            // "12a/3" is part of the door's name.
            let number = tokens[index...].joined(separator: " ")
            return (cleaned(street), number.isEmpty ? nil : number)
        }
        return (cleaned(trimmed), nil)
    }

    /// The app's own OSM importer emits "<Straße> <Nr>, <PLZ> <Ort>". Without
    /// truncating at the comma, an address with no house number ("Am Hof, 1010
    /// Wien") took the postal code for the house number and produced the street
    /// "Am Hof," — a trailing comma, and therefore a second section in the list
    /// sitting right next to the correct one.
    private static func head(of address: String) -> String {
        let head = address.split(separator: ",", maxSplits: 1).first.map(String.init) ?? address
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
