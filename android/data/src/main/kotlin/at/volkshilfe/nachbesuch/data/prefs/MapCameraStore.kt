package at.volkshilfe.nachbesuch.data.prefs

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first

private val Context.mapPreferences by preferencesDataStore("map-camera")

data class SavedCamera(val latitude: Double, val longitude: Double, val zoom: Double)

class MapCameraStore(private val context: Context) {
    private object Keys {
        val latitude = doublePreferencesKey("latitude")
        val longitude = doublePreferencesKey("longitude")
        val zoom = doublePreferencesKey("zoom")
        val didEverCenter = booleanPreferencesKey("didEverCenterOnUser")
    }

    suspend fun restore(): SavedCamera? = context.mapPreferences.data.first().let { values ->
        val lat = values[Keys.latitude] ?: return@let null
        val lon = values[Keys.longitude] ?: return@let null
        SavedCamera(lat, lon, (values[Keys.zoom] ?: 14.5).coerceIn(2.0, 21.0))
    }

    suspend fun record(camera: SavedCamera) {
        context.mapPreferences.edit { values ->
            values[Keys.latitude] = camera.latitude
            values[Keys.longitude] = camera.longitude
            values[Keys.zoom] = camera.zoom.coerceIn(2.0, 21.0)
        }
    }

    suspend fun consumeInitialCentre(latitude: Double, longitude: Double): SavedCamera? {
        var result: SavedCamera? = null
        context.mapPreferences.edit { values ->
            if (values[Keys.didEverCenter] != true) {
                values[Keys.didEverCenter] = true
                result = SavedCamera(latitude, longitude, 16.0)
                values[Keys.latitude] = latitude
                values[Keys.longitude] = longitude
                values[Keys.zoom] = 16.0
            }
        }
        return result
    }
}
