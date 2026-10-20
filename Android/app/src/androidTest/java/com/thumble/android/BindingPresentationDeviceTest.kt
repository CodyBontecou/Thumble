package com.thumble.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.MotionEvent
import android.view.View
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class BindingPresentationDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private fun profile(kind: String="button",label: String="Launch",caption: String="Open terminal",labels: Boolean=true): ControllerProfile {
        val element=JSONObject().put("id",UUID.randomUUID().toString()).put("kind",kind).put("label",label)
            .put("presentation",JSONObject().put("caption",caption).put("accessibilityName","Accessible launch"))
            .put("layout",JSONObject().put("widthScale",2).put("heightScale",1.6))
        return ControllerProfile.parse(JSONObject().put("id",UUID.randomUUID().toString()).put("customization",
            JSONObject().put("showsButtonLabels",labels).put("elements",JSONArray().put(element))))
    }
    private fun bindings(profile: ControllerProfile,text: String="⌘Return")=listOf(ProfileBindingPresentations(profile.id,null,
        listOf(BindingPresentation(profile.controls(false).first().id,"primary",text,"Command Return"))))
    private fun surface(profile: ControllerProfile): Pair<ControllerSurface,ControlFaceView> {
        val surface=ControllerSurface(instrumentation.targetContext);surface.show(profile,1,false,false)
        measure(surface)
        return surface to surface.getChildAt(0) as ControlFaceView
    }
    private fun measure(view: View) {
        view.measure(View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(350,View.MeasureSpec.EXACTLY));view.layout(0,0,800,350)
    }
    @Test fun metadataChangesAndGlyphPreferenceRetainPressIdentityAndAccessibleOutput() {
        instrumentation.runOnMainSync {
            val profile=profile();val (surface,face)=surface(profile)
            val edges=mutableListOf<Pair<Boolean,Long>>();surface.onEdge={ _,down,id -> edges.add(down to id) }
            fun touch(action: Int) {
                val event=MotionEvent.obtain(0,android.os.SystemClock.uptimeMillis(),action,(face.left+face.right)/2f,(face.top+face.bottom)/2f,0)
                assertTrue(surface.dispatchTouchEvent(event));event.recycle()
            }
            touch(MotionEvent.ACTION_DOWN)
            surface.showBindingPresentations(bindings(profile),true)
            assertEquals(listOf("Open terminal","⌘Return"),face.secondaryLines)
            assertEquals("Command Return",face.createAccessibilityNodeInfo().hintText.toString())
            surface.showBindingPresentations(bindings(profile),false)
            assertSame(face,surface.getChildAt(0));assertEquals(listOf("Open terminal"),face.secondaryLines)
            assertEquals("Command Return",face.createAccessibilityNodeInfo().hintText.toString())
            assertEquals("Accessible launch",face.contentDescription)
            assertEquals(1,edges.size)
            touch(MotionEvent.ACTION_UP)
            assertEquals(2,edges.size);assertEquals(edges.first().second,edges.last().second)
            assertFalse(edges.last().first)
        }
    }
    @Test fun visibilityMatchesNativeAndDuplicatesCompareTheControlLabel() {
        instrumentation.runOnMainSync {
            val hidden=profile(labels=false);val (surface,face)=surface(hidden)
            surface.showBindingPresentations(bindings(hidden),true)
            assertTrue(face.secondaryLines.isEmpty())
            assertEquals("Command Return",face.createAccessibilityNodeInfo().hintText.toString())
            val text=profile(kind="text",labels=false);val (textSurface,textFace)=surface(text)
            textSurface.showBindingPresentations(bindings(text),true)
            assertEquals(listOf("Open terminal"),textFace.secondaryLines)
            val duplicate=profile(label="É");val (duplicateSurface,duplicateFace)=surface(duplicate)
            duplicateSurface.showBindingPresentations(bindings(duplicate," e "),true)
            assertEquals(listOf("Open terminal"),duplicateFace.secondaryLines)
            val literal=profile(caption="null");val (_,literalFace)=surface(literal)
            assertEquals(listOf("null"),literalFace.secondaryLines)
        }
    }
    @Test fun wholeFaceBlurRefreshesWhenBindingHintsChange() {
        instrumentation.runOnMainSync {
            val profile=profile(caption="")
            profile.layout(false).getJSONArray("elements").getJSONObject(0).getJSONObject("layout")
                .put("visualStyle",JSONObject().put("normal",JSONObject().put("blurRadius",1.5)))
            val (surface,face)=surface(profile)
            fun pixels(): IntArray {
                val bitmap=Bitmap.createBitmap(face.width,face.height,Bitmap.Config.ARGB_8888)
                face.draw(Canvas(bitmap));val pixels=IntArray(face.width*face.height)
                bitmap.getPixels(pixels,0,face.width,0,0,face.width,face.height);bitmap.recycle();return pixels
            }
            val before=pixels()
            surface.showBindingPresentations(bindings(profile),true)
            val hinted=pixels()
            assertFalse("blur cache must include current secondary text",before.contentEquals(hinted))
            surface.showBindingPresentations(bindings(profile),false)
            assertTrue("clearing hints restores the unchanged original face",before.contentEquals(pixels()))
        }
    }
    @Test fun presentationMetadataAndPreferenceSurviveDiskReloadAndForgetPreservesPreference() {
        val namespace="binding-test-${UUID.randomUUID()}"
        val context=instrumentation.targetContext
        try {
            val profile=profile();val snapshot=ProfileSnapshot(listOf(profile),profile.id,profile.id,bindings(profile))
            val store=AndroidSessionStore(context,namespace)
            store.saveSnapshot(snapshot);store.savePreferences(ClientPreferences(showBindingGlyphs=false))
            val reloaded=AndroidSessionStore(context,namespace)
            assertEquals(snapshot.bindingPresentations,reloaded.loadSnapshot().bindingPresentations)
            assertFalse(reloaded.loadPreferences().showBindingGlyphs)
            reloaded.forgetMac()
            assertTrue(reloaded.loadSnapshot().bindingPresentations.isEmpty())
            assertFalse(reloaded.loadPreferences().showBindingGlyphs)
        } finally { File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
    private fun await(label: String,predicate: ()->Boolean) {
        val deadline=android.os.SystemClock.elapsedRealtime()+12_000
        while(!predicate() && android.os.SystemClock.elapsedRealtime()<deadline) android.os.SystemClock.sleep(20)
        assertTrue(label,predicate())
    }
    @Test fun metadataOnlySocketUpdatesPersistWithoutRetiringInputGeneration() {
        val profile=profile();val store=MemorySessionStore()
        val peer=java.util.concurrent.atomic.AtomicReference<okhttp3.WebSocket>()
        val state=java.util.concurrent.atomic.AtomicReference(ClientState())
        val server=okhttp3.mockwebserver.MockWebServer()
        server.enqueue(okhttp3.mockwebserver.MockResponse().withWebSocketUpgrade(object:okhttp3.WebSocketListener() {
            override fun onMessage(ws: okhttp3.WebSocket,text: String) {
                if(JSONObject(text).optString("type")=="hello") {
                    peer.set(ws)
                    ws.send(WireCodec.message("pairing_accepted").put("inputProtocolVersion",3)
                        .put("serverID","bindings-fixture").put("authToken","test-only")
                        .put("gamepadProfiles",JSONArray().put(profile.source)).put("gamepadProfileID",profile.id.toString()).toString())
                }
            }
        }))
        server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val client=ControllerClient(store) { state.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"))
            await("paired") { state.get().paired }
            val revision=state.get().surfaceRevision
            peer.get().send(WireCodec.message("gamepad_profiles").put("bindingPresentations",BindingPresentations.encode(bindings(profile))).toString())
            await("binding metadata received") { state.get().snapshot.bindingPresentations.isNotEmpty() }
            assertEquals(revision,state.get().surfaceRevision)
            assertEquals(bindings(profile),store.loadSnapshot().bindingPresentations)
            client.setShowBindingGlyphs(false)
            await("preference saved") { !state.get().showBindingGlyphs }
            assertFalse(store.loadPreferences().showBindingGlyphs)
            assertEquals(revision,state.get().surfaceRevision)
            peer.get().send(WireCodec.message("gamepad_profiles").put("bindingPresentations",JSONArray()).toString())
            await("explicit empty clears") { state.get().snapshot.bindingPresentations.isEmpty() }
            assertEquals(revision,state.get().surfaceRevision)
        } finally { client.disconnect();client.dispose();server.shutdown() }
    }
    @Test fun realRustReceiverSendsAuthoritativeBindingMetadataToAndroidRenderer() {
        val qr=InstrumentationRegistry.getArguments().getString("bindingPairingQR")
        org.junit.Assume.assumeTrue("requires isolated receiver driver",!qr.isNullOrBlank())
        val state=java.util.concurrent.atomic.AtomicReference(ClientState())
        val client=ControllerClient(MemorySessionStore()) { state.set(it) }
        try {
            client.connect(PairingTarget.parse(qr!!))
            await("real Rust pairing") { state.get().paired }
            val snapshot=state.get().snapshot;val profile=snapshot.selected!!
            val entries=BindingPresentations.entries(snapshot.bindingPresentations,profile.id,false)
            assertEquals("⌘Tab",entries.first().compactText)
            assertEquals("Command Tab",entries.first().accessibilityText)
            instrumentation.runOnMainSync {
                val (surface,face)=surface(profile)
                surface.showBindingPresentations(snapshot.bindingPresentations,true)
                assertEquals(listOf("Receiver caption","⌘Tab"),face.secondaryLines)
                assertEquals("Command Tab",face.createAccessibilityNodeInfo().hintText.toString())
            }
        } finally { client.disconnect();client.dispose() }
    }
    @Test fun captureCaptionAndHintMatrix() {
        instrumentation.runOnMainSync {
            val context=instrumentation.targetContext
            val root=android.widget.LinearLayout(context).apply { orientation=android.widget.LinearLayout.VERTICAL;setBackgroundColor(android.graphics.Color.WHITE) }
            val cases=listOf(Triple("button","Launch","Open terminal"),Triple("button","A","Caption plus hint"),
                Triple("text","Notes","Caption without binding"),Triple("trackpad","Pointer","Two finger scroll"),
                Triple("trigger","Throttle","Digital threshold"),Triple("button","É","Duplicate binding hidden"))
            cases.forEachIndexed { index,(kind,label,caption) ->
                val profile=profile(kind,label,caption)
                val surface=ControllerSurface(context);surface.show(profile,1,false,false)
                val id=profile.controls(false).first().id
                val part=if(kind=="trigger") "trigger_digital" else "primary"
                surface.showBindingPresentations(listOf(ProfileBindingPresentations(profile.id,null,listOf(
                    BindingPresentation(id,part,if(index==5) " e " else "⌃⌥⇧⌘Return","Control Option Shift Command Return")))),true)
                root.addView(surface,android.widget.LinearLayout.LayoutParams(800,280))
            }
            root.measure(View.MeasureSpec.makeMeasureSpec(800,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(1680,View.MeasureSpec.EXACTLY));root.layout(0,0,800,1680)
            val bitmap=Bitmap.createBitmap(800,1680,Bitmap.Config.ARGB_8888);root.draw(Canvas(bitmap))
            File(context.getExternalFilesDir(null),"binding-hints-matrix.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()
        }
    }
}
