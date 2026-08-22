package at.volkshilfe.nachbesuch.domain.list

/**
 * Extracts the street name and house number from a free-form Austrian address.
 * "Thaliastraße 12a/3" → "Thaliastraße" / "12a", "Am Augarten 3" → "Am Augarten" / "3".
 */
object StreetNameParser {

    fun parse(address: String): Pair<String, String?> {
        // The app's own OSM importer emits "<Straße> <Nr>, <PLZ> <Ort>". Without
        // truncating at the comma, an address whose number is followed by one
        // ("Am Hof 1, 1010 Wien") failed the old "number must end at whitespace"
        // rule, matched the postal code instead, and produced the street
        // "Am Hof 1" — so every house number became its own section in the list.
        val head = address.substringBefore(',')
        // Splits on any whitespace, not just U+0020: geocoded and pasted addresses
        // regularly contain non-breaking spaces, which collapse the whole string
        // into a single token otherwise.
        val trimmed = head.replace(' ', ' ').trim()
        if (trimmed.isEmpty()) return trimmed to null

        val tokens = trimmed.split(Regex("\\s+")).filter(String::isNotBlank)
        if (tokens.size <= 1) return cleaned(trimmed) to null

        // The first token after the start that begins with a digit is the house
        // number; everything before it is the street. A leading number is left
        // alone so "12 Hauptstraße" stays intact.
        for (index in 1 until tokens.size) {
            if (tokens[index].firstOrNull()?.isDigit() != true) continue
            val street = tokens.subList(0, index).joinToString(" ")
            // "12a/3" is house number 12a, door 3. The export's compact address
            // scheme has always carried only the house number, so the door suffix
            // is dropped here rather than changing that format.
            if (street.isNotEmpty()) return cleaned(street) to tokens[index].substringBefore('/')
        }
        return cleaned(trimmed) to null
    }

    private fun cleaned(value: String): String =
        value.trim().trim { it.isWhitespace() || (!it.isLetterOrDigit() && it != '.') }
}
