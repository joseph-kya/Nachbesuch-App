package at.volkshilfe.nachbesuch.data.prefs

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first

private val Context.settingsPreferences by preferencesDataStore("app-settings")

/**
 * User-facing toggles that must survive relaunches, matching the iOS
 * @AppStorage-backed keys: map style, POI preset and route overlay visibility.
 */
class AppSettingsStore(private val context: Context) {
    data class Values(
        val satellite: Boolean,
        val poiEssential: Boolean,
        val poiAll: Boolean,
        val routeVisible: Boolean,
        val exportVisitedOnly: Boolean,
        val exportIncludeNotes: Boolean
    )

    private object Keys {
        val satellite = booleanPreferencesKey("map.usesSatellite")
        val poiEssential = booleanPreferencesKey("map.poi.essential")
        val poiAll = booleanPreferencesKey("map.poi.all")
        val routeVisible = booleanPreferencesKey("route.overlayVisible")
        val exportVisitedOnly = booleanPreferencesKey("export.visitedOnly")
        val exportIncludeNotes = booleanPreferencesKey("export.includeNotes")
    }

    suspend fun restore(): Values {
        val values = context.settingsPreferences.data.first()
        return Values(
            satellite = values[Keys.satellite] ?: false,
            poiEssential = values[Keys.poiEssential] ?: true,
            poiAll = values[Keys.poiAll] ?: false,
            routeVisible = values[Keys.routeVisible] ?: true,
            exportVisitedOnly = values[Keys.exportVisitedOnly] ?: true,
            // iOS defaults includeNotes to true; Android historically forced it off.
            exportIncludeNotes = values[Keys.exportIncludeNotes] ?: true
        )
    }

    suspend fun record(values: Values) {
        context.settingsPreferences.edit { current ->
            current[Keys.satellite] = values.satellite
            current[Keys.poiEssential] = values.poiEssential
            current[Keys.poiAll] = values.poiAll
            current[Keys.routeVisible] = values.routeVisible
            current[Keys.exportVisitedOnly] = values.exportVisitedOnly
            current[Keys.exportIncludeNotes] = values.exportIncludeNotes
        }
    }
}
