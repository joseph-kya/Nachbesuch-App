package at.volkshilfe.nachbesuch.domain.naming

import java.text.Normalizer

/**
 * Pure naming rules for territories, ported from the iOS GebietNameAllocator:
 * a plain place name while it is unique, sequential numbering as soon as a
 * duplicate place appears (the existing plain Gebiet is renamed to "<Ort> 1",
 * the new one receives the next free number).
 */
object GebietNameAllocator {
    data class NameAssignment(
        val newName: String,
        /** When non-null, an existing plain-named territory must be renamed. */
        val renameOfExistingOld: String?,
        val renameOfExistingNew: String?
    )

    /** Case-, diacritic- and width-insensitive comparison form. */
    fun fold(text: String): String = Normalizer.normalize(text, Normalizer.Form.NFD)
        .replace(Regex("\\p{Mn}+"), "")
        .replace('ß', 's')
        // Width folding: full-width latin letters/digits collapse to ASCII.
        .map { c ->
            if (c.code in 0xFF01..0xFF5E) (c.code - 0xFEE0).toChar()
            else if (c == '　') ' '
            else c
        }
        .joinToString("")
        .lowercase()
        .trim()

    /** Placeholder names that carry no information about where the territory is. */
    fun isGenericName(name: String): Boolean {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return true
        if (trimmed == "Tagesrunde" || trimmed == "Neues Gebiet") return true
        if (trimmed.startsWith("Gebiet vom")) return true
        return exactNumberedSuffix(base = "Gebiet", candidate = trimmed) != null
    }

    private fun exactNumberedSuffix(base: String, candidate: String): Int? {
        val foldedBase = fold(base)
        val folded = fold(candidate)
        if (!folded.startsWith(foldedBase)) return null
        val remainder = folded.drop(foldedBase.length)
        if (remainder.isEmpty()) return 1
        if (!remainder.startsWith(" ")) return null
        return remainder.drop(1).trim().toIntOrNull() ?: return null
    }

    fun assignName(baseName: String, existingNames: List<String>): NameAssignment {
        val base = baseName.trim().ifEmpty { "Gebiet" }

        val usedNumbers = mutableSetOf<Int>()
        var plainMatch: String? = null

        for (raw in existingNames) {
            val name = raw.trim()
            if (name.isEmpty()) continue
            val number = exactNumberedSuffix(base = base, candidate = name) ?: continue
            if (fold(name) == fold(base)) {
                // A plain name occupies the un-numbered slot, not number 1.
                if (plainMatch == null) plainMatch = name
            } else {
                usedNumbers += number
            }
        }

        if (usedNumbers.isEmpty() && plainMatch == null) {
            return NameAssignment(base, null, null)
        }

        val existingPlain = plainMatch
            ?: return NameAssignment("${base} ${(usedNumbers.maxOrNull() ?: 0) + 1}", null, null)

        // A plain duplicate exists: it moves to the first free slot, the new
        // territory takes the number after the highest used one.
        var renameNumber = 1
        while (renameNumber in usedNumbers) renameNumber++
        usedNumbers += renameNumber
        val next = (usedNumbers.maxOrNull() ?: 0) + 1
        return NameAssignment(
            newName = "$base $next",
            renameOfExistingOld = existingPlain,
            renameOfExistingNew = "$base $renameNumber"
        )
    }
}
