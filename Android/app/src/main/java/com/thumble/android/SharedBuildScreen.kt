package com.thumble.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable internal fun SharedBuildScreen(session: SharedBuildSession, onSave: (PendingBuildRecovery.Record) -> Unit, onDone: () -> Unit) {
    LaunchedEffect(Unit) { session.refresh() }
    BackHandler { if (!session.busy) onDone() }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        TextButton(enabled = !session.busy, onClick = onDone) { Text("Done") }
        LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            item {
                Text("Recover saved builds", style = MaterialTheme.typography.titleLarge)
                Text("Hosted shared builds have been retired. Export a saved profile file to import it locally on your Mac. Your originals stay on this device.")
                session.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (session.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                TextButton(enabled = !session.busy, onClick = { session.refresh() }) { Text("Refresh") }
                if (session.records.isEmpty()) Text("No saved builds to recover.")
            }
            items(session.records, key = { it.id }) { record ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(record.name, style = MaterialTheme.typography.titleMedium)
                    Text("${record.bytes} saved bytes", style = MaterialTheme.typography.bodySmall)
                    if (!record.profileFile) Text("This record needs manual recovery. Export keeps its original files together in an archive.")
                    OutlinedButton(enabled = !session.busy, onClick = { onSave(record) }) {
                        Text(if (record.profileFile) "Save profile file" else "Save recovery archive")
                    }
                }
            }
        }
    }
}
