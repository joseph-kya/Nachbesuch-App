package at.volkshilfe.nachbesuch.data.prefs

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.route.PlannedRoute
import kotlinx.coroutines.flow.first
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

private val Context.routePreferences by preferencesDataStore("route-store")

/**
 * Persists the planned route per territory, mirroring the iOS RouteStore:
 * routes survive tab switches and process death, skipped stops stay skipped,
 * and restoring never needs to refetch the walking network because the drawn
 * legs are persisted too.
 */
class RouteStore(private val context: Context) {
    private val json = Json { ignoreUnknownKeys = true }

    @Serializable
    private data class PersistedLeg(val points: List<Double>)

    @Serializable
    private data class PersistedRoute(
        val startLatitude: Double,
        val startLongitude: Double,
        /** Visit order first, then every skipped stop in skip order. */
        val stopIDs: List<String>,
        val skippedIDs: List<String>,
        /** Flat [lat, lon, lat, lon, …] per leg so no coordinates are lost. */
        val legs: List<PersistedLeg>,
        val followsStreets: Boolean,
        val status: String? = null
    )

    data class RestoredRoute(
        val route: PlannedRoute,
        val order: List<String>,
        val skipped: List<String>,
        val status: String?
    )

    suspend fun save(
        gebietID: String,
        route: PlannedRoute?,
        order: List<String>,
        skipped: List<String>,
        status: String?
    ) {
        val key = keyFor(gebietID)
        if (route == null || order.isEmpty()) {
            context.routePreferences.edit { values -> values.remove(key) }
            return
        }
        val persisted = PersistedRoute(
            startLatitude = route.start.latitude,
            startLongitude = route.start.longitude,
            stopIDs = order,
            skippedIDs = skipped,
            legs = route.legs.map { leg -> PersistedLeg(leg.flatMap { listOf(it.latitude, it.longitude) }) },
            followsStreets = route.followsStreets,
            status = status
        )
        context.routePreferences.edit { values -> values[key] = json.encodeToString(persisted) }
    }

    suspend fun restore(gebietID: String): RestoredRoute? {
        val raw = context.routePreferences.data.first()[keyFor(gebietID)] ?: return null
        val persisted = runCatching { json.decodeFromString<PersistedRoute>(raw) }.getOrNull()
        if (persisted == null) {
            context.routePreferences.edit { values -> values.remove(keyFor(gebietID)) }
            return null
        }
        val legs = persisted.legs.mapNotNull { leg ->
            leg.points.chunked(2)
                .filter { it.size == 2 }
                .map { StoredCoordinate(it[0], it[1]) }
                .takeIf { it.size >= 2 }
        }
        val restoredRoute = PlannedRoute(
            start = StoredCoordinate(persisted.startLatitude, persisted.startLongitude),
            stops = persisted.stopIDs.map { at.volkshilfe.nachbesuch.domain.route.RouteStop(it, StoredCoordinate(0.0, 0.0)) },
            legs = legs,
            followsStreets = persisted.followsStreets
        )
        return RestoredRoute(restoredRoute, persisted.stopIDs, persisted.skippedIDs, persisted.status)
    }

    suspend fun clear(gebietID: String) {
        context.routePreferences.edit { values -> values.remove(keyFor(gebietID)) }
    }

    private fun keyFor(gebietID: String) = stringPreferencesKey("route-${gebietID.lowercase()}")
}
