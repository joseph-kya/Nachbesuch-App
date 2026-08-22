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
        fun from(doors: Iterable<DoorResult>, scope: DayScope): OutcomeTally {
            var tally = OutcomeTally()
            for (door in doors) {
                // Display outcome intentionally looks across the two-day window:
                // a result recorded on day one remains completed on day two,
                // while a pending "not home" door is still open on day two.
                val outcome = door.displayOutcome(scope)
                tally = tally.copy(
                    unitCount = tally.unitCount + 1,
                    completed = tally.completed + if (outcome != null) 1 else 0,
                    open = tally.open + if (door.isOpen(scope)) 1 else 0,
                    earlyNo = tally.earlyNo + if (outcome == VisitOutcome.EARLY_NO) 1 else 0,
                    lateNo = tally.lateNo + if (outcome == VisitOutcome.LATE_NO) 1 else 0,
                    joined = tally.joined + if (outcome == VisitOutcome.JOINED) 1 else 0,
                    notHome = tally.notHome + if (outcome == VisitOutcome.NOT_HOME) 1 else 0,
                    later = tally.later + if (outcome == VisitOutcome.LATER) 1 else 0
                )
            }
            return tally
        }
    }
}
