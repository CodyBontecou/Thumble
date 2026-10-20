package com.thumble.android

import android.content.Context
import android.view.MotionEvent
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Placed over the live controller's exact canvas, so measured reach matches play. */
@OptIn(ExperimentalLayoutApi::class)
@Composable internal fun ThumbCalibrationOverlay(profile: ControllerProfile,orientation: LayoutOrientation,token: Long,session: ControllerSession) {
    val layout=remember(token) { LayoutSnapshot.resolved(profile,orientation).oriented(orientation) }
    val context=LocalContext.current
    BoxWithConstraints(Modifier.fillMaxSize().testTag("thumb-calibration")) {
        val size=SkinCanvas(maxWidth.value.toDouble().coerceAtLeast(1.0),maxHeight.value.toDouble().coerceAtLeast(1.0))
        val safe=ThumbRect(0.0,0.0,size.width,size.height) // Parent already applies Android safe-drawing insets.
        val key=remember(token,size) {
            val device=android.provider.Settings.Secure.getString(context.contentResolver,android.provider.Settings.Secure.ANDROID_ID) ?: "${android.os.Build.MANUFACTURER}/${android.os.Build.MODEL}"
            ThumbCalibrationKey(profile.id,device,"${size.width}x${size.height}@${context.resources.displayMetrics.densityDpi}",orientation)
        }
        LaunchedEffect(key,token) { session.prepareThumbCalibration(token,key,layout) }
        val capture=session.thumbCapture
        val report by produceState<ThumbReport?>(null,capture?.calibration,size,capture?.complete) {
            value=null
            if(capture?.complete==true) value=withContext(Dispatchers.Default) {
                ThumbScorer.score(ThumbLayout.geometries(layout,size),capture.calibration.zones,size,safe)
            }
        }
        val tint=MaterialTheme.colorScheme.primary
        Canvas(Modifier.fillMaxSize()) {
            drawRect(androidx.compose.ui.graphics.Color.Black.copy(alpha=.20f))
            capture?.visibleZones?.forEach { zone ->
                val frame=zone.frame(size);val scaleX=this.size.width/size.width.toFloat();val scaleY=this.size.height/size.height.toFloat()
                val top=Offset(frame.x.toFloat()*scaleX,frame.y.toFloat()*scaleY)
                val extent=Size(frame.width.toFloat()*scaleX,frame.height.toFloat()*scaleY)
                drawOval(tint.copy(alpha=.14f),top,extent)
                drawOval(tint,top,extent,style=Stroke(3.dp.toPx(),pathEffect=if(zone.hand==ThumbHand.RIGHT) PathEffect.dashPathEffect(floatArrayOf(8.dp.toPx(),5.dp.toPx())) else null))
            }
        }
        BackHandler { if(!session.thumbBusy) session.client.finishLayoutEditing() }
        if(capture==null) {
            Surface(Modifier.align(Alignment.TopCenter).padding(16.dp),shape=MaterialTheme.shapes.medium) {
                Column(Modifier.padding(16.dp)) { Text("Loading thumb reach…");LinearProgressIndicator(Modifier.fillMaxWidth()) }
            }
        } else if(!capture.complete) {
            AndroidView(factory={ ThumbCaptureSurface(it) },update={ view ->
                view.enabledCapture=!session.thumbBusy
                view.onPoint={ x,y,final -> session.updateThumbCapture(token) { current ->
                    val p=ThumbPoint.of(x,y)
                    if(final) current.finish(p,System.currentTimeMillis()) else current.update(p)
                } }
                view.onCancel={ session.updateThumbCapture(token) { it.cancelDraft() } }
                view.onEstimate={ session.updateThumbCapture(token) { it.estimate(System.currentTimeMillis()) } }
                view.activeHand=capture.activeHand
            },modifier=Modifier.fillMaxSize().semantics { contentDescription="Thumb reach capture area" })
            Surface(Modifier.align(Alignment.TopCenter).padding(12.dp).widthIn(max=420.dp),shape=MaterialTheme.shapes.medium,color=MaterialTheme.colorScheme.surface) {
                Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(8.dp)) {
                    Text("Calibrate ${capture.activeHand!!.label} Thumb",style=MaterialTheme.typography.titleMedium)
                    Text("Hold your phone normally. Trace the comfortable area this thumb can reach, then lift.",style=MaterialTheme.typography.bodyMedium)
                    Text("Controls are paused during calibration.",style=MaterialTheme.typography.bodySmall)
                    session.thumbError?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                    FlowRow(horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick={ session.client.finishLayoutEditing() }) { Text("Cancel") }
                        TextButton(onClick={ session.updateThumbCapture(token) { it.estimate(System.currentTimeMillis()) } }) { Text("Use comfortable estimate") }
                    }
                }
            }
        } else {
            Surface(Modifier.align(Alignment.Center).padding(12.dp).widthIn(max=520.dp).heightIn(max=560.dp).fillMaxHeight(),shape=MaterialTheme.shapes.medium,color=MaterialTheme.colorScheme.surface) {
                Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp),verticalArrangement=Arrangement.spacedBy(12.dp)) {
                    Text("Thumb Placement Score",style=MaterialTheme.typography.titleLarge)
                    Text(report?.let { "${it.score} / 100" } ?: "Calculating…",modifier=Modifier.semantics { liveRegion=LiveRegionMode.Polite },style=MaterialTheme.typography.headlineLarge)
                    Text("Suggestions use your reach, safe areas, 44 dp controls and actual touch-region overlap.",style=MaterialTheme.typography.bodyMedium)
                    session.thumbError?.let { error ->
                        Text(error,color=MaterialTheme.colorScheme.error)
                        TextButton(enabled=!session.thumbBusy,onClick={ session.saveThumbCalibration(token) }) { Text("Retry saving reach") }
                    }
                    session.state.error?.let { Text(it,color=MaterialTheme.colorScheme.error) }
                    if(session.thumbBusy) { Text("Saving…");LinearProgressIndicator(Modifier.fillMaxWidth()) }
                    if(report?.suggestions?.isEmpty()==true) Text("No layout changes suggested")
                    report?.suggestions?.forEach { suggestion ->
                        Column(verticalArrangement=Arrangement.spacedBy(4.dp)) {
                            Text(suggestion.title,style=MaterialTheme.typography.titleMedium)
                            Text(suggestion.detail,style=MaterialTheme.typography.bodyMedium)
                            Button(enabled=!session.thumbBusy && session.thumbError==null,
                                modifier=Modifier.semantics { contentDescription="Apply: ${suggestion.title}" },
                                onClick={ session.applyThumbSuggestion(token,layout,suggestion,size,safe) }) { Text("Apply suggestion") }
                        }
                    }
                    Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.SpaceBetween) {
                        TextButton(enabled=!session.thumbBusy,onClick={ session.client.finishLayoutEditing() }) { Text("Cancel") }
                        Button(enabled=!session.thumbBusy,onClick={ session.client.finishLayoutEditing() }) { Text("Done") }
                    }
                }
            }
        }
    }
}

/** Single-finger trace only. Extra pointers, cancellation and resize discard the draft. */
internal class ThumbCaptureSurface(context: Context): View(context) {
    var onPoint: (Double,Double,Boolean)->Unit={ _,_,_ -> }
    var onCancel: ()->Unit={}
    var onEstimate: ()->Unit={}
    var enabledCapture=true
    private var pointer=-1
    var activeHand: ThumbHand?=null
        set(value) {
            if(field==value) return
            field=value;pointer=-1
            contentDescription="Thumb reach capture area. ${value?.label.orEmpty()} thumb. Double tap for a comfortable reach estimate."
            announceForAccessibility("Trace your ${value?.label?.lowercase().orEmpty()} thumb reach, then lift.")
        }
    init { isClickable=true;isFocusable=true;importantForAccessibility=IMPORTANT_FOR_ACCESSIBILITY_YES }
    override fun performClick(): Boolean { super.performClick();if(enabledCapture) onEstimate();return true }
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if(!enabledCapture) return true
        when(event.actionMasked) {
            MotionEvent.ACTION_DOWN -> { pointer=event.getPointerId(0);onPoint(event.x.toDouble()/maxOf(width,1),event.y.toDouble()/maxOf(height,1),false) }
            MotionEvent.ACTION_POINTER_DOWN,MotionEvent.ACTION_CANCEL -> { pointer=-1;onCancel() }
            MotionEvent.ACTION_MOVE -> {
                val index=event.findPointerIndex(pointer)
                if(index>=0) onPoint(event.getX(index).toDouble()/maxOf(width,1),event.getY(index).toDouble()/maxOf(height,1),false)
            }
            MotionEvent.ACTION_UP -> {
                val index=event.findPointerIndex(pointer)
                if(index>=0) onPoint(event.getX(index).toDouble()/maxOf(width,1),event.getY(index).toDouble()/maxOf(height,1),true)
                pointer=-1
            }
        }
        return true
    }
    override fun onSizeChanged(w: Int,h: Int,oldw: Int,oldh: Int) { super.onSizeChanged(w,h,oldw,oldh);if(pointer>=0) { pointer=-1;onCancel() } }
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) { super.onWindowFocusChanged(hasWindowFocus);if(!hasWindowFocus && pointer>=0) { pointer=-1;onCancel() } }
    override fun onDetachedFromWindow() { if(pointer>=0) { pointer=-1;onCancel() };super.onDetachedFromWindow() }
}
