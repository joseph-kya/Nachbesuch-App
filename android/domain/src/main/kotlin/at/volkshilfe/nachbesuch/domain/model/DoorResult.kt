package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class DoorResult(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val label: String,
    val outcome: VisitOutcome? = null,
    val updatedAt: Long? = null,
    /**
     * When to come back, for a [VisitOutcome.LATER] result on day 1. `null` for
     * every other outcome.
     *
     * Added after the storage format froze. It is a *new optional key*, which both
     * this reader (`ignoreUnknownKeys`) and iOS's `JSONDecoder` treat as absent →
     * `null`, so blobs written by earlier builds still decode and blobs written by
     * this build still open in them.
     */
    val revisitAt: Long? = null,
    val day2Outcome: VisitOutcome? = null,
    val day2UpdatedAt: Long? = null,
    /** The day-2 twin of [revisitAt]. */
    val day2RevisitAt: Long? = null
) {
    /** Strict result for statistics. Day 2 never falls back to day 1. */
    fun result(on: DayScope): VisitOutcome? = when (on) {
        DayScope.DAY_1 -> outcome
        DayScope.DAY_2 -> day2Outcome
        DayScope.COMBINED -> finalOutcome
    }

    val finalOutcome: VisitOutcome? get() = day2Outcome ?: outcome

    /** The agreed return time recorded on the given day. */
    fun revisitTime(inScope: DayScope): Long? = when (inScope) {
        DayScope.DAY_1 -> revisitAt
        DayScope.DAY_2 -> day2RevisitAt
        DayScope.COMBINED -> finalRevisitAt
    }

    /**
     * The return time that goes with [finalOutcome], so a pin or row never shows a
     * day-1 time next to a day-2 status.
     */
    val finalRevisitAt: Long? get() = if (day2Outcome == null) revisitAt else day2RevisitAt

    /** Result actually recorded in the requested report scope. */
    fun recordedOutcome(inScope: DayScope): VisitOutcome? = result(inScope)

    /** Display semantics keep a pending day-2 revisit visibly open. */
    fun displayOutcome(inScope: DayScope): VisitOutcome? = when (inScope) {
        DayScope.DAY_1 -> outcome
        DayScope.DAY_2 -> day2Outcome ?: if (outcome?.isOpenWork == true) null else outcome
        DayScope.COMBINED -> finalOutcome
    }

    /** The return time belonging to [displayOutcome]. */
    fun displayRevisitAt(inScope: DayScope): Long? = when (inScope) {
        DayScope.DAY_1 -> revisitAt.takeIf { outcome == VisitOutcome.LATER }
        DayScope.DAY_2 -> day2RevisitAt.takeIf { day2Outcome == VisitOutcome.LATER }
        DayScope.COMBINED -> finalRevisitAt.takeIf { finalOutcome == VisitOutcome.LATER }
    }

    val isPendingRevisit: Boolean get() = outcome?.isOpenWork == true && day2Outcome == null

    fun isOpen(inScope: DayScope): Boolean = when (inScope) {
        DayScope.DAY_1 -> outcome == null || outcome.isOpenWork
        DayScope.DAY_2 -> isPendingRevisit || (outcome == null && day2Outcome == null)
        DayScope.COMBINED -> finalOutcome == null || finalOutcome!!.isOpenWork
    }

    fun timestamp(inScope: DayScope): Long? = when (inScope) {
        DayScope.DAY_1 -> updatedAt
        DayScope.DAY_2, DayScope.COMBINED -> day2UpdatedAt ?: updatedAt
    }

    // Compatibility helper for UI code that uses the historical 0/1/2 picker.
    // New code should use result/displayOutcome explicitly.
    @Deprecated("Use result(scope) or displayOutcome(scope)")
    fun outcome(dayScope: Int): VisitOutcome? = displayOutcome(dayScope.asDayScope())
}
