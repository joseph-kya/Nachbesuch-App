package at.volkshilfe.nachbesuch.domain.list

object StreetNameParser {
    private val number = Regex("(?:^|\\s)(\\d+[A-Za-z]?)(?:\\s|/|$)")

    fun parse(address: String): Pair<String, String?> {
        val clean = address.replace('\u00A0', ' ').trim().replace(Regex("\\s+"), " ")
        val match = number.find(clean) ?: return clean to null
        val street = clean.substring(0, match.range.first).trim().trimEnd(',', ';')
        val numberText = match.groupValues[1]
        return (street.ifEmpty { clean }) to numberText
    }
}
