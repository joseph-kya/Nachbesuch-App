package at.volkshilfe.nachbesuch.domain.geo

import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate

object Centroid {
    fun polygon(points: List<StoredCoordinate>): StoredCoordinate? {
        val valid = points.filter(StoredCoordinate::isPlausible)
        if (valid.size < 3) return null
        var area2 = 0.0
        var latitude = 0.0
        var longitude = 0.0
        for (index in valid.indices) {
            val a = valid[index]
            val b = valid[(index + 1) % valid.size]
            val cross = a.longitude * b.latitude - b.longitude * a.latitude
            area2 += cross
            longitude += (a.longitude + b.longitude) * cross
            latitude += (a.latitude + b.latitude) * cross
        }
        if (kotlin.math.abs(area2) < 1e-12) return null
        val result = StoredCoordinate(latitude / (3.0 * area2), longitude / (3.0 * area2))
        return result.takeIf { it.isPlausible }
    }
}
