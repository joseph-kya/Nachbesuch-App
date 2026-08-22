package at.volkshilfe.nachbesuch.location

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Looper
import androidx.core.app.ActivityCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One position source for the whole app.
 *
 * The map previously owned a private `LocationSubscription` and the list had no
 * access to position at all, so "nearest first" could not be offered there. Two
 * separate subscriptions would mean two GPS sessions and roughly double the
 * battery cost on a device that spends a whole shift on this screen — which is
 * why iOS keeps a single shared `LocationService` too.
 *
 * Reference counted: the map and the list each start and stop it independently,
 * and the hardware request survives switching between them.
 */
class LocationService(context: Context) {
    private val client: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context.applicationContext)
    private val appContext = context.applicationContext

    private val _location = MutableStateFlow<Location?>(null)
    val location: StateFlow<Location?> = _location.asStateFlow()

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            result.lastLocation?.let { _location.value = it }
        }
    }

    private var subscribers = 0

    val hasPermission: Boolean
        get() {
            val fine = ActivityCompat.checkSelfPermission(appContext, android.Manifest.permission.ACCESS_FINE_LOCATION)
            val coarse = ActivityCompat.checkSelfPermission(appContext, android.Manifest.permission.ACCESS_COARSE_LOCATION)
            return fine == PackageManager.PERMISSION_GRANTED || coarse == PackageManager.PERMISSION_GRANTED
        }

    @SuppressLint("MissingPermission")
    @Synchronized
    fun start() {
        subscribers++
        if (subscribers > 1) return
        if (!hasPermission) return
        client.lastLocation.addOnSuccessListener { fix -> fix?.let { _location.value = it } }
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, UPDATE_INTERVAL_MS)
            .setMinUpdateDistanceMeters(MIN_DISTANCE_M)
            .setWaitForAccurateLocation(false)
            .build()
        client.requestLocationUpdates(request, callback, Looper.getMainLooper())
    }

    @Synchronized
    fun stop() {
        subscribers = (subscribers - 1).coerceAtLeast(0)
        if (subscribers == 0) client.removeLocationUpdates(callback)
    }

    private companion object {
        const val UPDATE_INTERVAL_MS = 2_000L
        const val MIN_DISTANCE_M = 3f
    }
}
