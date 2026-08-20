package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class DoorResult(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val label: String,
    val outcome: VisitOutcome? = null,
    val updatedAt: Long? = null,
    val day2Outcome: VisitOutcome? = null,
    val day2UpdatedAt: Long? = null
) {
    /** Strict result for statistics. Day 2 never falls back to day 1. */
    fun result(on: DayScope): VisitOutcome? = when (on) {
        DayScope.DAY_1 -> outcome
        DayScope.DAY_2 -> day2Outcome
        DayScope.COMBINED -> finalOutcome
    }

    val finalOutcome: VisitOutcome? get() = day2Outcome ?: outcome

    /** Result actually recorded in the requested report scope. */
    fun recordedOutcome(inScope: DayScope): VisitOutcome? = result(inScope)

    /** Display semantics keep a pending day-2 revisit visibly open. */
    fun displayOutcome(inScope: DayScope): VisitOutcome? = when (inScope) {
        DayScope.DAY_1 -> outcome
        DayScope.DAY_2 -> day2Outcome ?: if (outcome == VisitOutcome.NOT_HOME) null else outcome
        DayScope.COMBINED -> finalOutcome
    }

    val isPendingRevisit: Boolean get() = outcome == VisitOutcome.NOT_HOME && day2Outcome == null

    fun isOpen(inScope: DayScope): Boolean = when (inScope) {
        DayScope.DAY_1 -> outcome == null || outcome == VisitOutcome.NOT_HOME
        DayScope.DAY_2 -> isPendingRevisit || (outcome == null && day2Outcome == null)
        DayScope.COMBINED -> finalOutcome == null || finalOutcome == VisitOutcome.NOT_HOME
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
