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

private val Vienna = SavedCamera(48.2082, 16.3738, 14.5)
// Same red as the rest of the app's chrome — this used to be a second,
// slightly different constant living only on the map.
private val Accent = VolkshilfeRed
private val RouteBlue = Color(0xFF147EFB)

private enum class MapMode { BROWSING, PLACING_HOUSE, DRAWING_AREA, SELECTING }
private enum class PoiPreset(val title: String) { OFF("Aus"), ESSENTIAL("Wesentlich"), ALL("Alle") }
private enum class RoutePhase { OFF, CHOOSING_START, PICKING_ON_MAP, RUNNING }

private data class RenderCluster(val key: String, val center: LatLng, val houses: List<House>)
private data class SearchPlace(val title: String, val subtitle: String, val coordinate: StoredCoordinate)

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
    var clustered by remember { mutableStateOf(false) }
    var location by remember { mutableStateOf<Location?>(null) }
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
        val locationSubscription = LocationSubscription(context) { fix -> location = fix }
        val headingSubscription = HeadingSubscription(context) { value -> heading = value }
        locationSubscription.start()
        headingSubscription.start()
        onDispose {
            routeJob?.cancel()
            locationSubscription.stop()
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

    val mapStyle = remember(poiPreset) { MapStyleOptions(poiStyle(poiPreset)) }
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
                    fillColor = Accent.copy(alpha = 0.10f),
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
            } else {
                visibleHouses.forEach { house ->
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
                                routePhase == RoutePhase.PICKING_ON_MAP -> planRoute(StoredCoordinate(house.latitude, house.longitude))
                                mode == MapMode.SELECTING -> selectedIDs = selectedIDs.toggle(house.id)
                                else -> onHouseSelected(house)
                            }
                            true
                        }
                    )
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
            modifier = Modifier.align(Alignment.TopCenter),
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
            modifier = Modifier.align(Alignment.BottomEnd).padding(horizontal = 14.dp, vertical = 12.dp),
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

@Composable
private fun MapTopChrome(
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
private fun MapActionBar(
    canAdd: Boolean,
    onAdd: () -> Unit,
    menuExpanded: Boolean,
    onMenuExpanded: (Boolean) -> Unit,
    satellite: Boolean,
    poiPreset: PoiPreset,
    hasBoundary: Boolean,
    canRoute: Boolean,
    canImport: Boolean,
    onBoundary: () -> Unit,
    onRoute: () -> Unit,
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
                        text = { Text("Empfohlene Route") },
                        leadingIcon = { Icon(Icons.Default.Route, null) },
                        enabled = canRoute,
                        onClick = onRoute
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
private fun MapConfirmCard(
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

@Composable
private fun RouteStartCard(canUseLocation: Boolean, onLocation: () -> Unit, onMap: () -> Unit, onCancel: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.96f), shape = RoundedCornerShape(28.dp), tonalElevation = 5.dp) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Startpunkt wählen", style = MaterialTheme.typography.titleMedium)
                    Text("Kürzeste Reihenfolge durch alle offenen Häuser", color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                IconButton(onClick = onCancel) { Icon(Icons.Default.Close, "Abbrechen") }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = onLocation, enabled = canUseLocation) { Icon(Icons.Default.MyLocation, null); Text(" Mein Standort") }
                TextButton(onClick = onMap) { Icon(Icons.Default.EditLocationAlt, null); Text(" Auf der Karte") }
            }
        }
    }
}

@Composable
private fun RouteCard(
    nextAddress: String?,
    remaining: Int,
    status: String?,
    visible: Boolean,
    onFocus: () -> Unit,
    onSkip: () -> Unit,
    onToggle: () -> Unit,
    onEnd: () -> Unit
) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.96f), shape = RoundedCornerShape(28.dp), tonalElevation = 5.dp) {
        Column(Modifier.padding(10.dp)) {
            TextButton(onClick = onFocus, enabled = nextAddress != null) {
                Column(horizontalAlignment = Alignment.Start) {
                    Text(if (nextAddress == null) "Route abgeschlossen" else "Nächstes Haus · $remaining übrig", style = MaterialTheme.typography.labelLarge)
                    Text(nextAddress ?: "Alle offenen Häuser erledigt", style = MaterialTheme.typography.titleMedium)
                    status?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
            Row {
                IconButton(onClick = onSkip, enabled = remaining > 1) { Icon(Icons.Default.SkipNext, "Haus überspringen") }
                IconButton(onClick = onToggle) { Icon(if (visible) Icons.Default.VisibilityOff else Icons.Default.Visibility, "Route ein-/ausblenden") }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onEnd) { Icon(Icons.Default.Close, "Route beenden") }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MapSearchDialog(onDismiss: () -> Unit, onSelect: (SearchPlace) -> Unit) {
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
private fun AreaImportDialog(
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

private fun Set<String>.toggle(id: String): Set<String> = if (id in this) this - id else this + id

private fun makeClusters(houses: List<House>, spanMeters: Double): List<RenderCluster> {
    if (houses.isEmpty()) return emptyList()
    val cellMeters = (spanMeters / 8.0).coerceIn(90.0, 280.0)
    val latCell = cellMeters / 110_540.0
    val referenceLatitude = houses.map { it.latitude }.average()
    val lonCell = cellMeters / (111_320.0 * cos(Math.toRadians(referenceLatitude)).coerceAtLeast(0.2))
    return houses.groupBy { "${floor(it.latitude / latCell).toInt()}:${floor(it.longitude / lonCell).toInt()}" }
        .map { (key, members) ->
            RenderCluster(key, LatLng(members.map { it.latitude }.average(), members.map { it.longitude }.average()), members)
        }
}

private fun LatLngBounds.visibleWidthMetres(): Double = RoutePlanner.metres(
    StoredCoordinate(southwest.latitude, southwest.longitude),
    StoredCoordinate(northeast.latitude, northeast.longitude)
)

private fun LatLngBounds.containsPadded(latitude: Double, longitude: Double, fraction: Double): Boolean {
    val latPad = (northeast.latitude - southwest.latitude) * fraction
    val lonSpan = (northeast.longitude - southwest.longitude).let { if (it < 0) it + 360 else it }
    val lonPad = lonSpan * fraction
    return latitude in (southwest.latitude - latPad)..(northeast.latitude + latPad) &&
        longitude in (southwest.longitude - lonPad)..(northeast.longitude + lonPad)
}

private fun poiStyle(preset: PoiPreset): String = when (preset) {
    PoiPreset.OFF -> """[{"featureType":"poi","stylers":[{"visibility":"off"}]}]"""
    PoiPreset.ESSENTIAL -> """[
        {"featureType":"poi","stylers":[{"visibility":"off"}]},
        {"featureType":"poi.business","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-75},{"lightness":18}]},
        {"featureType":"transit","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-70}]}
    ]"""
    PoiPreset.ALL -> """[
        {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-70},{"lightness":12}]},
        {"featureType":"transit","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-65}]}
    ]"""
}

private fun googleMapsKeyIsMissing(context: Context): Boolean = runCatching {
    val info = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
    info.metaData?.getString("com.google.android.geo.API_KEY").let { it.isNullOrBlank() || it == "DEFAULT_API_KEY" }
}.getOrDefault(true)

private fun animationsDisabled(context: Context): Boolean = runCatching {
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
}.getOrDefault(false)

private class LocationSubscription(
    private val context: Context,
    private val onLocation: (Location) -> Unit
) {
    private val client: FusedLocationProviderClient = LocationServices.getFusedLocationProviderClient(context)
    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) { result.lastLocation?.let(onLocation) }
    }

    @SuppressLint("MissingPermission")
    fun start() {
        val fine = ActivityCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = ActivityCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION)
        if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) return
        client.lastLocation.addOnSuccessListener { it?.let(onLocation) }
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 2_000L)
            .setMinUpdateDistanceMeters(3f)
            .setWaitForAccurateLocation(false)
            .build()
        client.requestLocationUpdates(request, callback, android.os.Looper.getMainLooper())
    }

    fun stop() { client.removeLocationUpdates(callback) }
}

private class HeadingSubscription(context: Context, private val onHeading: (Float?) -> Unit) : SensorEventListener {
    private val manager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val sensor = manager?.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val rotation = FloatArray(9)
    private val orientation = FloatArray(3)
    private var smoothed: Float? = null
    private var lastSent = 0L

    fun start() { sensor?.let { manager?.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) } }
    fun stop() { manager?.unregisterListener(this) }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return
        SensorManager.getRotationMatrixFromVector(rotation, event.values)
        SensorManager.getOrientation(rotation, orientation)
        val raw = ((Math.toDegrees(orientation[0].toDouble()).toFloat() + 360f) % 360f)
        val alpha = when (event.accuracy) {
            SensorManager.SENSOR_STATUS_ACCURACY_HIGH -> 0.35f
            SensorManager.SENSOR_STATUS_ACCURACY_MEDIUM -> 0.18f
            else -> 0.08f
        }
        val previous = smoothed
        smoothed = if (previous == null) raw else {
            val delta = ((raw - previous + 540f) % 360f) - 180f
            (previous + alpha * delta + 360f) % 360f
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastSent >= 80L) { lastSent = now; onHeading(smoothed) }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        if (accuracy == SensorManager.SENSOR_STATUS_UNRELIABLE) { smoothed = null; onHeading(null) }
    }
}

private class GooglePinBitmapCache(private val context: Context) {
    private val cache = object : LruCache<String, BitmapDescriptor>(260) {}

    fun house(house: House, scope: DayScope, scale: PinScale, selected: Boolean): BitmapDescriptor {
        val tally = house.tally(scope)
        val fullText = if (house.isApartmentBuilding) "${tally.completed}/${tally.unitCount}" else house.units.firstOrNull()?.displayOutcome(scope)?.emoji ?: "•"
        val text = if (scale == PinScale.DOT) "" else fullText
        val outcome = markerOutcome(house, scope)
        val key = "house:$text:$outcome:$scale:$selected"
        return cached(key) { pinBitmap(text, outcome, scale, selected) }
    }

    fun cluster(count: Int, hasOpen: Boolean): BitmapDescriptor = cached("cluster:$count:$hasOpen") {
        val density = context.resources.displayMetrics.density
        val size = (54 * density).toInt().coerceAtLeast(54)
        Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { bitmap ->
            val canvas = Canvas(bitmap)
            val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = if (hasOpen) 0xFFFF4545.toInt() else 0xFF3A3A3C.toInt() }
            canvas.drawCircle(size / 2f, size / 2f, size * 0.39f, fill)
            val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 3f * density }
            canvas.drawCircle(size / 2f, size / 2f, size * 0.39f, ring)
            drawCentered(canvas, if (count >= 1_000) "${count / 100 / 10.0}k" else count.toString(), size / 2f, size / 2f, 16f * density)
        }
    }

    fun number(value: Int): BitmapDescriptor = cached("number:$value") {
        val density = context.resources.displayMetrics.density
        val size = (28 * density).toInt().coerceAtLeast(28)
        Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { bitmap ->
            val canvas = Canvas(bitmap)
            val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFF3B45.toInt() }
            canvas.drawCircle(size / 2f, size / 2f, size * 0.42f, fill)
            drawCentered(canvas, value.toString(), size / 2f, size / 2f, 12f * density)
        }
    }

    fun userPuck(): BitmapDescriptor = cached("user-puck") {
        val density = context.resources.displayMetrics.density
        val size = (40 * density).toInt().coerceAtLeast(40)
        Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also { bitmap ->
            val canvas = Canvas(bitmap)
            val center = size / 2f
            val cone = android.graphics.Path().apply {
                moveTo(center, size * 0.04f)
                lineTo(size * 0.67f, size * 0.47f)
                lineTo(size * 0.33f, size * 0.47f)
                close()
            }
            canvas.drawPath(cone, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x55147EFB })
            canvas.drawCircle(center, center, size * 0.19f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFF147EFB.toInt() })
            canvas.drawCircle(center, center, size * 0.19f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = android.graphics.Color.WHITE; style = Paint.Style.STROKE; strokeWidth = 2.5f * density
            })
        }
    }

    private fun pinBitmap(text: String, outcome: VisitOutcome?, scale: PinScale, selected: Boolean): Bitmap {
        val density = context.resources.displayMetrics.density
        val head = when (scale) { PinScale.FULL -> 34f; PinScale.COMPACT -> 25f; PinScale.DOT -> 15f }
        val padding = 5f
        val tipHeight = head * 10f / 34f
        val width = ((head + padding * 2) * density).toInt().coerceAtLeast(28)
        val height = ((head + tipHeight + padding * 2) * density).toInt().coerceAtLeast(34)
        return Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { bitmap ->
            val canvas = Canvas(bitmap)
            val centerX = width / 2f
            val radius = head * density / 2f
            val centerY = (padding + head / 2f) * density
            val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = when (outcome) {
                    VisitOutcome.JOINED -> 0xFFFF4569.toInt()
                    VisitOutcome.LATE_NO -> 0xFFFF4848.toInt()
                    VisitOutcome.EARLY_NO -> 0xFFF59126.toInt()
                    VisitOutcome.NOT_HOME -> 0xFFFF4545.toInt()
                    null -> 0xFF1E7AD2.toInt()
                }
                setShadowLayer(3f * density, 0f, 2f * density, 0x55000000)
            }
            canvas.drawCircle(centerX, centerY, radius, fill)
            val tip = android.graphics.Path().apply {
                moveTo(centerX - head * 6f / 34f * density, centerY + radius * 0.72f)
                quadTo(centerX, height - padding * 0.35f * density, centerX + head * 6f / 34f * density, centerY + radius * 0.72f)
                close()
            }
            canvas.drawPath(tip, fill)
            val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (selected) 0xFF147EFB.toInt() else android.graphics.Color.WHITE
                style = Paint.Style.STROKE
                strokeWidth = (if (selected) 4f else 2.5f) * density
            }
            canvas.drawCircle(centerX, centerY, radius - ring.strokeWidth / 2f, ring)
            if (text.isNotEmpty()) drawCentered(canvas, text, centerX, centerY, (if (text.length > 2) 9.5f else 16f) * density)
        }
    }

    private fun markerOutcome(house: House, scope: DayScope): VisitOutcome? {
        if (house.units.any { it.isOpen(scope) && (it.isPendingRevisit || it.displayOutcome(scope) == VisitOutcome.NOT_HOME) }) return VisitOutcome.NOT_HOME
        val outcomes = house.units.mapNotNull { it.displayOutcome(scope) }
        return outcomes.lastOrNull { it == VisitOutcome.JOINED } ?: outcomes.lastOrNull()
    }

    private fun cached(key: String, make: () -> Bitmap): BitmapDescriptor = synchronized(cache) {
        cache.get(key) ?: BitmapDescriptorFactory.fromBitmap(make()).also { cache.put(key, it) }
    }

    private fun drawCentered(canvas: Canvas, text: String, x: Float, y: Float, size: Float) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.WHITE
            textSize = size
            textAlign = Paint.Align.CENTER
            typeface = Typeface.DEFAULT_BOLD
        }
        canvas.drawText(text, x, y - (paint.ascent() + paint.descent()) / 2f, paint)
    }
}
