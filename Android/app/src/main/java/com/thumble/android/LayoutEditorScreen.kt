package com.thumble.android

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** Completed actions persist first. Previews and rendered skin assets stay local. */
@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable internal fun LayoutEditorScreen(profile: ControllerProfile, orientation: LayoutOrientation,
    token: Long, client: ControllerClient, renderer: SkinRenderRepository, dark: Boolean, hostError: String?, initialLayout: LayoutSnapshot? = null) {
    val entry = remember(token) { initialLayout ?: LayoutSnapshot.resolved(profile, orientation).oriented(orientation) }
    val current = remember(token) { LayoutSnapshot.resolved(profile, orientation).oriented(orientation) }
    val history = remember(token) { LayoutEditSession(entry).apply { commit(current) } }
    var preview by remember(token) { mutableStateOf(current) }
    var busy by remember(token) { mutableStateOf(false) }
    var historyRevision by remember(token) { mutableIntStateOf(0) }
    var feedback by remember(token) { mutableStateOf("Completed changes save locally and sync when your Mac is connected.") }
    var pendingDelete by remember(token) { mutableStateOf<Control?>(null) }
    var confirmExit by remember(token) { mutableStateOf(false) }
    var active by remember(token) { mutableStateOf(true) }
    DisposableEffect(token) { onDispose { active = false } }
    // Referencing this state makes non-Compose history changes observable.
    @Suppress("UNUSED_VARIABLE") val observedHistory = historyRevision
    fun save(value: LayoutSnapshot, success: () -> Unit) {
        if (busy) return
        busy = true
        client.commitLayoutEdit(value, token) { saved ->
            if (active) {
                busy = false
                if (saved) { success(); historyRevision++; feedback = "Saved on this Android device." }
                else { preview = history.committed; feedback = "Could not save the change. Your last saved layout is kept." }
            }
        }
    }
    fun cancel() {
        if (!history.hasChanges) { client.finishLayoutEditing(); return }
        save(entry) { history.cancel(); client.finishLayoutEditing() }
    }
    BackHandler { if(!busy) { if(history.hasChanges) confirmExit = true else client.finishLayoutEditing() } }
    val previewProfile = remember(profile, preview) {
        LayoutEditJournal.applying(profile, PendingLayoutEdit(profile.id, orientation, preview, 0, null))
    }
    var projection by remember(token) { mutableStateOf<SkinRenderProjection?>(null) }
    LaunchedEffect(previewProfile, dark) {
        projection = renderer.resolveForDisplay(previewProfile, orientation == LayoutOrientation.LANDSCAPE, dark)
    }
    val tint = MaterialTheme.colorScheme.primary.toArgb()
    val onTint = MaterialTheme.colorScheme.onPrimary.toArgb()
    // Keep readiness and the displayed projection in the same Compose snapshot.
    // AndroidView can rerun update independently of its parent's recomposition.
    val acceptsEdits = !busy && projection?.matches(previewProfile, orientation == LayoutOrientation.LANDSCAPE, dark)==true
    Column(Modifier.fillMaxSize().safeDrawingPadding().semantics { testTagsAsResourceId = true }) {
        Row(Modifier.fillMaxWidth().padding(horizontal=8.dp), horizontalArrangement=Arrangement.SpaceBetween) {
            TextButton(enabled=!busy, modifier=Modifier.testTag("layout-cancel"), onClick={ cancel() }) { Text("Cancel") }
            TextButton(enabled=!busy && history.canUndo, modifier=Modifier.testTag("layout-undo"), onClick={
                history.undoSnapshot?.let { previous -> save(previous) { history.undo(); preview = history.committed } }
            }) { Text("Undo") }
            TextButton(enabled=!busy, modifier=Modifier.testTag("layout-done"), onClick={ client.finishLayoutEditing() }) { Text("Done") }
        }
        Text("Edit layout", Modifier.padding(horizontal=16.dp), style=MaterialTheme.typography.titleLarge)
        Text("Drag a control to move it. Select one to resize, rotate, or delete.", Modifier.padding(horizontal=16.dp,vertical=4.dp), style=MaterialTheme.typography.bodySmall)
        Box(Modifier.fillMaxWidth().heightIn(min=48.dp).padding(horizontal=16.dp)) {
            Text(if(busy) "Saving…" else hostError ?: feedback,
                color=if(hostError!=null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                style=MaterialTheme.typography.labelSmall)
        }
        projection?.warning?.let { Text(it, Modifier.padding(horizontal=16.dp), style=MaterialTheme.typography.labelSmall) }
        val displayed = projection?.profile
        if (displayed == null) LinearProgressIndicator(Modifier.fillMaxWidth())
        else AndroidView(factory={ LayoutEditorSurface(it) }, update={ view ->
            view.onPatch = { patch, final ->
                if (!busy) {
                    val next = patch?.applying(preview) ?: history.committed
                    if (final && !next.samePresentation(history.committed)) save(next) { history.commit(next); preview = next }
                    else { preview = next; history.preview(next) }
                }
            }
            view.onDelete = { if(!busy) pendingDelete = it }
            view.show(displayed, orientation == LayoutOrientation.LANDSCAPE, profile.skinColorScheme(dark)=="dark",
                acceptsEdits, tint, onTint)
        }, modifier=Modifier.fillMaxWidth().weight(1f).testTag("layout-editor-canvas"))
    }
    pendingDelete?.let { control ->
        AlertDialog(onDismissRequest={ pendingDelete=null }, title={ Text("Delete element?") },
            text={ Text("Remove ${control.accessibilityName} from this keypad setup?") },
            confirmButton={ TextButton(enabled=!busy,onClick={
                val next=LayoutControlPatch(control.id,delete=true).applying(history.committed)
                pendingDelete=null
                save(next) { history.commit(next); preview=next }
            }, modifier=Modifier.semantics { contentDescription="Confirm deletion" }) { Text("Delete") } },
            dismissButton={ TextButton(onClick={ pendingDelete=null },modifier=Modifier.semantics { contentDescription="Cancel deletion" }) { Text("Cancel") } })
    }
    if (confirmExit) AlertDialog(onDismissRequest={ confirmExit=false }, title={ Text("Finish editing?") },
        text={ Text("Keep your saved changes, or restore the layout from when editing began.") },
        confirmButton={ TextButton(onClick={ confirmExit=false; client.finishLayoutEditing() }) { Text("Keep changes") } },
        dismissButton={ TextButton(onClick={ confirmExit=false; cancel() }) { Text("Restore starting layout") } })
}
