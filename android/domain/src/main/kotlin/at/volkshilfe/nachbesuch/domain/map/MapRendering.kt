package at.volkshilfe.nachbesuch.domain.map

import at.volkshilfe.nachbesuch.domain.model.VisitOutcome

enum class PinScale { FULL, COMPACT, DOT }

/** Hysteresis keeps the map readable near the threshold instead of flickering. */
object PinScalePolicy {
    fun scaleFor(metersAcross: Double, current: PinScale): PinScale = when (current) {
        PinScale.FULL -> if (metersAcross > 1_500.0) PinScale.COMPACT else PinScale.FULL
        PinScale.COMPACT -> when {
            metersAcross <= 1_300.0 -> PinScale.FULL
            metersAcross > 3_200.0 -> PinScale.DOT
            else -> PinScale.COMPACT
        }
        PinScale.DOT -> when {
            metersAcross <= 1_300.0 -> PinScale.FULL
            metersAcross <= 3_000.0 -> PinScale.COMPACT
            else -> PinScale.DOT
        }
    }
}

class ClusterGate(private var clustered: Boolean = false) {
    fun update(visibleSpanMeters: Double, visiblePinCount: Int): Boolean {
        clustered = if (clustered) {
            visibleSpanMeters > 2_000.0 || visiblePinCount > 800
        } else {
            visibleSpanMeters > 3_000.0 || visiblePinCount > 1_200
        }
        return clustered
    }
    val isClustered: Boolean get() = clustered
}

data class PinAppearance(
    val outcome: VisitOutcome?,
    val text: String,
    val isSelected: Boolean,
    val scale: PinScale
)
