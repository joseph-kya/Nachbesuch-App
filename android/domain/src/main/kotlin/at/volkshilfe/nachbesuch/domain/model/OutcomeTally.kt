package at.volkshilfe.nachbesuch.domain.model

data class OutcomeTally(
    val unitCount: Int = 0,
    val completed: Int = 0,
    val open: Int = 0,
    val earlyNo: Int = 0,
    val lateNo: Int = 0,
    val joined: Int = 0,
    val notHome: Int = 0,
    /**
     * Doors postponed to a concrete time. Counted separately from [notHome]
     * because "come back at 18:00" and "come back some time" are different jobs.
     */
    val later: Int = 0
) {
    /** Compatibility alias for callers that only need the number of doors. */
    val total: Int get() = unitCount
    val isComplete: Boolean get() = unitCount > 0 && completed == unitCount
    val completionFraction: Double get() = if (unitCount == 0) 0.0 else completed.toDouble() / unitCount
    val unansweredCount: Int get() = (unitCount - completed).coerceAtLeast(0)

    operator fun plus(other: OutcomeTally) = OutcomeTally(
        unitCount + other.unitCount, completed + other.completed, open + other.open,
        earlyNo + other.earlyNo, lateNo + other.lateNo, joined + other.joined,
        notHome + other.notHome, later + other.later
    )

    companion object {
        fun from(doors: Iterable<DoorResult>, scope: DayScope, recordedOnly: Boolean = false): OutcomeTally {
            var total = 0
            var completed = 0
            var open = 0
            var earlyNo = 0
            var lateNo = 0
            var joined = 0
            var notHome = 0
            var later = 0
            for (door in doors) {
                val outcome = if (recordedOnly) door.result(scope) else door.displayOutcome(scope)
                total++
                if (outcome != null) completed++
                if (door.isOpen(scope)) open++
                when (outcome) {
                    VisitOutcome.EARLY_NO -> earlyNo++
                    VisitOutcome.LATE_NO -> lateNo++
                    VisitOutcome.JOINED -> joined++
                    VisitOutcome.NOT_HOME -> notHome++
                    VisitOutcome.LATER -> later++
                    null -> Unit
                }
            }
            return OutcomeTally(total, completed, open, earlyNo, lateNo, joined, notHome, later)
        }
    }
}
