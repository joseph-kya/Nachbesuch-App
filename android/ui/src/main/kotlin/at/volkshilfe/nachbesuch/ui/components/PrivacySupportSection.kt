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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import java.util.Properties

@Composable
fun PrivacySupportSection() {
    val context = LocalContext.current
    val uri = LocalUriHandler.current
    val publishing = remember {
        Properties().apply { context.assets.open("publishing.properties").use(::load) }
    }
    var showPrivacy by remember { mutableStateOf(false) }
    TextButton(onClick = { showPrivacy = true }) { Text("Datenschutz & Support") }
    if (showPrivacy) {
        val policy = remember { context.assets.open("privacy.txt").bufferedReader().use { it.readText() } }
        AlertDialog(
            onDismissRequest = { showPrivacy = false },
            title = { Text("Datenschutz & Support") },
            text = {
                Column(Modifier.heightIn(max = 480.dp).verticalScroll(rememberScrollState())) {
                    publishing.getProperty("developerName", "").takeIf { it.isNotBlank() }?.let { Text(it) }
                    Text(policy)
                    listOf("privacyPolicyURL" to "Datenschutzerklärung öffnen", "supportURL" to "Support öffnen").forEach { (key, label) ->
                        val url = publishing.getProperty(key, "")
                        if (url.startsWith("https://")) {
                            TextButton(onClick = { uri.openUri(url) }) { Text(label) }
                        }
                    }
                    val email = publishing.getProperty("supportEmail", "")
                    if (email.isNotBlank()) Text("Support: $email")
                }
            },
            confirmButton = { TextButton(onClick = { showPrivacy = false }) { Text("Fertig") } }
        )
    }
}
