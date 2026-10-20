package com.thumble.android

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.MotionEvent
import android.view.ViewGroup
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** Modal library; previews have no runtime callbacks or interactive control descendants. */
@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun SkinLibraryScreen(session: ControllerSession,dark: Boolean,onImport: ()->Unit,onDismiss: ()->Unit) {
    BackHandler(onBack=onDismiss)
    val profile=session.state.snapshot.selected
    val scheme=profile?.skinColorScheme(dark) ?: if(dark) "dark" else "light"
    val context=androidx.compose.ui.platform.LocalContext.current
    val preferences=remember { context.applicationContext.getSharedPreferences("skin-preview",Context.MODE_PRIVATE) }
    var hitAreas by rememberSaveable { mutableStateOf(preferences.getBoolean("hitAreas",false)) }
    var removing by remember { mutableStateOf<InstalledSkin?>(null) }
    LaunchedEffect(Unit) { session.refreshSkins() }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal=8.dp),horizontalArrangement=Arrangement.SpaceBetween,verticalAlignment=Alignment.CenterVertically) {
            TextButton(onClick=onDismiss) { Text("Done") }
            Text("Skins",style=MaterialTheme.typography.titleLarge)
            TextButton(enabled=!session.skinBusy,onClick=onImport) { Text("Import") }
        }
        if(session.skinBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(Modifier.weight(1f),contentPadding=PaddingValues(16.dp),verticalArrangement=Arrangement.spacedBy(20.dp)) {
            item {
                Text("Current keypad",style=MaterialTheme.typography.titleLarge)
                Text("Skins change appearance. Your controls, labels and Mac mappings stay intact.",style=MaterialTheme.typography.bodyMedium)
                if(profile!=null) {
                    SkinLibraryPreview(session,profile,null,dark,hitAreas)
                    Text(profile.name,style=MaterialTheme.typography.titleMedium)
                    val applied=profile.source.optJSONObject("skinReference")?.let { runCatching { SkinReference.parse(it) }.getOrNull() }
                    Text(if(applied==null) "Local appearance" else session.installedSkins.firstOrNull { it.reference==applied }?.let { "${it.name} · ${it.reference.version}" } ?: "Missing skin package")
                    if(applied!=null) OutlinedButton(enabled=!session.skinBusy,onClick={ session.detachSkin(scheme) }) { Text("Fork current appearance") }
                } else Text("Choose a saved keypad to preview and apply skins.")
                Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.SpaceBetween) {
                    Text("Show touch targets",Modifier.weight(1f))
                    Switch(checked=hitAreas,onCheckedChange={ hitAreas=it;preferences.edit().putBoolean("hitAreas",it).apply() },modifier=Modifier.semantics { contentDescription="Show touch targets" })
                }
                session.skinError?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                session.state.error?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                session.skinNotice?.let { Text(it) }
                if(session.state.pendingSkinRemovals>0) Text("${session.state.pendingSkinRemovals} skin removal waiting for Mac sync",style=MaterialTheme.typography.bodySmall)
                HorizontalDivider(Modifier.padding(top=16.dp))
                Text("Installed skins",style=MaterialTheme.typography.titleLarge,modifier=Modifier.padding(top=16.dp))
                Text("Available offline and shared with your paired Mac.",style=MaterialTheme.typography.bodyMedium)
                if(session.installedSkins.isEmpty() && !session.skinBusy) Text("No skins installed. Import a .pocketpad file to get started.",Modifier.padding(vertical=24.dp))
            }
            items(session.installedSkins,key={ "${it.reference.identifier}@${it.reference.version}" }) { installed ->
                val applied=profile?.source?.optJSONObject("skinReference")?.let { runCatching { SkinReference.parse(it) }.getOrNull() }==installed.reference
                var previewReady by remember(installed,profile,dark,session.skinRevision) { mutableStateOf(false) }
                Column(verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    if(profile!=null) SkinLibraryPreview(session,profile,installed.reference,dark,hitAreas,onReady={ previewReady=it })
                    Text(installed.name,style=MaterialTheme.typography.titleMedium)
                    Text("${installed.author} · v${installed.reference.version}",style=MaterialTheme.typography.bodyMedium)
                    if(installed.summary.isNotBlank()) Text(installed.summary,style=MaterialTheme.typography.bodyMedium)
                    if(installed.license.isNotBlank()) Text(installed.license,style=MaterialTheme.typography.labelMedium)
                    Button(enabled=!session.skinBusy && profile!=null && !applied && previewReady,onClick={ session.applySkin(installed.reference,scheme) },modifier=Modifier.fillMaxWidth()) {
                        Text(if(applied) "Applied" else "Apply ${installed.name}")
                    }
                    FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(enabled=!session.skinBusy,onClick={ session.exportSkin(installed.reference,true) },modifier=Modifier.semantics { contentDescription="Share ${installed.name}" }) { Text("Share") }
                        OutlinedButton(enabled=!session.skinBusy,onClick={ session.exportSkin(installed.reference,false) },modifier=Modifier.semantics { contentDescription="Save ${installed.name} package" }) { Text("Save file") }
                        TextButton(enabled=!session.skinBusy,onClick={ removing=installed },modifier=Modifier.semantics { contentDescription="Remove ${installed.name}" }) { Text("Remove") }
                    }
                    HorizontalDivider()
                }
            }
        }
    }
    (session.skinError ?: session.state.error)?.let { message ->
        AlertDialog(onDismissRequest={ session.dismissSkinError() },title={ Text("Skin library") },text={ Text(message) },
            confirmButton={ TextButton(onClick={ session.dismissSkinError() }) { Text("OK") } })
    }
    removing?.let { installed ->
        AlertDialog(onDismissRequest={ removing=null },title={ Text("Remove skin?") },text={ Text("Remove ${installed.name} from your library? Skins used by a keypad must be forked or replaced first.") },
            confirmButton={ TextButton(onClick={ removing=null;session.removeSkin(installed.reference) }) { Text("Remove skin") } },
            dismissButton={ TextButton(onClick={ removing=null }) { Text("Cancel") } })
    }
}

@Composable internal fun SkinLibraryPreview(session: ControllerSession,profile: ControllerProfile,reference: SkinReference?,dark: Boolean,hitAreas: Boolean,previewPackage: SkinPackage? = null,onReady: (Boolean)->Unit = {}) {
    val landscape=LayoutOrientation.of(profile.source.getJSONObject("customization"))==LayoutOrientation.LANDSCAPE
    val projection by key(profile,reference,dark,session.skinRevision,previewPackage?.archiveSHA256) { produceState<SkinRenderProjection?>(null) {
        value=if(reference==null && previewPackage==null) session.skinRenderer.resolveForDisplay(profile,landscape,dark) else withContext(Dispatchers.IO) {
            runCatching {
                val pkg=previewPackage ?: session.packageForPreview(reference!!)
                val result=SkinProfileResolver.apply(pkg,profile.layout(landscape),if(landscape) "landscape" else "portrait",profile.skinColorScheme(dark),preserveLocal=false)
                val raw=JSONObject(profile.source.toString()).put(if(landscape) "landscapeCustomization" else "portraitCustomization",result.customization)
                SkinRenderProjection(profile,landscape,dark,ControllerProfile(profile.id,profile.name,raw),result.compatibility,
                    if(result.compatibility.status=="compatible") null else "Some artwork does not match this keypad; compatible control materials are shown.")
            }.getOrElse { SkinRenderProjection(profile,landscape,dark,null,warning="Preview unavailable. Try importing this skin again.") }
        }
    }
    }
    LaunchedEffect(projection) { onReady(projection?.profile!=null) }
    Box(Modifier.fillMaxWidth().height(220.dp),contentAlignment=Alignment.Center) {
        val displayed=projection?.profile
        if(projection==null) CircularProgressIndicator()
        else if(displayed!=null) AndroidView(factory={ SkinPreviewSurface(it) },update={ it.show(displayed,landscape,dark,hitAreas) },
            modifier=Modifier.fillMaxSize().semantics { contentDescription="Skin preview for ${profile.name}" })
    }
    projection?.warning?.let { Text(it,style=MaterialTheme.typography.bodySmall) }
}

/** Draw at canonical geometry, then scale the entire preview. No touch or AX input route. */
internal class SkinPreviewSurface(context: Context): ViewGroup(context) {
    private val surface=ControllerSurface(context)
    private var profile: ControllerProfile?=null
    private var landscape=false
    private var hitAreas=false
    private var design=SkinCanvas(402.0,874.0)
    private val paint=Paint(Paint.ANTI_ALIAS_FLAG).apply { color=android.graphics.Color.BLUE;style=Paint.Style.STROKE;strokeWidth=1f }
    init { addView(surface);importantForAccessibility=IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS;descendantFocusability=FOCUS_BLOCK_DESCENDANTS;isFocusable=false;setWillNotDraw(false) }
    fun show(value: ControllerProfile,wide: Boolean,dark: Boolean,targets: Boolean) {
        profile=value;landscape=wide;hitAreas=targets;design=SkinCanvas.from(value.layout(wide))
        surface.show(value,0,wide,dark);requestLayout();invalidate()
    }
    override fun onMeasure(w: Int,h: Int) {
        setMeasuredDimension(MeasureSpec.getSize(w),MeasureSpec.getSize(h))
        val d=resources.displayMetrics.density
        surface.measure(MeasureSpec.makeMeasureSpec((design.width*d).toInt(),MeasureSpec.EXACTLY),MeasureSpec.makeMeasureSpec((design.height*d).toInt(),MeasureSpec.EXACTLY))
    }
    override fun onLayout(changed: Boolean,l: Int,t: Int,r: Int,b: Int) { surface.layout(0,0,surface.measuredWidth,surface.measuredHeight) }
    override fun dispatchDraw(canvas: Canvas) {
        val w=surface.width.toFloat();val h=surface.height.toFloat();if(w<=0 || h<=0) return
        val scale=minOf((width-24).coerceAtLeast(1)/w,(height-24).coerceAtLeast(1)/h)
        val save=canvas.save();canvas.translate((width-w*scale)/2,(height-h*scale)/2);canvas.scale(scale,scale)
        surface.draw(canvas)
        if(hitAreas) {
            val d=resources.displayMetrics.density
            profile?.controls(landscape)?.filter { it.kind !in setOf("decoration","text") }?.forEach { control ->
                val f=ControlGeometry.resolve(control,design.width,design.height,profile!!.layout(landscape).optString("layoutMode")=="southpaw")
                val hit=control.style.optJSONObject("hitInsets")
                val leading=hit?.finite("leading",0.0)?.coerceIn(0.0,96.0) ?: 0.0;val trailing=hit?.finite("trailing",0.0)?.coerceIn(0.0,96.0) ?: 0.0
                val top=hit?.finite("top",0.0)?.coerceIn(0.0,96.0) ?: 0.0;val bottom=hit?.finite("bottom",0.0)?.coerceIn(0.0,96.0) ?: 0.0
                val saved=canvas.save();canvas.rotate(control.style.finite("rotationDegrees",0.0).toFloat(),((f.centerX+(trailing-leading)/2)*d).toFloat(),((f.centerY+(bottom-top)/2)*d).toFloat())
                canvas.drawRect(((f.left-leading)*d).toFloat(),((f.top-top)*d).toFloat(),((f.left+f.width+trailing)*d).toFloat(),((f.top+f.height+bottom)*d).toFloat(),paint)
                canvas.restoreToCount(saved)
            }
        }
        canvas.restoreToCount(save)
    }
    override fun dispatchTouchEvent(event: MotionEvent)=false
}
