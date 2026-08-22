package at.volkshilfe.nachbesuch.domain.model

data class MapPinSnapshot(
    val id: String,
    val address: String,
    val latitude: Double,
    val longitude: Double,
    val markerOutcome: VisitOutcome?,
    val unitCount: Int,
    val completedCount: Int,
    val followUpCount: Int,
    val joinedCount: Int,
    val earlyNoCount: Int,
    val lateNoCount: Int
) {
    val markerText: String get() = if (unitCount <= 1) markerOutcome?.emoji ?: "•" else "$completedCount/$unitCount"
    val hasOpenWork: Boolean get() = followUpCount > 0 || completedCount < unitCount
}

data class PreparedMapSnapshot(val pinsByID: Map<String, MapPinSnapshot>) {
    companion object { val empty = PreparedMapSnapshot(emptyMap()) }
}

object MapPinSnapshotBuilder {
    /**
     * Pin priority identical to iOS OutcomeTally.markerOutcome: a booked return
     * time wins, then any visible "not home", then a join, else the last displayed
     * result. A pending day-2 revisit displays as nil in Tag-2 scope, so it
     * deliberately does not force a red pin there.
     *
     * "Später" outranks "niemand da" because it is the more specific instruction,
     * and the one with a deadline attached.
     */
    fun markerOutcome(units: List<DoorResult>, scope: DayScope): VisitOutcome? {
        val outcomes = units.mapNotNull { it.displayOutcome(scope) }
        return when {
            VisitOutcome.LATER in outcomes -> VisitOutcome.LATER
            VisitOutcome.NOT_HOME in outcomes -> VisitOutcome.NOT_HOME
            VisitOutcome.JOINED in outcomes -> VisitOutcome.JOINED
            else -> outcomes.lastOrNull()
        }
    }

    fun build(houses: List<House>, scope: DayScope): PreparedMapSnapshot =
        PreparedMapSnapshot(houses.associate { house ->
            val tally = house.tally(scope)
            val hasRevisit = house.units.any {
                it.isPendingRevisit || it.displayOutcome(scope) == VisitOutcome.NOT_HOME
            }
            val marker = markerOutcome(house.units, scope)
            house.id to MapPinSnapshot(
                id = house.id, address = house.address, latitude = house.latitude,
                longitude = house.longitude, markerOutcome = marker,
                unitCount = tally.unitCount, completedCount = tally.completed,
                followUpCount = house.units.count {
                    it.isPendingRevisit || it.displayOutcome(scope) == VisitOutcome.NOT_HOME
                }, joinedCount = tally.joined,
                earlyNoCount = tally.earlyNo, lateNoCount = tally.lateNo
            )
        })
}
