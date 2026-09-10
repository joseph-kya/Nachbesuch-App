package at.volkshilfe.nachbesuch.domain.archive

import at.volkshilfe.nachbesuch.domain.stats.TerritorySummary
import java.time.Instant
import java.time.ZoneId

/**
 * Scored keyword search over territory summaries, ported from the iOS
 * ArchiveSearchEngine: outcome keywords map onto tally predicates, relative
 * day words ("heute", "morgen", …) map onto campaign dates, and results are
 * ranked by a stable score instead of list order.
 */
object ArchiveSearchEngine {

    private data class Token(val text: String, val score: Int, val matches: (TerritorySummary) -> Boolean)

    fun search(query: String, territories: List<TerritorySummary>): List<TerritorySummary> {
        val tokens = tokenize(query)
        if (tokens.isEmpty()) return territories
        val scored = territories.map { territory ->
            territory to tokens.fold(0) { total, token -> if (token.matches(territory)) total + token.score else total }
        }.filter { it.second > 0 }
        return scored.sortedWith(
            compareByDescending<Pair<TerritorySummary, Int>> { it.second }
                .thenComparingTerritoryName()
        ).map { it.first }
    }

    private fun Comparator<Pair<TerritorySummary, Int>>.thenComparingTerritoryName(): Comparator<Pair<TerritorySummary, Int>> =
        thenComparator { a, b -> a.first.territory.displayName.compareTo(b.first.territory.displayName, ignoreCase = true) }

    private fun tokenize(query: String): List<Token> {
        val today = System.currentTimeMillis()
        val normalized = query.replace('ä', 'a').replace('ö', 'o').replace('ü', 'u')
            .lowercase(java.util.Locale.GERMAN)
        return normalized.split(WHITESPACE).filter(String::isNotBlank).flatMap { raw ->
            val token = raw.trim('*', '?')
            when {
                token in OPEN_WORDS -> listOf(Token(raw, 100, ::hasAnyOpen))
                token in DONE_WORDS -> listOf(Token(raw, 100, ::fullyDone))
                token in JOINED_WORDS -> listOf(Token(raw, 90, ::hasJoined))
                token in EARLY_WORDS -> listOf(Token(raw, 80, ::hasEarlyNo))
                token in LATE_WORDS -> listOf(Token(raw, 80, ::hasLateNo))
                token in NOT_HOME_WORDS -> listOf(Token(raw, 90, ::hasNotHome))
                token in REVISIT_WORDS -> listOf(Token(raw, 95, ::hasPendingRevisits))
                token == "zweitage" || token == "2tage" -> listOf(Token(raw, 70, ::isTwoDay))
                token == "heute" -> listOf(dateToken(raw, 120, today, 0))
                token == "gestern" -> listOf(dateToken(raw, 110, today, -1))
                token == "vorgestern" -> listOf(dateToken(raw, 100, today, -2))
                token == "morgen" -> listOf(dateToken(raw, 120, today, 1))
                token == "uebermorgen" || token == "ubermorgen" -> listOf(dateToken(raw, 110, today, 2))
                else -> textTokens(token)
            }
        }
    }

    private fun textTokens(token: String): List<Token> = listOf(
        Token(token, 80, { summary -> normalizeText(summary.searchText).split(WHITESPACE).contains(token) }),
        Token(token, 40, { summary -> containsWord(summary.searchText, token) }),
        Token(token, 25, { summary -> normalizeText(summary.searchText).contains(token) }),
        Token(token, 30, { summary -> token.toIntOrNull()?.let { count -> count == summary.houseCount } == true })
    )

    private fun dateToken(text: String, score: Int, referenceMillis: Long, dayOffset: Long): Token {
        val targetDay = startOfDay(referenceMillis) + dayOffset * DAY_MILLIS
        return Token(text, score, { summary ->
            startOfDay(summary.territory.day1Date) == targetDay ||
                summary.territory.day2Date?.let { startOfDay(it) == targetDay } == true
        })
    }

    private fun hasAnyOpen(summary: TerritorySummary) = summary.bilanz.overall.open > 0
    private fun fullyDone(summary: TerritorySummary) =
        summary.bilanz.overall.unitCount > 0 && summary.bilanz.overall.open == 0
    private fun hasJoined(summary: TerritorySummary) = summary.bilanz.overall.joined > 0
    private fun hasEarlyNo(summary: TerritorySummary) = summary.bilanz.overall.earlyNo > 0
    private fun hasLateNo(summary: TerritorySummary) = summary.bilanz.overall.lateNo > 0
    private fun hasNotHome(summary: TerritorySummary) = summary.bilanz.overall.notHome > 0
    private fun hasPendingRevisits(summary: TerritorySummary) = summary.bilanz.pendingRevisits > 0
    private fun isTwoDay(summary: TerritorySummary) = summary.territory.isTwoDay

    private fun containsWord(haystack: String, needle: String): Boolean =
        normalizeText(haystack).split(WHITESPACE).any { word -> word.startsWith(needle) }

    private fun normalizeText(value: String): String = value
        .replace('ä', 'a').replace('ö', 'o').replace('ü', 'u')
        .replace("ß", "ss")
        .lowercase(java.util.Locale.GERMAN)

    private val WHITESPACE = Regex("\\s+")

    private val OPEN_WORDS = setOf("offen", "open")
    private val DONE_WORDS = setOf("fertig", "erledigt", "done", "komplett")
    private val JOINED_WORDS = setOf("dabei", "beitritt", "joined")
    private val EARLY_WORDS = setOf("abblocker", "fruh", "earlyno", "fruher", "fruhe")
    private val LATE_WORDS = setOf("spat", "lateno", "spater")
    private val NOT_HOME_WORDS = setOf("niemand", "nichtda", "nothome", "abwesend")
    private val REVISIT_WORDS = setOf("nachbesuch", "revisit", "wiederkommen", "2termin")

    private const val DAY_MILLIS = 24L * 60 * 60 * 1000

    private fun startOfDay(epochMillis: Long): Long =
        Instant.ofEpochMilli(epochMillis).atZone(ZoneId.systemDefault()).toLocalDate().toEpochDay() * DAY_MILLIS
}
