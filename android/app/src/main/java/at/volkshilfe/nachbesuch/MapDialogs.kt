package at.volkshilfe.nachbesuch

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Geocoder
import android.location.Location
import android.os.SystemClock
import android.provider.Settings
import android.util.LruCache
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.EditLocationAlt
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.LocationSearching
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SelectAll
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.app.ActivityCompat
import at.volkshilfe.nachbesuch.data.prefs.MapCameraStore
import at.volkshilfe.nachbesuch.data.prefs.MapLoadGuard
import at.volkshilfe.nachbesuch.data.prefs.MapLoadPermit
import at.volkshilfe.nachbesuch.data.prefs.SavedCamera
import at.volkshilfe.nachbesuch.data.importing.AreaHouseImportService
import at.volkshilfe.nachbesuch.data.importing.AreaImportResult
import at.volkshilfe.nachbesuch.data.importing.ImportedAreaAddress
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.ui.theme.ChromeIconButton
import at.volkshilfe.nachbesuch.ui.theme.VolkshilfeRed
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.maps.CameraUpdateFactory
import com.google.android.gms.maps.GoogleMapOptions
import com.google.android.gms.maps.model.BitmapDescriptor
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.LatLngBounds
import com.google.android.gms.maps.model.MapStyleOptions
import com.google.android.gms.maps.model.RoundCap
import com.google.maps.android.compose.Circle
import com.google.maps.android.compose.GoogleMap
import com.google.maps.android.compose.MapProperties
import com.google.maps.android.compose.MapType
import com.google.maps.android.compose.MapUiSettings
import com.google.maps.android.compose.Marker
import com.google.maps.android.compose.Polygon
import com.google.maps.android.compose.Polyline
import com.google.maps.android.compose.rememberCameraPositionState
import com.google.maps.android.compose.rememberMarkerState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.cos
import kotlin.math.floor

/*
 * The map's modal dialogs: address/place search and the OSM area import preview.
 */

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun MapSearchDialog(onDismiss: () -> Unit, onSelect: (SearchPlace) -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var query by rememberSaveable { mutableStateOf("") }
    var loading by remember { mutableStateOf(false) }
    var results by remember { mutableStateOf(emptyList<SearchPlace>()) }
    var error by remember { mutableStateOf<String?>(null) }
    fun search() {
        val term = query.trim()
        if (term.length < 2) return
        loading = true
        error = null
        scope.launch {
            results = runCatching { geocode(context, term) }.getOrElse {
                error = "Suche gerade nicht verfügbar"
                emptyList()
            }
            loading = false
        }
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Auf der Karte suchen") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    singleLine = true,
                    label = { Text("Adresse, Ort oder Gebiet") },
                    trailingIcon = { IconButton(onClick = ::search) { Icon(Icons.Default.Search, "Suchen") } },
                    modifier = Modifier.fillMaxWidth()
                )
                if (loading) Text("Wird gesucht …", color = MaterialTheme.colorScheme.onSurfaceVariant)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                LazyColumn(modifier = Modifier.height(260.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    items(results) { place ->
                        TextButton(onClick = { onSelect(place) }, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.Start) {
                                Text(place.title)
                                if (place.subtitle.isNotBlank()) Text(place.subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { Button(onClick = ::search, enabled = query.trim().length >= 2 && !loading) { Text("Suchen") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

@Composable
internal fun AreaImportDialog(
    service: AreaHouseImportService,
    boundary: List<StoredCoordinate>,
    existingHouses: List<House>,
    onDismiss: () -> Unit,
    onImport: (List<ImportedAreaAddress>) -> Unit
) {
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    var addresses by remember { mutableStateOf(emptyList<ImportedAreaAddress>()) }
    var skipped by remember { mutableIntStateOf(0) }
    var reload by remember { mutableIntStateOf(0) }

    LaunchedEffect(boundary, existingHouses, reload) {
        loading = true
        error = null
        when (val result = service.fetch(boundary)) {
            is AreaImportResult.Ready -> {
                val selection = withContext(Dispatchers.Default) {
                    service.excludingExisting(result.addresses, existingHouses)
                }
                addresses = selection.addresses
                skipped = selection.skippedDuplicates
            }
            is AreaImportResult.Failed -> {
                addresses = emptyList()
                error = result.message
            }
        }
        loading = false
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Häuser im Gebiet") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                when {
                    loading -> Text("Häuser werden gesucht …")
                    error != null -> {
                        Text("Import nicht möglich", style = MaterialTheme.typography.titleMedium)
                        Text(error.orEmpty(), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton(onClick = { reload++ }) { Text("Erneut versuchen") }
                    }
                    addresses.isEmpty() -> Text(
                        if (skipped > 0) "Keine neuen Häuser · $skipped bereits vorhanden"
                        else "In diesem Gebiet wurden keine adressierten Häuser gefunden."
                    )
                    else -> {
                        Text(
                            "${addresses.size} neue Häuser" + if (skipped > 0) " · $skipped Duplikate übersprungen" else "",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            "Alle Einträge entstehen als Einzelhäuser. Quelle: © OpenStreetMap-Mitwirkende.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        LazyColumn(modifier = Modifier.height(280.dp)) {
                            items(addresses.take(60), key = { it.id }) { candidate ->
                                Text(candidate.address, modifier = Modifier.padding(vertical = 5.dp))
                            }
                            if (addresses.size > 60) item { Text("… und ${addresses.size - 60} weitere") }
                        }
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = { onImport(addresses) }, enabled = addresses.isNotEmpty() && !loading) {
                Text("${addresses.size} anlegen")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

@Suppress("DEPRECATION")
private suspend fun geocode(context: Context, query: String): List<SearchPlace> = withContext(Dispatchers.IO) {
    if (!Geocoder.isPresent()) return@withContext emptyList()
    Geocoder(context, Locale.GERMANY).getFromLocationName(query, 8).orEmpty().mapNotNull { address ->
        val coordinate = StoredCoordinate(address.latitude, address.longitude)
        if (!coordinate.isPlausible) null else SearchPlace(
            title = address.featureName ?: address.thoroughfare ?: query,
            subtitle = listOfNotNull(address.postalCode, address.locality, address.countryName).distinct().joinToString(" · "),
            coordinate = coordinate
        )
    }
}
