package com.thumble.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp

@Composable internal fun SharedBuildScreen(session: SharedBuildSession,activePreview: SharedBuildPracticePreview?,closePreview: ()->Unit,onDone: ()->Unit,adoptionServer: String?=null) {
    var link by remember { mutableStateOf("") } // Never save a bearer link in instance state.
    var deleting by remember { mutableStateOf<PendingSharedBuild?>(null) }
    var adopting by remember { mutableStateOf<Pair<PendingSharedBuild,String>?>(null) }
    LaunchedEffect(Unit) { session.refresh() }
    BackHandler { if(!session.busy) { if(session.review!=null) session.cancelReview() else { session.cancelDownload();onDone() } } }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal=8.dp),horizontalArrangement=Arrangement.SpaceBetween) {
            TextButton(enabled=!session.busy,onClick={ session.cancelDownload();onDone() }) { Text("Done") }
            Text("Shared builds",Modifier.padding(top=12.dp),style=MaterialTheme.typography.titleLarge)
        }
        LazyColumn(Modifier.fillMaxSize(),contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
            item {
                Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    Text("Open a shared build",style=MaterialTheme.typography.titleMedium)
                    Text("Review a Thumble builder link, then keep it on this Android device for practice. Your Mac profiles stay unchanged.")
                    OutlinedTextField(value=link,onValueChange={ link=it.take(2049) },label={ Text("Shared-build link") },singleLine=true,
                        visualTransformation=PasswordVisualTransformation(),keyboardOptions=KeyboardOptions(keyboardType=KeyboardType.Uri),modifier=Modifier.fillMaxWidth())
                    Button(enabled=link.isNotEmpty() && !session.fetching && !session.busy,onClick={
                        val raw=link;link=""
                        session.openLink(raw)
                    }) { Text("Open link") }
                    if(session.fetching) {
                        Text("Downloading shared build…");LinearProgressIndicator(Modifier.fillMaxWidth())
                        TextButton(onClick={ session.cancelDownload() }) { Text("Cancel download") }
                    }
                    session.error?.let { message ->
                        Text(message,color=MaterialTheme.colorScheme.error)
                        TextButton(onClick={ session.dismissError() }) { Text("Dismiss error") }
                    }
                }
            }
            item {
                Column(verticalArrangement=Arrangement.spacedBy(4.dp)) {
                    Text("Pending shared builds",style=MaterialTheme.typography.titleLarge)
                    Text("Kept for Practice Mode on this device. These are not installed on your Mac.")
                    if(adoptionServer==null) Text("Connect to a Mac receiver that supports shared-build adoption to add a kept build to your Mac.")
                    if(session.adoption?.phase==ArtifactAdoptionPhase.SUCCEEDED) Text("Shared build added to your Mac.")
                    if(session.records.isEmpty()) Text("No shared builds kept yet.")
                }
            }
            items(session.records,key={it.id}) { record ->
                val progress=session.adoption?.takeIf { it.metadata.recordID==record.id }
                val working=session.adoption?.active==true
                Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    Text(record.profiles.firstOrNull()?.name ?: "Shared Controller",style=MaterialTheme.typography.titleMedium)
                    Text("${record.profiles.size} profiles · ${record.bytes} bytes",style=MaterialTheme.typography.bodySmall)
                    if(record.state==PendingBuildState.FAILED) Text("Previous adoption did not finish. This build is still on your device.")
                    if(progress?.active==true) {
                        Text(if(progress.phase==ArtifactAdoptionPhase.AWAITING_SNAPSHOT) "Waiting for Mac profiles…" else "Sending shared build · ${progress.sentChunks}/${progress.metadata.chunkCount}")
                        LinearProgressIndicator(Modifier.fillMaxWidth())
                        TextButton(onClick={ session.onCancelAdoption() }) { Text("Cancel adoption") }
                    }
                    Row(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(enabled=!session.busy && !working,onClick={ session.preview(record.id) },modifier=Modifier.semantics { contentDescription="Preview ${record.profiles.firstOrNull()?.name.orEmpty()}" }) { Text("Preview") }
                        TextButton(enabled=!session.busy && !working && record.state!=PendingBuildState.ADOPTING,onClick={ deleting=record },modifier=Modifier.semantics { contentDescription="Delete shared build ${record.profiles.firstOrNull()?.name.orEmpty()}" }) { Text("Delete") }
                    }
                    OutlinedButton(enabled=!session.busy && !working && adoptionServer!=null && record.state!=PendingBuildState.ADOPTED,
                        onClick={ adoptionServer?.let { adopting=record to it } },modifier=Modifier.semantics { contentDescription="Adopt shared build ${record.profiles.firstOrNull()?.name.orEmpty()} on Mac" }) {
                        Text(if(record.state==PendingBuildState.FAILED) "Retry adoption" else "Adopt on Mac")
                    }
                    HorizontalDivider()
                }
            }
        }
    }
    session.review?.let { review ->
        AlertDialog(onDismissRequest={ session.cancelReview() },title={ Text("Preview Shared Build") },containerColor=MaterialTheme.colorScheme.surface,
            text={ Column(Modifier.verticalScroll(rememberScrollState()),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text("From ${review.sourceHost}")
                Text("${review.artifact.summaries.size} profiles · ${review.artifact.byteCount} bytes")
                Text("Integrity ${review.artifact.contentHash.take(12)}")
                review.artifact.summaries.forEach { summary ->
                    val name=StringBuilder();summary.name.codePoints().forEach { name.appendCodePoint(if(SkinText.isControl(it)) 32 else it) }
                    Text(SkinText.trim(name.toString()).ifEmpty { "Untitled Profile" })
                }
                Text("Preview runs only in Practice Mode. It will not send input or change profiles on your Mac.")
                session.error?.let { Text(it,color=MaterialTheme.colorScheme.error) }
            } },
            confirmButton={ TextButton(enabled=!session.busy,onClick={ session.keep() }) { Text(if(session.busy) "Keeping…" else "Preview & Keep") } },
            dismissButton={ TextButton(enabled=!session.busy,onClick={ session.cancelReview() }) { Text("Cancel") } })
    }
    deleting?.let { record ->
        AlertDialog(onDismissRequest={ deleting=null },title={ Text("Delete shared build?") },
            text={ Text("Remove this pending build from this Android device?") },
            confirmButton={ TextButton(onClick={ deleting=null;if(activePreview?.recordID==record.id) closePreview();session.delete(record.id) }) { Text("Delete build") } },
            dismissButton={ TextButton(onClick={ deleting=null }) { Text("Cancel") } })
    }
    adopting?.let { (record,server) ->
        AlertDialog(onDismissRequest={ adopting=null },title={ Text("Add shared build to Mac?") },
            text={ Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                Text("Add copies of ${record.profiles.size} profiles to the connected Mac and select this build’s active profile. Your current default stays unchanged.")
                Text("Mac identity ${server.take(12)}")
                if(adoptionServer!=server) Text("The Mac connection changed. Close this review and choose Adopt again.")
            } },
            confirmButton={ TextButton(enabled=adoptionServer==server && !session.busy,onClick={ adopting=null;session.adopt(record.id,server) }) { Text("Add to Mac") } },
            dismissButton={ TextButton(onClick={ adopting=null }) { Text("Cancel") } })
    }
}
