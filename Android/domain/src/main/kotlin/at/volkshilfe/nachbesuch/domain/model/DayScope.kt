package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable

@Serializable
enum class DayScope { COMBINED, DAY_1, DAY_2 }

fun Int.asDayScope(): DayScope = when (this) {
    1 -> DayScope.DAY_1
    2 -> DayScope.DAY_2
    else -> DayScope.COMBINED
}
