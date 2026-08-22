package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable

@Serializable
data class StoredCoordinate(val latitude: Double, val longitude: Double) {
    // Matches the iOS null-island band: a ~11 m box around (0, 0) is where
    // "no fix yet" defaults land, so anything in it is treated as missing data.
    val isPlausible: Boolean
        get() = latitude.isFinite() && longitude.isFinite() &&
            latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
            !(kotlin.math.abs(latitude) < 0.0001 && kotlin.math.abs(longitude) < 0.0001)
}
