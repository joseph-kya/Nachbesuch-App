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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.IosShare
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
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SelectAll
import androidx.compose.material.icons.filled.Visibility
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
import at.volkshilfe.nachbesuch.data.route.OverpassClient
import at.volkshilfe.nachbesuch.data.route.WalkingNetworkResult
import at.volkshilfe.nachbesuch.domain.map.ClusterGate
import at.volkshilfe.nachbesuch.domain.map.PinScale
import at.volkshilfe.nachbesuch.domain.map.PinScalePolicy
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.domain.model.VisitOutcome
import at.volkshilfe.nachbesuch.domain.route.PlannedRoute
import at.volkshilfe.nachbesuch.domain.route.RoutePlanner
import at.volkshilfe.nachbesuch.domain.route.RouteStop
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
 * The map's floating control surfaces: summary, action bar, confirmation and
 * route cards. Presentation only — every decision stays in MapSurface.
 */

@Composable
internal fun MapTopChrome(
    modifier: Modifier,
    gebiet: Gebiet?,
    houses: List<House>,
    scope: DayScope,
    selectedCount: Int,
    selecting: Boolean,
    onScopeChanged: (DayScope) -> Unit,
    onSearch: () -> Unit,
    onStartSelection: () -> Unit,
    onCancelSelection: () -> Unit,
    onToggleAll: () -> Unit,
    onExportSelection: () -> Unit,
    onDeleteSelection: () -> Unit
) {
    val tally = remember(houses, scope) { houses.map { it.tally(scope) } }
    Surface(
        modifier = modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.94f),
        shape = RoundedCornerShape(28.dp),
        tonalElevation = 4.dp
    ) {
        if (selecting) {
            Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onCancelSelection) { Icon(Icons.Default.Close, "Auswahl beenden") }
                Column(Modifier.weight(1f)) {
                    Text("$selectedCount ausgewählt", style = MaterialTheme.typography.titleMedium)
                    Text("von ${houses.size}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton(onClick = onToggleAll) { Text(if (selectedCount == houses.size) "Keine" else "Alle") }
                IconButton(onClick = onExportSelection, enabled = selectedCount > 0) {
                    Icon(Icons.Default.IosShare, "Auswahl exportieren")
                }
                IconButton(onClick = onDeleteSelection, enabled = selectedCount > 0) {
                    Icon(Icons.Default.DeleteOutline, "Auswahl löschen", tint = MaterialTheme.colorScheme.error)
                }
            }
        } else {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(gebiet?.displayName ?: "Kein Gebiet", style = MaterialTheme.typography.titleLarge)
                        Text(
                            if (gebiet == null) "Lege im Archiv ein Gebiet an"
                            else "${houses.size} Häuser · ${tally.sumOf { it.open }} offen · 🔥 ${tally.sumOf { it.joined }}",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    IconButton(onClick = onStartSelection, enabled = houses.isNotEmpty()) { Icon(Icons.Default.SelectAll, "Pins auswählen") }
                    IconButton(onClick = onSearch) { Icon(Icons.Default.Search, "Ort auf der Karte suchen") }
                }
                if (gebiet?.isTwoDay == true) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        listOf(DayScope.COMBINED to "Gesamt", DayScope.DAY_1 to "Tag 1", DayScope.DAY_2 to "Tag 2").forEach { (value, label) ->
                            FilterChip(selected = scope == value, onClick = { onScopeChanged(value) }, label = { Text(label) })
                        }
                    }
                }
            }
        }
    }
}

@Composable
internal fun MapActionBar(
    canAdd: Boolean,
    onAdd: () -> Unit,
    menuExpanded: Boolean,
    onMenuExpanded: (Boolean) -> Unit,
    satellite: Boolean,
    poiPreset: PoiPreset,
    hasBoundary: Boolean,
    canImport: Boolean,
    onBoundary: () -> Unit,
    onImport: () -> Unit,
    onSatellite: () -> Unit,
    onPoi: () -> Unit
) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.95f), shape = RoundedCornerShape(30.dp), tonalElevation = 4.dp) {
        Row(Modifier.padding(7.dp), verticalAlignment = Alignment.CenterVertically) {
            Box {
                IconButton(onClick = { onMenuExpanded(true) }) { Icon(Icons.Default.MoreHoriz, "Kartenoptionen") }
                DropdownMenu(expanded = menuExpanded, onDismissRequest = { onMenuExpanded(false) }) {
                    DropdownMenuItem(
                        text = { Text(if (hasBoundary) "Gebiet bearbeiten" else "Gebiet einzeichnen") },
                        leadingIcon = { Icon(Icons.Default.EditLocationAlt, null) },
                        onClick = onBoundary
                    )
                    DropdownMenuItem(
                        text = { Text("Häuser aus Kartendaten laden") },
                        leadingIcon = { Icon(Icons.Default.Add, null) },
                        enabled = canImport,
                        onClick = onImport
                    )
                    DropdownMenuItem(
                        text = { Text(if (satellite) "Kartenstil: Satellit" else "Kartenstil: Standard") },
                        leadingIcon = { Icon(Icons.Default.Layers, null) },
                        onClick = onSatellite
                    )
                    DropdownMenuItem(
                        text = { Text("Orte: ${poiPreset.title}") },
                        leadingIcon = { Icon(Icons.Default.Visibility, null) },
                        onClick = onPoi
                    )
                }
            }
            Button(onClick = onAdd, enabled = canAdd, shape = RoundedCornerShape(24.dp)) {
                Icon(Icons.Default.Add, null)
                Text(" Haus hinzufügen")
            }
        }
    }
}

@Composable
internal fun MapConfirmCard(
    title: String,
    confirmLabel: String,
    secondaryIcon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    onSecondary: () -> Unit = {},
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
    onPrimaryLongClick: () -> Unit = onConfirm
) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.96f), shape = RoundedCornerShape(28.dp), tonalElevation = 5.dp) {
        Column(Modifier.padding(10.dp), horizontalAlignment = Alignment.End) {
            Text(title, modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onCancel) { Text("Abbrechen") }
                secondaryIcon?.let { IconButton(onClick = onSecondary) { Icon(it, "Rückgängig") } }
                Button(onClick = onConfirm, shape = RoundedCornerShape(22.dp)) {
                    Icon(Icons.Default.Check, null)
                    Text(" $confirmLabel")
                }
            }
        }
    }
}
