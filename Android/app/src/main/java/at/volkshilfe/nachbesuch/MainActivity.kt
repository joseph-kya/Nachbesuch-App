package at.volkshilfe.nachbesuch

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import at.volkshilfe.nachbesuch.ui.RootScaffold
import at.volkshilfe.nachbesuch.ui.theme.NachbesuchTheme

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<AppViewModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            NachbesuchTheme {
                var locationDenied by remember { mutableStateOf(false) }
                val locationLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.RequestMultiplePermissions()
                ) { grants ->
                    locationDenied = grants.values.none { it }
                }
                LaunchedEffect(Unit) {
                    val fine = ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.ACCESS_FINE_LOCATION)
                    val coarse = ContextCompat.checkSelfPermission(this@MainActivity, Manifest.permission.ACCESS_COARSE_LOCATION)
                    if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) {
                        locationLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                    }
                }
                var selectedHouse by remember { mutableStateOf<House?>(null) }
                var addCoordinate by remember { mutableStateOf<StoredCoordinate?>(null) }
                var showGebietDialog by remember { mutableStateOf(false) }
                var showStoreWarning by remember { mutableStateOf(viewModel.storeUnreadable) }
                var exportKind by remember { mutableStateOf<String?>(null) }
                var importUri by remember { mutableStateOf<android.net.Uri?>(null) }
                val importLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.OpenDocument()
                ) { uri -> importUri = uri }
                val exportLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.CreateDocument("application/octet-stream")
                ) { uri ->
                    exportKind = uri?.let { "${exportKind.orEmpty()}|$it" }
                }
                RootScaffold(
                    map = {
                        MapSurface(
                            houses = viewModel.houses.collectAsStateWithLifecycleCompat().value,
                            gebiet = viewModel.activeGebiet.collectAsStateWithLifecycleCompat().value,
                            boundary = viewModel.activeGebiet.collectAsStateWithLifecycleCompat().value?.boundary.orEmpty(),
                            scope = viewModel.scope.collectAsStateWithLifecycleCompat().value,
                            onScopeChanged = viewModel::selectScope,
                            onHouseSelected = { selectedHouse = it },
                            onMapLongPress = { addCoordinate = it },
                            onBoundaryChanged = viewModel::updateBoundary,
                            onDeleteHouses = viewModel::deleteHouses
                        )
                    },
                    list = {
                        ListSurface(viewModel) { selectedHouse = it }
                    },
                    archive = {
                        ArchiveSurface(
                            viewModel = viewModel,
                            onCreateGebiet = { showGebietDialog = true },
                            onExportBackup = { exportKind = "backup"; exportLauncher.launch("nachbesuch-backup.json") },
                            onExportPdf = { exportKind = "pdf"; exportLauncher.launch("nachbesuche.pdf") },
                            onExportText = { exportKind = "text"; exportLauncher.launch("nachbesuche.txt") },
                            onImportBackup = { importLauncher.launch(arrayOf("application/json", "text/*", "application/octet-stream")) }
                        )
                    }
                )
                LaunchedEffect(importUri) {
                    val uri = importUri ?: return@LaunchedEffect
                    val raw = withContext(Dispatchers.IO) {
                        contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                    }
                    if (raw != null) viewModel.importBackup(raw)
                    importUri = null
                }
                LaunchedEffect(exportKind) {
                    val value = exportKind ?: return@LaunchedEffect
                    val separator = value.indexOf('|')
                    if (separator <= 0) return@LaunchedEffect
                    val kind = value.substring(0, separator)
                    val uri = android.net.Uri.parse(value.substring(separator + 1))
                    val bytes = withContext(Dispatchers.IO) {
                        when (kind) {
                            "backup" -> viewModel.exportBackupJson().toByteArray()
                            "text" -> viewModel.exportCurrentText().toByteArray()
                            "pdf" -> {
                                val scratch = File(cacheDir, "nachbesuche-export.pdf")
                                viewModel.exportCurrentPdf(scratch)
                                scratch.readBytes()
                            }
                            else -> byteArrayOf()
                        }
                    }
                    contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    exportKind = null
                }
                selectedHouse?.let { house ->
                    HouseDetailSheet(
                        house = viewModel.houses.collectAsStateWithLifecycleCompat().value.firstOrNull { it.id == house.id } ?: house,
                        scope = viewModel.scope.collectAsStateWithLifecycleCompat().value,
                        onScopeChange = viewModel::selectScope,
                        onOutcome = { unitID, outcome -> viewModel.recordOutcome(house.id, unitID, outcome, viewModel.scope.value) },
                        onResize = { viewModel.makeApartment(house.id, it) },
                        onDelete = { viewModel.deleteHouse(house.id); selectedHouse = null },
                        onDismiss = { selectedHouse = null }
                    )
                }
                addCoordinate?.let { coordinate ->
                    AddHouseDialog(
                        coordinate = coordinate,
                        onAdd = { address, value -> viewModel.addHouse(address, value); addCoordinate = null },
                        onDismiss = { addCoordinate = null }
                    )
                }
                if (showGebietDialog) {
                    CreateGebietDialog(
                        onCreate = { name, district, twoDay -> viewModel.createGebiet(name, district, twoDay); showGebietDialog = false },
                        onDismiss = { showGebietDialog = false }
                    )
                }
                if (showStoreWarning) {
                    AlertDialog(
                        onDismissRequest = { showStoreWarning = false },
                        title = { Text("Datenbank nicht lesbar") },
                        text = { Text("Die App läuft vorübergehend mit einem leeren Arbeitsbereich. Die ursprüngliche Datei wurde nicht gelöscht und sollte für eine Wiederherstellung gesichert werden.") },
                        confirmButton = { TextButton(onClick = { showStoreWarning = false }) { Text("Verstanden") } }
                    )
                }
                if (locationDenied) {
                    AlertDialog(
                        onDismissRequest = { locationDenied = false },
                        title = { Text("Standortzugriff ist deaktiviert") },
                        text = { Text("Du kannst die Karte weiterhin verwenden. Für deinen Standort und die empfohlene Route kannst du den Zugriff später in den Einstellungen erlauben.") },
                        confirmButton = {
                            TextButton(onClick = {
                                locationDenied = false
                                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                    data = android.net.Uri.parse("package:$packageName")
                                })
                            }) { Text("Einstellungen") }
                        },
                        dismissButton = { TextButton(onClick = { locationDenied = false }) { Text("Später") } }
                    )
                }
            }
        }
    }
}
