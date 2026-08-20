package at.volkshilfe.nachbesuch.domain.archive

import java.text.Normalizer

object ArchiveSearch {
    fun normalize(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFD)
        .replace("\\p{Mn}+".toRegex(), "")
        .lowercase()
        .replace('ß', 's')

    fun matches(query: String, fields: Iterable<String>): Boolean {
        val tokens = normalize(query).split(Regex("\\s+")) .filter(String::isNotBlank)
        if (tokens.isEmpty()) return true
        val haystack = normalize(fields.joinToString(" "))
        return tokens.all(haystack::contains)
    }
}
