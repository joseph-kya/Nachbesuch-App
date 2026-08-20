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
    fun build(houses: List<House>, scope: DayScope): PreparedMapSnapshot =
        PreparedMapSnapshot(houses.associate { house ->
            val tally = house.tally(scope)
            val outcomes = house.units.mapNotNull { it.displayOutcome(scope) }
            val hasRevisit = house.units.any {
                it.isPendingRevisit || it.displayOutcome(scope) == VisitOutcome.NOT_HOME
            }
            val marker = if (hasRevisit) VisitOutcome.NOT_HOME else outcomes.lastOrNull()
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
