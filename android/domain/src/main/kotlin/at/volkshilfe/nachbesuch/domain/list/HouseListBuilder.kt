package at.volkshilfe.nachbesuch.domain.list

import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.MapPinSnapshotBuilder
import at.volkshilfe.nachbesuch.domain.model.OutcomeTally
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.revisit.RevisitPlanner
import java.text.Normalizer
import java.util.Locale
import kotlin.math.cos
import kotlin.math.sqrt

/**
 * A list row, as a pure value — ported from the iOS `HouseRowModel`.
 *
 * Deliberately holds no [House] reference. A row carrying a live entity means any
 * change to any house invalidates every row, which is exactly the recomposition
 * behaviour the iOS side rewrote this model to avoid.
 */
data class HouseRow(
    val id: String,
    val address: String,
    val note: String,
    val street: String,
    val markerOutcome: VisitOutcome?,
    val unitCount: Int,
    val completedCount: Int,
    val followUpCount: Int,
    val joinedCount: Int,
    val openCount: Int,
    val createdAt: Long,
    val searchText: String,
    val latitude: Double,
    val longitude: Double,
    /** When the most recent door of this house was recorded. */
    val recordedAt: Long?,
    /** The earliest return time booked on this house, when any door is "Später". */
    val nextRevisitAt: Long? = null,
    /** Metres from the user, when a position is known. */
    val distance: Double? = null
) {
    val isSingleDoor: Boolean get() = unitCount == 1

    val formattedDistance: String?
        get() = distance?.let { metres ->
            if (metres < 950) "${(metres / 10).toInt() * 10} m"
            else String.format(Locale.GERMAN, "%.1f km", metres / 1000)
        }

    /** What a screen reader reads instead of an emoji. */
    val accessibilityValue: String
        get() {
            val base = if (isSingleDoor) (markerOutcome?.germanTitle ?: "Noch kein Status")
            else "$completedCount von $unitCount Türen erfasst, $openCount offen"
            return nextRevisitAt?.let { "$base, zurück um ${RevisitPlanner.clockText(it)}" } ?: base
        }
}

/** The list's status filters, ported from the iOS `ListFilter`. */
enum class ListFilter(val id: String, val title: String) {
    ALL("all", "Alle"),
    OPEN("open", "Offen"),
    UNANSWERED("unanswered", "Ohne Status"),
    JOINED("joined", "Dabei");

    val emptyTitle: String
        get() = when (this) {
            ALL -> "Noch keine Häuser"
            OPEN -> "Keine offenen Nachbesuche"
            UNANSWERED -> "Alles eingetragen"
            JOINED -> "Noch keine Beitritte"
        }

    val emptyMessage: String
        get() = when (this) {
            ALL -> "Füge auf der Karte dein erstes Haus hinzu."
            OPEN -> "Für diesen Zeitraum ist nichts mehr offen."
            UNANSWERED -> "Jeder erfasste Haushalt hat bereits einen Status."
            JOINED -> "Hier erscheinen Haushalte, die dabei sind."
        }

    fun matches(row: HouseRow): Boolean = when (this) {
        ALL -> true
        OPEN -> row.openCount > 0
        UNANSWERED -> row.completedCount < row.unitCount
        JOINED -> row.joinedCount > 0
    }

    companion object {
        fun from(id: String?): ListFilter = entries.firstOrNull { it.id == id } ?: ALL
    }
}

/** One street's worth of rows. */
data class StreetSection(
    val id: String,
    val title: String,
    val rows: List<HouseRow>,
    val houseCount: Int,
    val unitCount: Int,
    val completedCount: Int,
    val openCount: Int
) {
    val progress: Double get() = if (unitCount > 0) (unitCount - openCount).coerceAtLeast(0).toDouble() / unitCount else 0.0
}

/** Diacritic-insensitive text folding, shared by the list and the archive. */
object SearchText {
    fun fold(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFD)
        .replace(Regex("\\p{Mn}+"), "")
        .lowercase(Locale.GERMAN)
        .replace("ß", "ss")

    fun tokenize(query: String): List<String> =
        fold(query).split(Regex("\\s+")).filter(String::isNotBlank)
}

/**
 * Builds the list corpus once per data change, off the main thread.
 *
 * Every function here is pure, so the whole visible behaviour of the list —
 * filtering, sorting, grouping, counts — is unit-testable without Compose.
 */
object HouseListBuilder {

    fun rows(houses: List<House>, scope: DayScope): List<HouseRow> = houses.map { house ->
        val doors = house.units
        val tally = OutcomeTally.from(doors, scope)
        val recordedAt = doors.mapNotNull { it.timestamp(scope) }.maxOrNull()
        val street = StreetNameParser.parse(house.address).first
        val searchable = buildString {
            append(house.address).append(' ').append(house.note).append(' ').append(street)
            doors.forEach { append(' ').append(it.label) }
        }
        HouseRow(
            id = house.id,
            address = house.address,
            note = house.note,
            street = street,
            // One implementation of the pin priority, shared with the map: a second
            // copy here is what let the list and the map disagree in Tag-2 mode.
            markerOutcome = MapPinSnapshotBuilder.markerOutcome(doors, scope),
            nextRevisitAt = doors.mapNotNull { it.displayRevisitAt(scope) }.minOrNull(),
            unitCount = doors.size,
            completedCount = tally.completed,
            followUpCount = tally.notHome,
            joinedCount = tally.joined,
            openCount = tally.open,
            createdAt = house.createdAt,
            searchText = SearchText.fold(searchable),
            latitude = house.latitude,
            longitude = house.longitude,
            recordedAt = recordedAt
        )
    }

    fun filter(rows: List<HouseRow>, filter: ListFilter, query: String): List<HouseRow> {
        val tokens = SearchText.tokenize(query)
        val matched =
            if (tokens.isEmpty()) rows
            else rows.filter { row -> tokens.all { row.searchText.contains(it) } }
        return if (filter == ListFilter.ALL) matched else matched.filter(filter::matches)
    }

    /** Field-tested default: open work first, then newest. */
    fun sort(rows: List<HouseRow>): List<HouseRow> =
        rows.sortedWith(compareByDescending<HouseRow> { it.openCount }.thenByDescending { it.createdAt })

    /**
     * Nearest first, measured from where you are standing.
     *
     * Equirectangular metres rather than a full geodesic: at city scale the error
     * is centimetres, and it avoids allocating a Location per row on every fix.
     */
    fun sortByDistance(rows: List<HouseRow>, originLat: Double, originLon: Double): List<HouseRow> {
        val latitudeScale = 110_540.0
        val longitudeScale = 111_320.0 * cos(Math.toRadians(originLat))
        return rows.map { row ->
            val dLat = (row.latitude - originLat) * latitudeScale
            val dLon = (row.longitude - originLon) * longitudeScale
            row.copy(distance = sqrt(dLat * dLat + dLon * dLon))
        }.sortedBy { it.distance ?: Double.MAX_VALUE }
    }

    fun sections(rows: List<HouseRow>): List<StreetSection> =
        rows.groupBy { it.street }
            .toSortedMap(String.CASE_INSENSITIVE_ORDER)
            .map { (street, streetRows) ->
                StreetSection(
                    id = "street:$street",
                    title = street,
                    rows = streetRows,
                    houseCount = streetRows.size,
                    unitCount = streetRows.sumOf { it.unitCount },
                    completedCount = streetRows.sumOf { it.completedCount },
                    openCount = streetRows.sumOf { it.openCount }
                )
            }

    fun counts(rows: List<HouseRow>): Map<ListFilter, Int> =
        ListFilter.entries.associateWith { filter ->
            if (filter == ListFilter.ALL) rows.size else rows.count(filter::matches)
        }
}
