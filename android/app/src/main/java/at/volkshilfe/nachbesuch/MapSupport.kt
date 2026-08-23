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
import at.volkshilfe.nachbesuch.domain.map.PinScale
import at.volkshilfe.nachbesuch.domain.map.PinStacking
import at.volkshilfe.nachbesuch.domain.model.DayScope
import at.volkshilfe.nachbesuch.domain.model.Gebiet
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.MapPinSnapshotBuilder
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
import com.google.android.gms.maps.Projection
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

/*
 * Map plumbing: bounds maths, POI styling, environment probes, the
 * compass-heading subscription and the cached pin bitmaps.
 *
 * The former private LocationSubscription is gone — position now comes from the
 * shared LocationService, so the map and the list no longer open two GPS
 * sessions for the same fix.
 */

internal fun Set<String>.toggle(id: String): Set<String> = if (id in this) this - id else this + id

internal fun LatLngBounds.visibleWidthMetres(): Double = RoutePlanner.metres(
    StoredCoordinate(southwest.latitude, southwest.longitude),
    StoredCoordinate(northeast.latitude, northeast.longitude)
)

internal fun LatLngBounds.containsPadded(latitude: Double, longitude: Double, fraction: Double): Boolean {
    val latPad = (northeast.latitude - southwest.latitude) * fraction
    val lonSpan = (northeast.longitude - southwest.longitude).let { if (it < 0) it + 360 else it }
    val lonPad = lonSpan * fraction
    return latitude in (southwest.latitude - latPad)..(northeast.latitude + latPad) &&
        longitude in (southwest.longitude - lonPad)..(northeast.longitude + lonPad)
}

/**
 * The POI rules for one preset, as raw style entries.
 *
 * Returned without the enclosing brackets so [mapStyleJson] can concatenate them
 * with the dark palette instead of applying one style and losing the other —
 * Google Maps accepts a single style array, not a stack of them.
 */
private fun poiStyleEntries(preset: PoiPreset): String = when (preset) {
    PoiPreset.OFF -> """{"featureType":"poi","stylers":[{"visibility":"off"}]}"""
    PoiPreset.ESSENTIAL -> """
        {"featureType":"poi","stylers":[{"visibility":"off"}]},
        {"featureType":"poi.business","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-75},{"lightness":18}]},
        {"featureType":"transit","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-70}]}
    """.trim()
    PoiPreset.ALL -> """
        {"featureType":"poi","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-70},{"lightness":12}]},
        {"featureType":"transit","elementType":"labels","stylers":[{"visibility":"on"},{"saturation":-65}]}
    """.trim()
}

/**
 * A dark map palette, tuned to this app's neutral scheme.
 *
 * In dark mode the map used to stay bright white while every surface around it
 * was near-black — the single loudest mismatch with the iOS build, where the
 * map follows the system appearance. It also made the system status bar
 * unreadable once the map went edge-to-edge: light status icons over light
 * tiles. The greys below are the same neutral family as the app's surfaces
 * rather than Google's blue-tinted sample palette.
 */
private val DarkMapEntries = """
    {"elementType":"geometry","stylers":[{"color":"#1b1b1d"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#9a9a9e"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#131314"}]},
    {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#3a3b3e"}]},
    {"featureType":"administrative.locality","elementType":"labels.text.fill","stylers":[{"color":"#c4c6c8"}]},
    {"featureType":"landscape.man_made","elementType":"geometry","stylers":[{"color":"#202022"}]},
    {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#8e9095"}]},
    {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#1d2a20"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#2c2d2f"}]},
    {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#151516"}]},
    {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#a5a7ab"}]},
    {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3a3b3e"}]},
    {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#d0d2d5"}]},
    {"featureType":"transit","elementType":"geometry","stylers":[{"color":"#26272a"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#101820"}]},
    {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#4d5a68"}]}
""".trim()

/** The full style array for the current preset and appearance. */
internal fun mapStyleJson(preset: PoiPreset, dark: Boolean): String {
    val entries = if (dark) "$DarkMapEntries,\n${poiStyleEntries(preset)}" else poiStyleEntries(preset)
    return "[$entries]"
}


internal fun googleMapsKeyIsMissing(context: Context): Boolean = runCatching {
    val info = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
    info.metaData?.getString("com.google.android.geo.API_KEY").let { it.isNullOrBlank() || it == "DEFAULT_API_KEY" }
}.getOrDefault(true)

internal fun animationsDisabled(context: Context): Boolean = runCatching {
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
}.getOrDefault(false)


internal class HeadingSubscription(context: Context, private val onHeading: (Float?) -> Unit) : SensorEventListener {
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


internal class GooglePinBitmapCache(private val context: Context) {
    private val cache = object : LruCache<String, BitmapDescriptor>(260) {}

    /**
     * The pin for one house.
     *
     * Both the glyph and the colour come from [MapPinSnapshotBuilder], the same
     * rule the list and the export use. This file used to carry its own copy of
     * the priority logic, and it had drifted: it forced a red pin for a pending
     * revisit even in Tag-2 scope, where the shared rule (and iOS) deliberately
     * shows the door as unrecorded. A pin and its list row disagreeing about the
     * same house is exactly what one shared rule prevents.
     */
    fun house(house: House, scope: DayScope, scale: PinScale, selected: Boolean): BitmapDescriptor {
        val tally = house.tally(scope)
        val outcome = MapPinSnapshotBuilder.markerOutcome(house.units, scope)
        val fullText =
            if (house.isApartmentBuilding) "${tally.completed}/${tally.unitCount}"
            else outcome?.emoji ?: "•"
        val text = if (scale == PinScale.DOT) "" else fullText
        val key = "house:$text:$outcome:$scale:$selected"
        return cached(key) { pinBitmap(text, outcome, scale, selected) }
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
        val head = scale.headDiameterDp
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
                    // Matches `VisitOutcome.LATER.tint`; the pin palette is
                    // hand-written here because these are ints baked into a
                    // rendered bitmap cache.
                    VisitOutcome.LATER -> 0xFF5E5CE6.toInt()
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



/**
 * House IDs sitting essentially on top of [houseID], the tapped house first.
 *
 * With nothing merged or hidden, houses at the same spot render as one visible
 * pin and a tap can only ever reach whichever marker is on top. This finds the
 * ones underneath so the UI can offer a choice.
 *
 * The radius is deliberately **small**, matching iOS. Merely adjacent pins
 * overlap at street zoom, but each still exposes enough of itself to be tapped
 * directly. Only a pin whose centre lies under another pin's head is genuinely
 * unreachable, and that is the case worth a list.
 *
 * Projects into screen space so the threshold means the same thing at every
 * zoom level, then hands the decision to [PinStacking], which is pure and
 * therefore testable without a map.
 */
internal fun stackedHouseIDs(
    houseID: String,
    houses: List<House>,
    projection: Projection?,
    pinScale: PinScale,
    density: Float
): List<String> {
    if (projection == null) return listOf(houseID)
    if (houses.none { it.id == houseID }) return listOf(houseID)
    val points = houses.associate { house ->
        val point = projection.toScreenLocation(LatLng(house.latitude, house.longitude))
        house.id to PinStacking.Point(point.x.toFloat(), point.y.toFloat())
    }
    return PinStacking.idsAt(houseID, points, PinStacking.radiusPx(pinScale, density))
}
