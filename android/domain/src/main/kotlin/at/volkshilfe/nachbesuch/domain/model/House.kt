package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class House(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val address: String,
    val note: String = "",
    val latitude: Double,
    val longitude: Double,
    val isApartmentBuilding: Boolean = false,
    val gebietID: String,
    val dayID: String = gebietID,
    val units: List<DoorResult> = listOf(DoorResult(label = "Haushalt")),
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val isDamaged: Boolean = false
) {
    init { require(StoredCoordinate(latitude, longitude).isPlausible) { "Invalid house coordinate" } }

    val tally: OutcomeTally get() = OutcomeTally.from(units, DayScope.COMBINED)
    fun tally(scope: DayScope): OutcomeTally = OutcomeTally.from(units, scope)
    val hasOpenWork: Boolean get() = units.any { it.isOpen(DayScope.COMBINED) }

    fun recordOutcome(
        unitID: String,
        outcome: VisitOutcome?,
        scope: DayScope,
        now: Long = System.currentTimeMillis()
    ): House? {
        if (isDamaged || scope == DayScope.COMBINED) return null
        val changed = units.map { door ->
            if (door.id != unitID) door else when (scope) {
                DayScope.DAY_1 -> door.copy(outcome = outcome, updatedAt = outcome?.let { now })
                DayScope.DAY_2 -> door.copy(day2Outcome = outcome, day2UpdatedAt = outcome?.let { now })
                DayScope.COMBINED -> door
            }
        }
        if (changed == units) return this
        return copy(units = changed, updatedAt = monotonicTimestamp(now))
    }

    fun resizeApartment(count: Int, now: Long = System.currentTimeMillis()): House? {
        if (isDamaged) return null
        val target = count.coerceIn(2, 100)
        val next = units.toMutableList()
        while (next.size < target) next += DoorResult(label = "Tür ${next.size + 1}")
        while (next.size > target) next.removeLast()
        return copy(
            isApartmentBuilding = true,
            units = next.mapIndexed { index, door -> door.copy(label = if (index == 0 && !isApartmentBuilding) "Tür 1" else door.label) },
            updatedAt = monotonicTimestamp(now)
        )
    }

    private fun monotonicTimestamp(now: Long): Long = maxOf(now, updatedAt + 1L)
}
