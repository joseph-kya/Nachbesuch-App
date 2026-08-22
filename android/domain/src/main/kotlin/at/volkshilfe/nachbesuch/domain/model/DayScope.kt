package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable

@Serializable
enum class DayScope { COMBINED, DAY_1, DAY_2 }

fun Int.asDayScope(): DayScope = when (this) {
    1 -> DayScope.DAY_1
    2 -> DayScope.DAY_2
    else -> DayScope.COMBINED
}

/**
 * The campaign day a write in this scope lands on, mirroring the iOS
 * `DayScope.writeTargetDay`. `COMBINED` is a filter, never a write target, so it
 * resolves to day 1 — the same fallback the write paths already use.
 */
val DayScope.writeTargetDay: Int
    get() = if (this == DayScope.DAY_2) 2 else 1
