package at.volkshilfe.nachbesuch.domain.revisit

import java.time.Instant
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One offered return time for a `VisitOutcome.LATER` door. */
data class RevisitSuggestion(
    val kind: Kind,
    /** Epoch millis, so it can go straight to the alarm scheduler. */
    val atMillis: Long
) {
    sealed interface Kind {
        /** "in 30 Minuten" — measured from the moment of tapping. */
        data class Relative(val minutes: Int) : Kind

        /** A fixed time of day, e.g. 18:00. */
        data class Clock(val hour: Int, val minute: Int) : Kind
    }

    val id: String get() = when (val value = kind) {
        is Kind.Relative -> "rel-${value.minutes}"
        is Kind.Clock -> "clock-${value.hour}-${value.minute}"
    }

    val title: String get() = when (val value = kind) {
        is Kind.Relative ->
            if (value.minutes % 60 == 0) "In ${value.minutes / 60} Std" else "In ${value.minutes} Min"
        is Kind.Clock -> String.format(Locale.GERMAN, "Um %02d:%02d", value.hour, value.minute)
    }

    /**
     * The resulting clock time, shown under a relative title so the user sees what
     * they are actually booking.
     */
    fun clockText(zone: ZoneId = ZoneId.systemDefault()): String = RevisitPlanner.clockText(atMillis, zone)
}

/**
 * Builds the shortlist of return times offered when a door is marked "Später".
 *
 * A literal port of the iOS `RevisitPlanner`, down to the constants: the two apps
 * are used side by side in the same team, and a suggestion that appears on one
 * phone and not the other reads as a bug. Pure and zone-injectable so the boundary
 * cases — late evening, a slot that has just passed, a relative offset landing on a
 * suggested clock slot — are unit tested rather than discovered in the field.
 */
object RevisitPlanner {
    /**
     * Offsets from "now". Rounded up to the next five minutes so the booked time
     * reads as a clock time a person would say out loud.
     */
    val relativeOffsets = listOf(30, 60, 120)

    /** The hours people are actually home. Only those still ahead are offered. */
    val clockSlots = listOf(17 to 0, 18 to 0, 19 to 0)

    /** Two clock slots at most, so the row never scrolls on a small phone. */
    const val MAXIMUM_CLOCK_SLOTS = 2

    /**
     * A suggestion is dropped when another one is already within this window —
     * offering "In 1 Std" and "Um 18:00" for the same minute is noise.
     */
    const val DUPLICATE_WINDOW_MILLIS = 10L * 60 * 1000

    private val formatter = DateTimeFormatter.ofPattern("HH:mm", Locale.GERMAN)

    fun clockText(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): String =
        formatter.format(Instant.ofEpochMilli(epochMillis).atZone(zone))

    fun suggestions(
        now: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault()
    ): List<RevisitSuggestion> {
        val result = mutableListOf<RevisitSuggestion>()

        for (minutes in relativeOffsets) {
            result += RevisitSuggestion(
                kind = RevisitSuggestion.Kind.Relative(minutes),
                atMillis = roundUpToFiveMinutes(now + minutes * 60_000L, zone)
            )
        }

        var used = 0
        for ((hour, minute) in clockSlots) {
            if (used == MAXIMUM_CLOCK_SLOTS) break
            val slot = Instant.ofEpochMilli(now).atZone(zone)
                .with(LocalTime.of(hour, minute))
                .toInstant().toEpochMilli()
            // A slot that has already passed today is not a suggestion; rolling it
            // to tomorrow would silently book a visit for the next day.
            if (slot <= now) continue
            if (result.any { kotlin.math.abs(it.atMillis - slot) < DUPLICATE_WINDOW_MILLIS }) continue
            result += RevisitSuggestion(RevisitSuggestion.Kind.Clock(hour, minute), slot)
            used += 1
        }

        return result.sortedBy { it.atMillis }
    }

    /**
     * The initial value of the free time picker: the first suggestion, or half an
     * hour out when the day is too late for any of them.
     */
    fun defaultTime(
        now: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault()
    ): Long = suggestions(now, zone).firstOrNull()?.atMillis
        ?: roundUpToFiveMinutes(now + 30 * 60_000L, zone)

    /**
     * Turns an hour and minute picked on the wheel into an instant.
     *
     * A time earlier than [now] can only mean tomorrow, but booking tomorrow behind
     * the user's back is worse than refusing — the caller gets `null` and says so.
     */
    fun instantFor(
        hour: Int,
        minute: Int,
        now: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault()
    ): Long? {
        val candidate = Instant.ofEpochMilli(now).atZone(zone)
            .with(LocalTime.of(hour, minute))
            .withSecond(0).withNano(0)
            .toInstant().toEpochMilli()
        return candidate.takeIf { it > now }
    }

    fun roundUpToFiveMinutes(epochMillis: Long, zone: ZoneId = ZoneId.systemDefault()): Long {
        val moment: ZonedDateTime = Instant.ofEpochMilli(epochMillis).atZone(zone).withSecond(0).withNano(0)
        val remainder = moment.minute % 5
        val rounded = if (remainder == 0) moment else moment.plusMinutes((5 - remainder).toLong())
        return rounded.toInstant().toEpochMilli()
    }
}

/**
 * "Später · 18:00" for a booked door, plain [VisitOutcome.germanTitle] for
 * everything else. The iOS twin is `VisitOutcome.label(revisitAt:)`.
 *
 * An extension rather than a member so the `model` package keeps knowing nothing
 * about time formatting.
 */
fun at.volkshilfe.nachbesuch.domain.model.VisitOutcome.label(
    revisitAt: Long?,
    zone: ZoneId = ZoneId.systemDefault()
): String {
    if (this != at.volkshilfe.nachbesuch.domain.model.VisitOutcome.LATER || revisitAt == null) return germanTitle
    return "$germanTitle · ${RevisitPlanner.clockText(revisitAt, zone)}"
}
