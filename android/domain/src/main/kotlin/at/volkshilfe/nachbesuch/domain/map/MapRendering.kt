package at.volkshilfe.nachbesuch.domain.map

import at.volkshilfe.nachbesuch.domain.model.VisitOutcome

enum class PinScale(
    /**
     * Diameter of the pin's head in dp.
     *
     * Lives here rather than inside the bitmap painter because two callers need
     * the same number: the painter that draws the head, and the hit test that
     * decides whether two pins are stacked on top of each other. A second copy
     * is how the two would drift apart.
     */
    val headDiameterDp: Float
) {
    FULL(34f), COMPACT(25f), DOT(15f)
}

/**
 * The same deterministic three-scale rule as iOS. The result depends only on the
 * current camera span, never on which direction the user crossed a threshold.
 */
object PinScalePolicy {
    fun scaleFor(metersAcross: Double): PinScale = when {
        metersAcross <= 1_400.0 -> PinScale.FULL
        metersAcross < 3_000.0 -> PinScale.COMPACT
        else -> PinScale.DOT
    }
}

data class PinAppearance(
    val outcome: VisitOutcome?,
    val text: String,
    val isSelected: Boolean,
    val scale: PinScale
)
