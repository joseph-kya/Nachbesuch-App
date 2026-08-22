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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import at.volkshilfe.nachbesuch.data.backup.UnreadableHouseException
import at.volkshilfe.nachbesuch.data.prefs.AppSettingsStore
import at.volkshilfe.nachbesuch.data.prefs.RouteStore
import at.volkshilfe.nachbesuch.domain.model.House
import at.volkshilfe.nachbesuch.domain.model.StoredCoordinate
import at.volkshilfe.nachbesuch.ui.RootScaffold
import at.volkshilfe.nachbesuch.ui.theme.NachbesuchTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

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
                var showStoreWarning by remember { mutableStateOf(false) }

                // Export pipeline: pick kind → confirm options → SAF target → write.
                var pendingExportKind by remember { mutableStateOf<String?>(null) }
                var confirmedOptions by remember { mutableStateOf(ExportOptions()) }
                var writeRequest by remember { mutableStateOf<Pair<String, android.net.Uri>?>(null) }
                var exportError by remember { mutableStateOf<String?>(null) }

                // Import pipeline: read file → merge → report outcome.
                var importUri by remember { mutableStateOf<android.net.Uri?>(null) }
                var importOutcome by remember { mutableStateOf<BackupImportOutcome?>(null) }

                val importLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.OpenDocument()
                ) { uri -> importUri = uri }
                val exportLauncher = rememberLauncherForActivityResult(
                    ActivityResultContracts.CreateDocument("application/octet-stream")
                ) { uri ->
                    val kind = pendingExportKind
                    if (uri != null && kind != null) writeRequest = kind to uri
                    pendingExportKind = null
                }

                LaunchedEffect(Unit) {
                    viewModel.storeUnreadable.collect { unreadable -> if (unreadable) showStoreWarning = true }
                }
                LaunchedEffect(importUri) {
                    val uri = importUri ?: return@LaunchedEffect
                    importUri = null
                    val raw = withContext(Dispatchers.IO) {
                        runCatching {
                            contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
                        }.getOrNull()
                    }
                    importOutcome = when {
                        raw == null -> BackupImportOutcome.Failure("Die Datei konnte nicht gelesen werden.")
                        else -> try {
                            val result = viewModel.importBackup(raw)
                            BackupImportOutcome.Success(result.insertedGebiete, result.insertedHouses, result.skippedHouses)
                        } catch (error: Exception) {
                            BackupImportOutcome.Failure(error.message ?: "Die Datei ist kein gültiges Backup.")
                        }
                    }
                }
                LaunchedEffect(writeRequest) {
                    val request = writeRequest ?: return@LaunchedEffect
                    writeRequest = null
                    try {
                        val bytes = withContext(Dispatchers.IO) {
                            when (request.first) {
                                "backup" -> viewModel.exportBackupJson().toByteArray()
                                "text" -> viewModel.exportCurrentText(confirmedOptions).toByteArray()
                                "legacy" -> viewModel.exportCurrentLegacyText().toByteArray()
                                "pdf" -> {
                                    val scratch = File(cacheDir, "nachbesuch-export.pdf")
                                    viewModel.exportCurrentPdf(scratch, confirmedOptions)
                                    scratch.readBytes()
                                }
                                else -> byteArrayOf()
                            }
                        }
                        withContext(Dispatchers.IO) {
                            contentResolver.openOutputStream(request.second)?.use { it.write(bytes) }
                        }
                    } catch (error: UnreadableHouseException) {
                        exportError = "${error.address} enthält unlesbare Türdaten. Der Export wurde abgebrochen, damit keine Einträge verloren gehen."
                    } catch (error: Exception) {
                        exportError = error.message ?: "Der Export ist fehlgeschlagen."
                    }
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
                            onDeleteHouses = viewModel::deleteHouses,
                            onImportHouses = viewModel::addImportedHouses,
                            routeStore = remember { RouteStore(this@MainActivity) },
                            settingsStore = remember { AppSettingsStore(this@MainActivity) }
                        )
                    },
                    list = {
                        ListSurface(viewModel) { selectedHouse = it }
                    },
                    archive = {
                        ArchiveSurface(
                            viewModel = viewModel,
                            onCreateGebiet = { showGebietDialog = true },
                            onExportBackup = { pendingExportKind = "backup" },
                            onExportPdf = { pendingExportKind = "pdf" },
                            onExportText = { pendingExportKind = "text" },
                            onExportLegacy = { pendingExportKind = "legacy" },
                            onImportBackup = { importLauncher.launch(arrayOf("application/json", "text/*", "application/octet-stream")) }
                        )
                    }
                )

                pendingExportKind?.let { kind ->
                    if (kind == "backup") {
                        // Backups are always complete: no options to choose.
                        LaunchedEffect(pendingExportKind) {
                            pendingExportKind = null
                            exportLauncher.launch(exportFileName("Backup", "json"))
                        }
                    } else if (kind == "legacy") {
                        LaunchedEffect(pendingExportKind) {
                            pendingExportKind = null
                            val subject = viewModel.activeGebiet.value?.displayName
                            exportLauncher.launch(exportFileName("${subject.orEmpty()}-Legacy", "txt"))
                        }
                    } else {
                        ExportOptionsDialog(
                            onConfirm = { options ->
                                confirmedOptions = options
                                pendingExportKind = null
                                val subject = viewModel.activeGebiet.value?.displayName
                                exportLauncher.launch(
                                    when (kind) {
                                        "pdf" -> exportFileName(subject, "pdf")
                                        else -> exportFileName(subject, "txt")
                                    }
                                )
                            },
                            onDismiss = { pendingExportKind = null }
                        )
                    }
                }

                selectedHouse?.let { house ->
                    HouseDetailSheet(
                        house = viewModel.houses.collectAsStateWithLifecycleCompat().value.firstOrNull { it.id == house.id } ?: house,
                        scope = viewModel.scope.collectAsStateWithLifecycleCompat().value,
                        onScopeChange = viewModel::selectScope,
                        onOutcome = { unitID, outcome -> viewModel.recordOutcome(house.id, unitID, outcome, viewModel.scope.value) },
                        onFillOpenDoors = { outcome -> viewModel.fillOpenDoors(house.id, outcome, viewModel.scope.value) },
                        onRenameUnit = { unitID, label -> viewModel.renameUnit(house.id, unitID, label) },
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
                importOutcome?.let { outcome ->
                    AlertDialog(
                        onDismissRequest = { importOutcome = null },
                        title = {
                            Text(
                                when (outcome) {
                                    is BackupImportOutcome.Success -> "Backup importiert"
                                    is BackupImportOutcome.Failure -> "Import nicht möglich"
                                }
                            )
                        },
                        text = {
                            Text(
                                when (outcome) {
                                    is BackupImportOutcome.Success -> {
                                        val success = outcome as BackupImportOutcome.Success
                                        buildString {
                                            append("${success.gebiete} Gebiete und ${success.houses} Häuser übernommen")
                                            if (success.skipped > 0) {
                                                append(". ${success.skipped} Einträge übersprungen (unlesbar oder ohne zugehöriges Gebiet).")
                                            } else append(".")
                                        }
                                    }
                                    is BackupImportOutcome.Failure -> outcome.message
                                }
                            )
                        },
                        confirmButton = { TextButton(onClick = { importOutcome = null }) { Text("OK") } }
                    )
                }
                exportError?.let { message ->
                    AlertDialog(
                        onDismissRequest = { exportError = null },
                        title = { Text("Export abgebrochen") },
                        text = { Text(message) },
                        confirmButton = { TextButton(onClick = { exportError = null }) { Text("OK") } }
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

    /** "Nachbesuch-Ottakring-2026-08-21.pdf", matching the iOS file naming. */
    private fun exportFileName(subject: String?, extension: String): String {
        val slug = subject.orEmpty()
            .replace(Regex("[^A-Za-z0-9ÄÖÜäöüß]+"), "-")
            .trim('-')
            .ifBlank { "Export" }
        val date = DateTimeFormatter.ofPattern("yyyy-MM-dd")
            .withZone(ZoneId.systemDefault())
            .format(Instant.now())
        return "Nachbesuch-$slug-$date.$extension"
    }
}

private sealed interface BackupImportOutcome {
    data class Success(val gebiete: Int, val houses: Int, val skipped: Int) : BackupImportOutcome
    data class Failure(val message: String) : BackupImportOutcome
}
