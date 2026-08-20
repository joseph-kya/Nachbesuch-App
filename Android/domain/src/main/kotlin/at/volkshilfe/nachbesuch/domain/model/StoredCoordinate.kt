package at.volkshilfe.nachbesuch.domain.model

import kotlinx.serialization.Serializable

@Serializable
data class StoredCoordinate(val latitude: Double, val longitude: Double) {
    val isPlausible: Boolean
        get() = latitude.isFinite() && longitude.isFinite() &&
            latitude in -90.0..90.0 && longitude in -180.0..180.0 &&
            !(latitude == 0.0 && longitude == 0.0)
}
