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
import androidx.compose.material.icons.filled.Route
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
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
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.cos
import kotlin.math.floor

/*
 * The map screen.
 *
 * Split out of a single 1,273-line file: the chrome, the dialogs, the pin
 * bitmap cache and the sensor plumbing now live beside this one, so what is
 * left here is the state machine and the Google Map host.
 */

internal val Vienna = SavedCamera(48.2082, 16.3738, 14.5)
// Same red as the rest of the app's chrome — this used to be a second,
// slightly different constant living only on the map.
internal val Accent = VolkshilfeRed
internal val RouteBlue = Color(0xFF147EFB)

internal enum class MapMode { BROWSING, PLACING_HOUSE, DRAWING_AREA, SELECTING }
internal enum class PoiPreset(val title: String) { OFF("Aus"), ESSENTIAL("Wesentlich"), ALL("Alle") }
internal enum class RoutePhase { OFF, CHOOSING_START, PICKING_ON_MAP, RUNNING }

internal data class RenderCluster(val key: String, val center: LatLng, val houses: List<House>)
internal data class SearchPlace(val title: String, val subtitle: String, val coordinate: StoredCoordinate)

@Composable
fun MapSurface(
    houses: List<House>,
    gebiet: Gebiet? = null,
    boundary: List<StoredCoordinate> = emptyList(),
    scope: DayScope = DayScope.COMBINED,
    onScopeChanged: (DayScope) -> Unit = {},
    onHouseSelected: (House) -> Unit,
    onMapLongPress: (StoredCoordinate) -> Unit,
    onBoundaryChanged: (List<StoredCoordinate>) -> Unit = {},
    onDeleteHouses: (Set<String>) -> Unit = {},
    onImportHouses: (List<ImportedAreaAddress>) -> Unit = {},
    /**
     * Raised instead of [onHouseSelected] when the tapped pin has others stacked
     * underneath it, so the UI can offer a choice rather than silently picking
     * whichever marker happened to be on top.
     */
    onStackedPins: (List<String>) -> Unit = {},
    /** The app-wide position feed; see [at.volkshilfe.nachbesuch.location.LocationService]. */
    locationFlow: StateFlow<Location?> = MutableStateFlow(null),
    /**
     * Window insets plus the floating tab bar's height.
     *
     * The map tiles themselves stay full-bleed — they run under the status bar
     * and behind the tab bar, as on iOS — so these are applied only to the
     * chrome that must stay reachable.
     */
    contentPadding: PaddingValues = PaddingValues(0.dp),
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    val cameraStore = remember { MapCameraStore(context) }
    val mapLoadGuard = remember { MapLoadGuard(context) }
    val overpassClient = remember { OverpassClient(context) }
    val areaImportService = remember { AreaHouseImportService() }
    val bitmapCache = remember { GooglePinBitmapCache(context) }
    val clusterGate = remember { ClusterGate() }
    val camera = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(LatLng(Vienna.latitude, Vienna.longitude), Vienna.zoom.toFloat())
    }

    var mapLoaded by remember { mutableStateOf(false) }
    var mode by rememberSaveable { mutableStateOf(MapMode.BROWSING) }
    var poiPreset by rememberSaveable { mutableStateOf(PoiPreset.ESSENTIAL) }
    var satellite by rememberSaveable { mutableStateOf(false) }
    var menuExpanded by remember { mutableStateOf(false) }
    var selectedIDs by rememberSaveable { mutableStateOf(setOf<String>()) }
    var deleteSelectionPending by remember { mutableStateOf(false) }
    var boundaryOptions by remember { mutableStateOf(false) }
    var draftBoundary by remember { mutableStateOf(emptyList<StoredCoordinate>()) }
    var searchVisible by remember { mutableStateOf(false) }
    var areaImportVisible by remember { mutableStateOf(false) }
    var visibleBounds by remember { mutableStateOf<LatLngBounds?>(null) }
    var pinScale by remember { mutableStateOf(PinScale.FULL) }
    val displayDensity = LocalDensity.current.density
    var clustered by remember { mutableStateOf(false) }
    // Position comes from the shared LocationService, not a private subscription:
    // the list needs the same fix for "nearest first", and two subscriptions meant
    // two GPS sessions for one screen's worth of information.
    val location by locationFlow.collectAsState()
    var heading by remember { mutableStateOf<Float?>(null) }
    var following by remember { mutableStateOf(false) }
    var routePhase by rememberSaveable { mutableStateOf(RoutePhase.OFF) }
    var route by remember { mutableStateOf<PlannedRoute?>(null) }
    var routeOrder by remember { mutableStateOf(emptyList<String>()) }
    var routeVisible by rememberSaveable { mutableStateOf(true) }
    var routeStatus by remember { mutableStateOf<String?>(null) }
    var routeJob by remember { mutableStateOf<Job?>(null) }
    var cameraWriteSequence by remember { mutableIntStateOf(0) }
    var mapPermit by remember { mutableStateOf<MapLoadPermit?>(null) }

    val apiKeyMissing = remember { googleMapsKeyIsMissing(context) }
    val openHouses = remember(houses, scope) { houses.filter { it.tally(scope).open > 0 } }
    val nextHouse = remember(routeOrder, houses, scope) {
        routeOrder.asSequence().mapNotNull { id -> houses.firstOrNull { it.id == id } }
            .firstOrNull { it.tally(scope).open > 0 }
    }

    LaunchedEffect(apiKeyMissing) {
        mapPermit = if (apiKeyMissing) null else withContext(Dispatchers.IO) { mapLoadGuard.acquire() }
    }

    fun moveTo(coordinate: StoredCoordinate, zoom: Float = 16f, animate: Boolean = true) {
        val update = CameraUpdateFactory.newLatLngZoom(LatLng(coordinate.latitude, coordinate.longitude), zoom)
        coroutineScope.launch {
            if (animate) camera.animate(update, 180) else camera.move(update)
        }
    }

    fun frameTerritory() {
        val points = if (boundary.size >= 3) boundary else houses.map { StoredCoordinate(it.latitude, it.longitude) }
        if (points.isEmpty()) return
        if (points.size == 1) return moveTo(points.first())
        val builder = LatLngBounds.builder()
        points.filter { it.isPlausible }.forEach { builder.include(LatLng(it.latitude, it.longitude)) }
        coroutineScope.launch { camera.animate(CameraUpdateFactory.newLatLngBounds(builder.build(), 84), 220) }
    }

    fun planRoute(start: StoredCoordinate) {
        val stops = openHouses.map { RouteStop(it.id, StoredCoordinate(it.latitude, it.longitude)) }
        if (stops.isEmpty()) return
        routeJob?.cancel()
        route = RoutePlanner.plan(start, stops)
        routeOrder = route!!.stops.map { it.id }
        routeStatus = "Luftlinie · Gehwege werden gesucht …"
        routePhase = RoutePhase.RUNNING
        routeVisible = true
        routeJob = coroutineScope.launch {
            val network = withContext(Dispatchers.IO) { overpassClient.load(listOf(start) + stops.map { it.coordinate }) }
            val graph = (network as? WalkingNetworkResult.Ready)?.graph
            if (graph == null) {
                routeStatus = when (network) {
                    WalkingNetworkResult.AreaTooLarge -> "Luftlinie · Gebiet zu groß für Gehwege"
                    else -> "Luftlinie · Gehwege offline nicht verfügbar"
                }
                return@launch
            }
            val upgraded = withContext(Dispatchers.Default) { RoutePlanner.plan(start, stops, graph) }
            if (upgraded.followsStreets) {
                route = upgraded
                routeOrder = upgraded.stops.map { it.id }
                routeStatus = "Gehwegroute"
            }
        }
    }

    LaunchedEffect(mapLoaded) {
        if (!mapLoaded) return@LaunchedEffect
        val restored = withContext(Dispatchers.IO) { cameraStore.restore() } ?: Vienna
        camera.move(CameraUpdateFactory.newCameraPosition(
            CameraPosition.fromLatLngZoom(LatLng(restored.latitude, restored.longitude), restored.zoom.toFloat())
        ))
    }

    DisposableEffect(Unit) {
        val headingSubscription = HeadingSubscription(context) { value -> heading = value }
        headingSubscription.start()
        onDispose {
            routeJob?.cancel()
            headingSubscription.stop()
        }
    }

    LaunchedEffect(location, mapLoaded) {
        val fix = location ?: return@LaunchedEffect
        if (!mapLoaded) return@LaunchedEffect
        val initial = withContext(Dispatchers.IO) { cameraStore.consumeInitialCentre(fix.latitude, fix.longitude) }
        initial?.let { moveTo(StoredCoordinate(it.latitude, it.longitude), it.zoom.toFloat(), animate = false) }
    }

    LaunchedEffect(following, location) {
        if (!following) return@LaunchedEffect
        val fix = location ?: return@LaunchedEffect
        moveTo(StoredCoordinate(fix.latitude, fix.longitude), camera.position.zoom.coerceAtLeast(16f), animate = true)
    }

    LaunchedEffect(camera) {
        snapshotFlow { camera.position to camera.isMoving }.collectLatest { (position, moving) ->
            val projection = camera.projection ?: return@collectLatest
            val bounds = projection.visibleRegion.latLngBounds
            val span = bounds.visibleWidthMetres()
            val nextScale = PinScalePolicy.scaleFor(span, pinScale)
            if (nextScale != pinScale) pinScale = nextScale
            if (!moving) {
                visibleBounds = bounds
                val visibleCount = houses.count { bounds.containsPadded(it.latitude, it.longitude, 0.16) }
                clustered = clusterGate.update(span, visibleCount)
                cameraWriteSequence++
                delay(350)
                if (!camera.isMoving) {
                    withContext(Dispatchers.IO) {
                        cameraStore.record(SavedCamera(position.target.latitude, position.target.longitude, position.zoom.toDouble()))
                    }
                }
            }
        }
    }

    val visibleHouses = remember(houses, visibleBounds, clustered) {
        val bounds = visibleBounds
        if (bounds == null || houses.size <= 1_200) houses
        else houses.filter { bounds.containsPadded(it.latitude, it.longitude, 0.16) }
    }
    val clusters = remember(visibleHouses, visibleBounds, clustered) {
        if (!clustered) emptyList() else makeClusters(visibleHouses, visibleBounds?.visibleWidthMetres() ?: 3_200.0)
    }

    // Read from the applied scheme, not isSystemInDarkTheme(): the user can force
    // Hell or Dunkel in the settings, and the map has to follow that choice rather
    // than the system's — otherwise picking "Hell" on a dark phone gives a light
    // app wrapped around a dark map.
    val darkMap = MaterialTheme.colorScheme.background.luminance() < 0.5f
    val mapStyle = remember(poiPreset, darkMap) { MapStyleOptions(mapStyleJson(poiPreset, darkMap)) }
    val properties = remember(satellite, mapStyle) {
        MapProperties(
            mapType = if (satellite) MapType.HYBRID else MapType.NORMAL,
            mapStyleOptions = if (satellite) null else mapStyle,
            minZoomPreference = 3f,
            maxZoomPreference = 21f
        )
    }
    val settings = remember {
        MapUiSettings(
            compassEnabled = true,
            indoorLevelPickerEnabled = false,
            mapToolbarEnabled = false,
            myLocationButtonEnabled = false,
            rotationGesturesEnabled = true,
            scrollGesturesEnabled = true,
            tiltGesturesEnabled = true,
            zoomControlsEnabled = false,
            zoomGesturesEnabled = true
        )
    }

    Box(modifier.fillMaxSize()) {
        if (!apiKeyMissing && mapPermit is MapLoadPermit.Allowed) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = camera,
            // Cost policy: never attach a cloud Map ID. The no-Map-ID Maps SDK SKU
            // is the unlimited mobile tier and cannot silently become Dynamic Maps.
            googleMapOptionsFactory = { GoogleMapOptions() },
            properties = properties,
            uiSettings = settings,
            contentDescription = "Nachbesuchskarte",
            contentPadding = PaddingValues(top = 112.dp, bottom = 118.dp, start = 8.dp, end = 8.dp),
            onMapLoaded = { mapLoaded = true },
            onPOIClick = { },
            onMapLongClick = { point ->
                if (mode == MapMode.BROWSING) onMapLongPress(StoredCoordinate(point.latitude, point.longitude))
            }
        ) {
            if (boundary.size >= 3 && boundary.all { it.isPlausible }) {
                Polygon(
                    points = boundary.map { LatLng(it.latitude, it.longitude) },
                    // Lighter over dark tiles. The same 10% red that reads as a
                    // faint tint on the light map turns the whole territory
                    // maroon against the dark one — the boundary should mark an
                    // area, not recolour the city inside it.
                    fillColor = Accent.copy(alpha = if (darkMap) 0.055f else 0.10f),
                    strokeColor = Accent,
                    strokeWidth = 4f,
                    clickable = mode == MapMode.BROWSING,
                    zIndex = 2f,
                    onClick = { boundaryOptions = true }
                )
            }
            if (mode == MapMode.DRAWING_AREA && draftBoundary.size >= 2) {
                Polyline(
                    points = draftBoundary.map { LatLng(it.latitude, it.longitude) },
                    color = Accent,
                    width = 5f,
                    startCap = RoundCap(),
                    endCap = RoundCap(),
                    zIndex = 3f
                )
            }
            if (routeVisible) {
                route?.path?.takeIf { it.size >= 2 }?.let { path ->
                    Polyline(
                        points = path.map { LatLng(it.latitude, it.longitude) },
                        color = RouteBlue.copy(alpha = 0.88f),
                        width = 10f,
                        startCap = RoundCap(),
                        endCap = RoundCap(),
                        zIndex = 1f
                    )
                }
            }
            if (clustered) {
                clusters.forEach { cluster ->
                  // Same identity rule as the house markers below.
                  key(cluster.key) {
                    Marker(
                        state = rememberMarkerState(key = cluster.key, position = cluster.center),
                        icon = bitmapCache.cluster(cluster.houses.size, cluster.houses.any { it.tally(scope).open > 0 }),
                        anchor = Offset(0.5f, 0.5f),
                        title = "${cluster.houses.size} Häuser",
                        zIndex = 6f,
                        onClick = {
                            coroutineScope.launch {
                                camera.animate(CameraUpdateFactory.newLatLngZoom(cluster.center, camera.position.zoom + 1.4f), 180)
                            }
                            true
                        }
                    )
                  }
                }
            } else {
                visibleHouses.forEach { house ->
                  // `key` is load-bearing, not tidiness. A marker's icon comes from
                  // this parameter but its position lives in a MarkerState that
                  // `rememberMarkerState` creates once per composition *slot* — it
                  // takes no inputs, so it is never rebuilt when the slot's house
                  // changes. Emitted positionally, any reordering of the corpus
                  // therefore handed slot i the new house's icon while it kept the
                  // old house's position: the pin you edited kept a stale icon and
                  // the new one appeared somewhere else entirely. Keying by id
                  // gives every house its own slot for as long as it exists, which
                  // is the identity model the iOS annotations already have.
                  key(house.id) {
                    val selected = house.id in selectedIDs
                    Marker(
                        state = rememberMarkerState(key = house.id, position = LatLng(house.latitude, house.longitude)),
                        contentDescription = house.address,
                        icon = bitmapCache.house(house, scope, pinScale, selected),
                        anchor = Offset(0.5f, 1f),
                        title = house.address,
                        zIndex = if (selected) 12f else 5f,
                        onClick = {
                            when {
                                // Picking a route start wants one house, not a menu.
                                routePhase == RoutePhase.PICKING_ON_MAP ->
                                    planRoute(StoredCoordinate(house.latitude, house.longitude))
                                mode == MapMode.SELECTING -> selectedIDs = selectedIDs.toggle(house.id)
                                else -> {
                                    val stacked = stackedHouseIDs(
                                        houseID = house.id,
                                        houses = visibleHouses,
                                        projection = camera.projection,
                                        pinScale = pinScale,
                                        density = displayDensity
                                    )
                                    if (stacked.size > 1) onStackedPins(stacked) else onHouseSelected(house)
                                }
                            }
                            true
                        }
                    )
                  }
                }
            }
            draftBoundary.forEachIndexed { index, point ->
                Marker(
                    state = rememberMarkerState(key = "draft-$index", position = LatLng(point.latitude, point.longitude)),
                    icon = bitmapCache.number(index + 1),
                    anchor = Offset(0.5f, 0.5f),
                    zIndex = 20f
                )
            }
            location?.let { fix ->
                Circle(
                    center = LatLng(fix.latitude, fix.longitude),
                    radius = fix.accuracy.toDouble().coerceIn(4.0, 80.0),
                    fillColor = RouteBlue.copy(alpha = 0.09f),
                    strokeColor = RouteBlue.copy(alpha = 0.22f),
                    strokeWidth = 2f,
                    zIndex = 7f
                )
                Marker(
                    state = rememberMarkerState(key = "user", position = LatLng(fix.latitude, fix.longitude)),
                    icon = bitmapCache.userPuck(),
                    anchor = Offset(0.5f, 0.5f),
                    rotation = heading ?: 0f,
                    flat = true,
                    zIndex = 30f
                )
            }
            nextHouse?.takeIf { routeVisible && routePhase == RoutePhase.RUNNING }?.let { next ->
                val reduceMotion = remember { animationsDisabled(context) }
                val radius = if (reduceMotion) 16f else rememberInfiniteTransition(label = "next-stop")
                    .animateFloat(
                        initialValue = 13f,
                        targetValue = 20f,
                        animationSpec = infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse),
                        label = "next-stop-radius"
                    ).value
                Circle(
                    center = LatLng(next.latitude, next.longitude),
                    radius = radius.toDouble(),
                    fillColor = Color.Transparent,
                    strokeColor = RouteBlue.copy(alpha = 0.78f),
                    strokeWidth = 6f,
                    zIndex = 25f
                )
            }
        }
        }

        if (mode == MapMode.PLACING_HOUSE || mode == MapMode.DRAWING_AREA || routePhase == RoutePhase.PICKING_ON_MAP) {
            Icon(
                imageVector = if (routePhase == RoutePhase.PICKING_ON_MAP) Icons.Default.Flag else Icons.Default.EditLocationAlt,
                contentDescription = null,
                tint = Accent,
                modifier = Modifier.align(Alignment.Center)
            )
        }

        MapTopChrome(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .padding(top = contentPadding.calculateTopPadding()),
            gebiet = gebiet,
            houses = houses,
            scope = scope,
            selectedCount = selectedIDs.size,
            selecting = mode == MapMode.SELECTING,
            onScopeChanged = onScopeChanged,
            onSearch = { searchVisible = true },
            onStartSelection = { mode = MapMode.SELECTING; selectedIDs = emptySet() },
            onCancelSelection = { mode = MapMode.BROWSING; selectedIDs = emptySet() },
            onToggleAll = { selectedIDs = if (selectedIDs.size == houses.size) emptySet() else houses.mapTo(mutableSetOf()) { it.id } },
            onDeleteSelection = { if (selectedIDs.isNotEmpty()) deleteSelectionPending = true }
        )

        Column(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(bottom = contentPadding.calculateBottomPadding())
                .padding(horizontal = 14.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            AnimatedVisibility(mode == MapMode.BROWSING && routePhase == RoutePhase.OFF) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (boundary.isNotEmpty() || houses.isNotEmpty()) {
                        ChromeIconButton(onClick = ::frameTerritory) {
                            Icon(Icons.Default.Layers, contentDescription = "Zum Gebiet", tint = MaterialTheme.colorScheme.onSurface)
                        }
                    }
                    ChromeIconButton(
                        onClick = {
                            val fix = location
                            if (fix != null) {
                                following = !following
                                moveTo(StoredCoordinate(fix.latitude, fix.longitude), 16f)
                            }
                        },
                        tint = if (following) Accent else MaterialTheme.colorScheme.surfaceContainerHigh
                    ) {
                        Icon(
                            if (following) Icons.Default.LocationSearching else Icons.Default.MyLocation,
                            "Zu meinem Standort",
                            tint = if (following) Color.White else MaterialTheme.colorScheme.onSurface
                        )
                    }
                }
            }

            when (routePhase) {
                RoutePhase.CHOOSING_START -> RouteStartCard(
                    canUseLocation = location != null,
                    onLocation = { location?.let { planRoute(StoredCoordinate(it.latitude, it.longitude)) } },
                    onMap = { routePhase = RoutePhase.PICKING_ON_MAP },
                    onCancel = { routePhase = RoutePhase.OFF }
                )
                RoutePhase.PICKING_ON_MAP -> MapConfirmCard(
                    title = "Karte auf den Startpunkt schieben",
                    confirmLabel = "Hier starten",
                    onCancel = { routePhase = RoutePhase.OFF },
                    onConfirm = { planRoute(StoredCoordinate(camera.position.target.latitude, camera.position.target.longitude)) }
                )
                RoutePhase.RUNNING -> RouteCard(
                    nextAddress = nextHouse?.address,
                    remaining = routeOrder.count { id -> houses.firstOrNull { it.id == id }?.tally(scope)?.open ?: 0 > 0 },
                    status = routeStatus,
                    visible = routeVisible,
                    onFocus = { nextHouse?.let { moveTo(StoredCoordinate(it.latitude, it.longitude), 17f) } },
                    onSkip = {
                        nextHouse?.id?.let { id -> routeOrder = routeOrder.filterNot { it == id } + id }
                    },
                    onToggle = { routeVisible = !routeVisible },
                    onEnd = { routeJob?.cancel(); route = null; routeOrder = emptyList(); routePhase = RoutePhase.OFF }
                )
                RoutePhase.OFF -> Unit
            }

            when (mode) {
                MapMode.DRAWING_AREA -> MapConfirmCard(
                    title = "${draftBoundary.size} Punkte · Karte auf eine Ecke schieben",
                    confirmLabel = if (draftBoundary.size >= 3) "Gebiet speichern" else "Punkt ${draftBoundary.size + 1}",
                    secondaryIcon = if (draftBoundary.isNotEmpty()) Icons.AutoMirrored.Filled.Undo else null,
                    onSecondary = { if (draftBoundary.isNotEmpty()) draftBoundary = draftBoundary.dropLast(1) },
                    onCancel = { mode = MapMode.BROWSING; draftBoundary = emptyList() },
                    onConfirm = {
                        if (draftBoundary.size >= 3) {
                            onBoundaryChanged(draftBoundary)
                            draftBoundary = emptyList()
                            mode = MapMode.BROWSING
                        } else {
                            draftBoundary = draftBoundary + StoredCoordinate(camera.position.target.latitude, camera.position.target.longitude)
                        }
                    },
                    onPrimaryLongClick = {
                        draftBoundary = draftBoundary + StoredCoordinate(camera.position.target.latitude, camera.position.target.longitude)
                    }
                )
                MapMode.PLACING_HOUSE -> MapConfirmCard(
                    title = "Karte auf das Haus schieben",
                    confirmLabel = "Haus hier eintragen",
                    onCancel = { mode = MapMode.BROWSING },
                    onConfirm = {
                        onMapLongPress(StoredCoordinate(camera.position.target.latitude, camera.position.target.longitude))
                        mode = MapMode.BROWSING
                    }
                )
                MapMode.BROWSING -> if (routePhase == RoutePhase.OFF) {
                    MapActionBar(
                        canAdd = gebiet != null,
                        onAdd = { mode = MapMode.PLACING_HOUSE },
                        menuExpanded = menuExpanded,
                        onMenuExpanded = { menuExpanded = it },
                        satellite = satellite,
                        poiPreset = poiPreset,
                        hasBoundary = boundary.size >= 3,
                        canRoute = openHouses.isNotEmpty(),
                        canImport = boundary.size >= 3,
                        onBoundary = {
                            menuExpanded = false
                            if (boundary.size >= 3) boundaryOptions = true
                            else { draftBoundary = emptyList(); mode = MapMode.DRAWING_AREA }
                        },
                        onRoute = { menuExpanded = false; routePhase = RoutePhase.CHOOSING_START },
                        onImport = { menuExpanded = false; areaImportVisible = true },
                        onSatellite = { satellite = !satellite },
                        onPoi = { poiPreset = PoiPreset.entries[(poiPreset.ordinal + 1) % PoiPreset.entries.size] }
                    )
                }
                MapMode.SELECTING -> Unit
            }
        }

        if (apiKeyMissing) {
            Surface(
                modifier = Modifier.align(Alignment.Center).padding(24.dp),
                color = MaterialTheme.colorScheme.errorContainer,
                shape = RoundedCornerShape(24.dp)
            ) {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Google Maps API-Key fehlt", style = MaterialTheme.typography.titleMedium)
                    Text("Trage MAPS_API_KEY in secrets.properties ein.", style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        if (mapPermit is MapLoadPermit.Blocked) {
            Surface(
                modifier = Modifier.align(Alignment.Center).padding(24.dp),
                color = MaterialTheme.colorScheme.errorContainer,
                shape = RoundedCornerShape(24.dp)
            ) {
                Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Karten-Sicherheitslimit erreicht", style = MaterialTheme.typography.titleMedium)
                    Text(
                        "Die Karte wurde heute ungewöhnlich oft neu geladen. Morgen ist sie automatisch wieder verfügbar.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }
        }
    }

    if (searchVisible) {
        MapSearchDialog(
            onDismiss = { searchVisible = false },
            onSelect = { place -> searchVisible = false; moveTo(place.coordinate, 17f) }
        )
    }
    if (areaImportVisible) {
        AreaImportDialog(
            service = areaImportService,
            boundary = boundary,
            existingHouses = houses,
            onDismiss = { areaImportVisible = false },
            onImport = { values ->
                onImportHouses(values)
                areaImportVisible = false
            }
        )
    }
    if (deleteSelectionPending) {
        AlertDialog(
            onDismissRequest = { deleteSelectionPending = false },
            title = { Text("Auswahl löschen?") },
            text = { Text("${selectedIDs.size} Häuser und alle dazugehörigen Tür-Status werden entfernt.") },
            confirmButton = {
                TextButton(onClick = {
                    onDeleteHouses(selectedIDs)
                    selectedIDs = emptySet()
                    mode = MapMode.BROWSING
                    deleteSelectionPending = false
                }) { Text("${selectedIDs.size} löschen", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteSelectionPending = false }) { Text("Abbrechen") } }
        )
    }
    if (boundaryOptions) {
        AlertDialog(
            onDismissRequest = { boundaryOptions = false },
            title = { Text("Gebietsmarkierung") },
            text = { Text("Du kannst die vorhandene Grenze weiterbearbeiten oder die Markierung löschen.") },
            confirmButton = {
                TextButton(onClick = {
                    draftBoundary = boundary
                    mode = MapMode.DRAWING_AREA
                    boundaryOptions = false
                }) { Text("Bearbeiten") }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = { onBoundaryChanged(emptyList()); boundaryOptions = false }) {
                        Text("Löschen", color = MaterialTheme.colorScheme.error)
                    }
                    TextButton(onClick = { boundaryOptions = false }) { Text("Abbrechen") }
                }
            }
        )
    }
}

