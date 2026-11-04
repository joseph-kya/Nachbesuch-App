package at.volkshilfe.nachbesuch.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

@Composable
fun PrivacySupportSection() {
    val context = LocalContext.current
    var showPrivacy by remember { mutableStateOf(false) }
    TextButton(onClick = { showPrivacy = true }) { Text("Datenschutz") }
    if (showPrivacy) {
        val policy = remember { context.assets.open("privacy.txt").bufferedReader().use { it.readText() } }
        AlertDialog(
            onDismissRequest = { showPrivacy = false },
            title = { Text("Datenschutz") },
            text = {
                Column(Modifier.heightIn(max = 480.dp).verticalScroll(rememberScrollState())) {
                    Text(policy)
                }
            },
            confirmButton = { TextButton(onClick = { showPrivacy = false }) { Text("Fertig") } }
        )
    }
}
