package at.volkshilfe.nachbesuch

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import kotlinx.coroutines.flow.StateFlow

@Composable
fun AddHouseDialog(
    coordinate: StoredCoordinate,
    onAdd: (String, StoredCoordinate) -> Unit,
    onDismiss: () -> Unit
) {
    var address by rememberSaveable { mutableStateOf("") }
    var latitude by rememberSaveable(coordinate.latitude) { mutableStateOf("%.6f".format(coordinate.latitude)) }
    var longitude by rememberSaveable(coordinate.longitude) { mutableStateOf("%.6f".format(coordinate.longitude)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Haus hinzufügen") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(address, { address = it }, label = { Text("Adresse") }, singleLine = true)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(latitude, { latitude = it }, label = { Text("Breite") }, singleLine = true, modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                    OutlinedTextField(longitude, { longitude = it }, label = { Text("Länge") }, singleLine = true, modifier = Modifier.weight(1f), keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                }
                Text("Position: ${coordinate.latitude.formatCoordinate()}, ${coordinate.longitude.formatCoordinate()}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
        confirmButton = {
            Button(onClick = {
                val lat = latitude.replace(',', '.').toDoubleOrNull()
                val lon = longitude.replace(',', '.').toDoubleOrNull()
                if (lat != null && lon != null) onAdd(address, StoredCoordinate(lat, lon))
            }, enabled = address.trim().isNotEmpty()) { Text("Hinzufügen") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } }
    )
}

private fun Double.formatCoordinate(): String = "%.5f".format(this)

@Composable
fun <T> StateFlow<T>.collectAsStateWithLifecycleCompat(): androidx.compose.runtime.State<T> =
    collectAsState()
