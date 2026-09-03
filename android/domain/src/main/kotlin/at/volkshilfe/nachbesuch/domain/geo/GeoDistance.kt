package at.volkshilfe.nachbesuch.domain.geo

import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate

/**
 * Equirectangular metres between two coordinates. At city scale the error is
 * centimetres, and it avoids allocating a location object per comparison.
 *
 * Formerly `RoutePlanner.metres`: the planner is gone (same decision as iOS —
 * choosing the next house stays manual), but the distance math is shared by
 * the duplicate check and the visible-width computation, so it lives here now.
 */
object GeoDistance {
    fun metres(a: StoredCoordinate, b: StoredCoordinate): Double {
        val latScale = 110_540.0
        val lonScale = 111_320.0 * kotlin.math.cos(Math.toRadians((a.latitude + b.latitude) / 2.0))
        return kotlin.math.hypot((a.latitude - b.latitude) * latScale, (a.longitude - b.longitude) * lonScale)
    }

    fun metresSquared(a: StoredCoordinate, b: StoredCoordinate): Double {
        val latScale = 110_540.0
        val lonScale = 111_320.0 * kotlin.math.cos(Math.toRadians((a.latitude + b.latitude) / 2.0))
        val lat = (a.latitude - b.latitude) * latScale
        val lon = (a.longitude - b.longitude) * lonScale
        return lat * lat + lon * lon
    }
}
