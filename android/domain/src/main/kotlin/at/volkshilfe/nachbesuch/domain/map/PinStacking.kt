package at.volkshilfe.nachbesuch.domain.map

/**
 * Decides which pins are stacked on top of a tapped one, in screen space.
 *
 * Pure so the rule can be tested without a map: the projection belongs to
 * Google's SDK, but "is this pin's centre hidden under that one's head" is the
 * app's own decision and the part that can be wrong.
 */
object PinStacking {

    data class Point(val x: Float, val y: Float)

    /**
     * How close two pin centres must be to count as stacked.
     *
     * 30% of the head diameter, matching iOS. Merely adjacent pins overlap at
     * street zoom but each still exposes enough of itself to be tapped; only a
     * pin whose centre sits under another's head is genuinely unreachable.
     */
    fun radiusPx(scale: PinScale, density: Float): Float = scale.headDiameterDp * 0.3f * density

    /**
     * The tapped id first, then any whose centre lies within [radiusPx] of it.
     *
     * Order matters: the sheet lists the pin actually under the finger at the
     * top, so the common case stays one tap away.
     */
    fun idsAt(houseID: String, points: Map<String, Point>, radiusPx: Float): List<String> {
        val origin = points[houseID] ?: return listOf(houseID)
        val radiusSquared = radiusPx * radiusPx
        val others = points.entries
            .filter { (id, point) ->
                if (id == houseID) return@filter false
                val dx = point.x - origin.x
                val dy = point.y - origin.y
                dx * dx + dy * dy <= radiusSquared
            }
            .map { it.key }
            .sorted()
        return listOf(houseID) + others
    }
}
