package com.thumble.android

import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ThumbCalibrationDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private var previousFlags=0
    private val ownedCalibrationKeys=mutableSetOf<ThumbCalibrationKey>()
    @Before fun setup() {
        val info=instrumentation.uiAutomation.serviceInfo;previousFlags=info.flags
        info.flags=info.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        instrumentation.uiAutomation.serviceInfo=info
    }
    @After fun cleanup() {
        val store=ThumbCalibrationStore(File(context.noBackupFilesDir,"thumb-calibration"))
        ownedCalibrationKeys.forEach(store::remove)
        val info=instrumentation.uiAutomation.serviceInfo;info.flags=previousFlags;instrumentation.uiAutomation.serviceInfo=info
    }
    private fun profile(): ControllerProfile {
        val id=UUID.randomUUID()
        val controls=JSONArray().put(JSONObject().put("id",UUID.randomUUID().toString()).put("kind","button").put("label","Calibrate A")
            .put("visualRole","primary_action").put("layout",JSONObject().put("centerX",.85).put("centerY",.1).put("widthScale",.2).put("heightScale",.2)))
            .put(JSONObject().put("id",UUID.randomUUID().toString()).put("kind","button").put("label","Calibrate B")
                .put("layout",JSONObject().put("centerX",.85).put("centerY",.1)))
        return ControllerProfile.parse(JSONObject().put("id",id.toString()).put("name","Thumb acceptance").put("orientationPreference","portrait")
            .put("customization",JSONObject().put("deviceCanvas",JSONObject().put("frameID","iphone-17-pro-portrait"))
                .put("elements",controls).put("colorSchemePreference","system")))
    }
    private fun await(label: String,test: ()->Boolean) {
        val end=SystemClock.elapsedRealtime()+20_000
        while(SystemClock.elapsedRealtime()<end) { if(test()) return;SystemClock.sleep(30) }
        screenshot("failed-"+label.replace(Regex("[^a-zA-Z0-9]+"),"-").take(55));fail(label)
    }
    private fun node(label: String): AccessibilityNodeInfo? {
        fun walk(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if(!n.refresh()) return null
            if(n.isVisibleToUser && (n.text?.toString()==label || n.contentDescription?.toString()==label)) return n
            repeat(n.childCount) { n.getChild(it)?.let { child -> walk(child)?.let { return it } } };return null
        }
        val a=instrumentation.uiAutomation
        return (listOfNotNull(a.rootInActiveWindow)+a.windows.filter { it.isActive || it.isFocused }.mapNotNull { it.root }).firstNotNullOfOrNull { walk(it) }
    }
    private fun click(label: String) {
        var rect: Rect?=null;var previous: Rect?=null;var since=0L
        await("stable $label") {
            node(label)?.takeIf { it.isEnabled }?.let { n ->
                val r=Rect();n.getBoundsInScreen(r)
                if(r!=previous) { previous=Rect(r);since=SystemClock.elapsedRealtime() }
                if(!r.isEmpty && SystemClock.elapsedRealtime()-since>300) { rect=r;true } else false
            } ?: false
        }
        val r=rect!!;val now=SystemClock.uptimeMillis()
        for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP)) {
            val e=MotionEvent.obtain(now,SystemClock.uptimeMillis(),action,r.exactCenterX(),r.exactCenterY(),0)
            e.source=InputDevice.SOURCE_TOUCHSCREEN;assertTrue(instrumentation.uiAutomation.injectInputEvent(e,true));e.recycle()
        }
    }
    private fun scrollTo(label: String) {
        fun scroll(n: AccessibilityNodeInfo): Boolean {
            if(!n.refresh()) return false
            if(n.isVisibleToUser && n.isScrollable && n.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) return true
            repeat(n.childCount) { n.getChild(it)?.let { if(scroll(it)) return true } };return false
        }
        repeat(5) {
            if(node(label)!=null) return
            instrumentation.uiAutomation.rootInActiveWindow?.let(::scroll)
            instrumentation.uiAutomation.waitForIdle(200,2500)
        }
        await("visible $label") { node(label)!=null }
    }
    private fun screenshot(name: String) {
        instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
            File(context.getExternalFilesDir(null),"thumb-calibration-$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()
        }
    }
    private fun session(scenario: ActivityScenario<MainActivity>): ControllerSession {
        var session: ControllerSession?=null
        scenario.onActivity { session=ViewModelProvider(it)[ControllerSession::class.java] };return session!!
    }
    private fun start(scenario: ActivityScenario<MainActivity>,profile: ControllerProfile) {
        scenario.onActivity { it.showSavedKeypad() }
        await("saved keypad") { session(scenario).state.viewingSaved }
        await("controller rendered") { node("Calibrate B")!=null }
        click(profile.name)
        scrollTo("Calibrate thumb reach")
        click("Calibrate thumb reach")
        await("left thumb capture") { node("Calibrate Left Thumb")!=null }
        ownedCalibrationKeys+=session(scenario).thumbCapture!!.calibration.key
    }
    private fun traceLeft(scenario: ActivityScenario<MainActivity>) {
        var location=IntArray(2);var width=0;var height=0
        scenario.onActivity { activity ->
            fun find(view: View): ThumbCaptureSurface? {
                if(view is ThumbCaptureSurface) return view
                if(view is android.view.ViewGroup) repeat(view.childCount) { find(view.getChildAt(it))?.let { return it } }
                return null
            }
            val view=find(activity.window.decorView)!!;view.getLocationOnScreen(location);width=view.width;height=view.height
        }
        val points=ThumbCapture.defaultSamples(ThumbPoint.of(.24,.74))
        val start=SystemClock.uptimeMillis()
        points.forEachIndexed { index,p ->
            val event=MotionEvent.obtain(start,SystemClock.uptimeMillis(),if(index==0) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_MOVE,
                (location[0]+width*p.x).toFloat(),(location[1]+height*p.y).toFloat(),0)
            event.source=InputDevice.SOURCE_TOUCHSCREEN;assertTrue(instrumentation.uiAutomation.injectInputEvent(event,true));event.recycle();SystemClock.sleep(25)
        }
        val p=points.last();val up=MotionEvent.obtain(start,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,(location[0]+width*p.x).toFloat(),(location[1]+height*p.y).toFloat(),0)
        up.source=InputDevice.SOURCE_TOUCHSCREEN;assertTrue(instrumentation.uiAutomation.injectInputEvent(up,true));up.recycle()
    }
    @Test fun visibleTraceAndEstimateScorePersistAndAcceptedRepairCanUndoWithoutChangingPracticeOrIdentity() {
        val original=profile();val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(original),original.id,original.id)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            start(scenario,original);val practiceBefore=store.loadPreferences().practiceMode;screenshot("capture-left")
            traceLeft(scenario);await("right thumb") { node("Calibrate Right Thumb")!=null };screenshot("capture-right")
            click("Use comfortable estimate");await("score saved") { session(scenario).let { it.thumbCapture?.complete==true && !it.thumbBusy && it.thumbError==null } && node("Thumb Placement Score")!=null }
            val record=session(scenario).thumbCapture!!.calibration
            assertEquals(record,ThumbCalibrationStore(File(context.noBackupFilesDir,"thumb-calibration")).load(record.key))
            assertSame(original,store.loadSnapshot().selected);assertTrue(store.loadPendingLayoutEdits().isEmpty());assertEquals(practiceBefore,store.loadPreferences().practiceMode)
            screenshot("score")
            // Small-size repair is visible below the reach repair. Scroll its real panel if needed.
            val label="Apply: Make controls at least 44 dp"
            scrollTo(label)
            click(label)
            await("repair editor") { session(scenario).state.let { it.layoutEditing && !it.layoutCalibrating } && node("Edit layout")!=null }
            assertEquals(original.id,store.loadSnapshot().selectedID);assertEquals(original.id,store.loadSnapshot().defaultID)
            assertEquals(original.controls(false).map { it.id },store.loadSnapshot().selected!!.controls(false).map { it.id })
            assertEquals(1,store.loadPendingLayoutEdits().size);assertEquals(practiceBefore,store.loadPreferences().practiceMode)
            screenshot("accepted-repair-editor")
            click("Undo");await("repair undone") { LayoutSnapshot.resolved(store.loadSnapshot().selected!!,LayoutOrientation.PORTRAIT).samePresentation(LayoutSnapshot.resolved(original,LayoutOrientation.PORTRAIT)) }
            click("Done");await("calibration finished") { !session(scenario).state.layoutEditing }
            assertEquals(practiceBefore,store.loadPreferences().practiceMode);assertEquals(0L,session(scenario).state.webSocketFrames);assertEquals(0L,session(scenario).state.udpFrames)
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun cancelDuringCaptureAndRecreationDiscardDraftWithoutSavingOrChangingTheKeypad() {
        val original=profile();val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(original),original.id,original.id));savePreferences(ClientPreferences(practiceMode=true)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            start(scenario,original)
            val owner=session(scenario);val token=owner.state.layoutEditToken
            scenario.onActivity { owner.updateThumbCapture(token) { it.update(ThumbPoint.of(.2,.8)) } }
            assertEquals(1,owner.thumbCapture!!.draft.size)
            val key=owner.thumbCapture!!.calibration.key
            click("Cancel");await("canceled capture") { !owner.state.layoutEditing }
            assertNull(ThumbCalibrationStore(File(context.noBackupFilesDir,"thumb-calibration")).load(key));assertSame(original,store.loadSnapshot().selected)
            assertTrue(store.loadPreferences().practiceMode);assertTrue(store.loadPendingLayoutEdits().isEmpty())
            start(scenario,original);scenario.recreate()
            await("recreation cancels capture") { !session(scenario).state.layoutEditing }
            assertSame(original,store.loadSnapshot().selected);assertTrue(store.loadPreferences().practiceMode)
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun realMacAcceptsCalibrationRepairAndReplaysItAfterReconnect() {
        val qr=InstrumentationRegistry.getArguments().getString("calibrationPairingQR")
        org.junit.Assume.assumeTrue("Requires private native receiver",qr!=null)
        val target=PairingTarget.parse(qr!!);val memory=MemorySessionStore()
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={memory}
        var originalRecord: ThumbCalibration?=null;var calibrationKey: ThumbCalibrationKey?=null
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.connect(target) }
            await("native paired profile") { session(scenario).state.let { it.paired && it.snapshot.selected!=null } }
            val owner=session(scenario);val original=owner.state.snapshot.selected!!
            val baseline=LayoutSnapshot.resolved(original,LayoutOrientation.PORTRAIT)
            click(original.name);scrollTo("Calibrate thumb reach");click("Calibrate thumb reach")
            await("native calibration entry") { node("Calibrate Left Thumb")!=null }
            calibrationKey=owner.thumbCapture!!.calibration.key
            originalRecord=ThumbCalibrationStore(File(context.noBackupFilesDir,"thumb-calibration")).load(calibrationKey!!)
            click("Use comfortable estimate");await("native right hand") { node("Calibrate Right Thumb")!=null }
            click("Use comfortable estimate");await("native report saved") { owner.thumbCapture?.complete==true && !owner.thumbBusy && owner.thumbError==null }
            screenshot("native-score")
            val suggestion="Apply: Separate overlapping touch targets";scrollTo(suggestion);click(suggestion)
            await("native repair acknowledged") {
                owner.state.let { it.paired && it.layoutEditing && !it.layoutCalibrating && it.pendingLayoutChanges==0 &&
                    !LayoutSnapshot.resolved(it.snapshot.selected!!,LayoutOrientation.PORTRAIT).samePresentation(baseline) }
            }
            val committed=LayoutSnapshot.resolved(owner.state.snapshot.selected!!,LayoutOrientation.PORTRAIT)
            assertEquals(original.id,owner.state.snapshot.selectedID);assertEquals(original.id,owner.state.snapshot.defaultID)
            assertTrue(memory.loadPendingLayoutEdits().isEmpty());assertEquals(target.serverID,memory.loadMac()?.serverID)
            File(context.getExternalFilesDir(null),"thumb-calibration-native-profile.json").writeText(owner.state.snapshot.selected!!.source.toString())
            screenshot("native-acknowledged")
            owner.client.finishLayoutEditing();owner.client.disconnect();await("native disconnected") { !owner.state.paired }
            owner.client.reconnect();await("native trusted reconnect") { owner.state.paired && committed.samePresentation(LayoutSnapshot.resolved(owner.state.snapshot.selected!!,LayoutOrientation.PORTRAIT)) }
            assertTrue(memory.loadPendingLayoutEdits().isEmpty());assertEquals(target.serverID,memory.loadMac()?.serverID)
            screenshot("native-reconnected");owner.client.disconnect()
        } } finally {
            ClientDependencies.sessionStore=previous
            calibrationKey?.let { key ->
                val store=ThumbCalibrationStore(File(context.noBackupFilesDir,"thumb-calibration"))
                originalRecord?.let(store::save) ?: store.remove(key)
            }
        }
    }
    @Test fun failedLayoutSaveKeepsTheOriginalProfileAndPendingJournal() {
        val original=profile();val memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(original),original.id,original.id)) }
        val failing=object: SessionStore by memory {
            override fun saveEditingState(snapshot: ProfileSnapshot,skins: List<PendingSkinSelection>,appearance: List<PendingAppearancePreference>,layouts: List<PendingLayoutEdit>) {
                throw java.io.IOException("fixture local layout failure")
            }
        }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={failing}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            start(scenario,original);click("Use comfortable estimate");await("failure right hand") { node("Calibrate Right Thumb")!=null }
            click("Use comfortable estimate");await("failure report saved") { session(scenario).let { it.thumbCapture?.complete==true && !it.thumbBusy && it.thumbError==null } }
            val label="Apply: Make controls at least 44 dp";scrollTo(label);click(label)
            await("failed repair remains in calibration") { session(scenario).let { !it.thumbBusy && it.state.layoutCalibrating && it.state.error?.contains("Could not save this layout edit")==true } }
            assertSame(original,memory.loadSnapshot().selected);assertTrue(memory.loadPendingLayoutEdits().isEmpty());screenshot("save-failed")
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun calibrationReleasesHeldInputSuppressesNewFramesAndRestoresThePriorPracticeChoice() {
        val original=profile();val server=okhttp3.mockwebserver.MockWebServer()
        val wire=java.util.concurrent.CopyOnWriteArrayList<ByteArray>()
        server.enqueue(okhttp3.mockwebserver.MockResponse().withWebSocketUpgrade(object: okhttp3.WebSocketListener() {
            override fun onMessage(socket: okhttp3.WebSocket,bytes: okio.ByteString) { wire.add(bytes.toByteArray()) }
            override fun onMessage(socket: okhttp3.WebSocket,text: String) {
                val value=JSONObject(text)
                if(value.optString("type")=="hello") socket.send(WireCodec.message("pairing_accepted").put("inputProtocolVersion",3)
                    .put("serverID","calibration-fixture").put("authToken","fixture-only")
                    .put("gamepadProfiles",JSONArray().put(original.source)).put("gamepadProfileID",original.id.toString())
                    .put("capabilities",JSONArray().put(ProfileActions.ORIENTATION_CAPABILITY)).toString())
                else wire.add(text.toByteArray())
            }
        }))
        server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val memory=MemorySessionStore();val state=java.util.concurrent.atomic.AtomicReference(ClientState())
        val client=ControllerClient(memory) { state.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"));await("live paired") { state.get().paired }
            val control=original.controls(false).first().id
            val previousRevision=state.get().surfaceRevision
            client.edge(control,true,1,previousRevision);await("held edge") { wire.any { it.size==56 } }
            val before=wire.size
            client.beginLayoutEditing(original.id,LayoutOrientation.PORTRAIT,true)
            await("calibration releases held input") { state.get().layoutCalibrating && wire.drop(before).any { bytes ->
                runCatching { JSONObject(bytes.toString(Charsets.UTF_8)).optString("type")=="release_all" }.getOrDefault(false)
            } }
            fun inputFrames()=wire.count { bytes -> bytes.size==56 || runCatching {
                JSONObject(bytes.toString(Charsets.UTF_8)).optString("type") !in setOf("heartbeat","release_all")
            }.getOrDefault(true) }
            val inputCount=inputFrames()
            client.edge(control,true,2,previousRevision);client.edge(control,true,3,state.get().surfaceRevision)
            client.stick("left",1.0,1.0,true,state.get().surfaceRevision);client.pointer("move",1.0,1.0,null,null,state.get().surfaceRevision)
            SystemClock.sleep(400);assertEquals(inputCount,inputFrames());assertFalse(memory.loadPreferences().practiceMode)
            client.finishLayoutEditing();await("calibration done") { !state.get().layoutEditing }
            client.edge(control,true,4,state.get().surfaceRevision);await("input resumes") { inputFrames()>inputCount }
            client.releaseAll();client.setPracticeMode(true);await("practice chosen") { state.get().practiceMode }
            client.beginLayoutEditing(original.id,LayoutOrientation.PORTRAIT,true);await("practice calibration") { state.get().layoutCalibrating }
            client.finishLayoutEditing();await("practice preserved") { !state.get().layoutEditing && state.get().practiceMode }
            assertTrue(memory.loadPreferences().practiceMode)
        } finally { client.dispose();server.shutdown() }
    }
    @Test fun privateStoreScopesByDeviceDisplayProfileAndOrientationAndRejectsCorruption() {
        val directory=File(context.cacheDir,"thumb-test-${UUID.randomUUID()}")
        val key=ThumbCalibrationKey(UUID.randomUUID(),"device","400x800@160",LayoutOrientation.PORTRAIT)
        val value=ThumbCalibration(key).recording(ThumbHand.LEFT,ThumbCapture.defaultSamples(ThumbPoint.of(.2,.7)),123)
        try {
            ThumbCalibrationStore(directory).save(value)
            val reloaded=ThumbCalibrationStore(directory);assertEquals(value,reloaded.load(key))
            assertNull(reloaded.load(key.copy(device="other")));assertNull(reloaded.load(key.copy(display="other")))
            assertNull(reloaded.load(key.copy(profileID=UUID.randomUUID())));assertNull(reloaded.load(key.copy(orientation=LayoutOrientation.LANDSCAPE)))
            val base=directory.listFiles()!!.single()
            // AtomicFile must recover a previous value even if an interrupted write lost its base.
            base.copyTo(File(base.path+".bak"));base.delete()
            assertEquals(value,reloaded.load(key))
            base.writeText("broken")
            assertTrue(runCatching { reloaded.load(key) }.isFailure)
            reloaded.save(value);assertEquals(value,reloaded.load(key))
        } finally { directory.deleteRecursively() }
    }
    @Test fun surfaceCancelAdditionalFingerAndResizeNeverCommitAndAccessibleClickUsesEstimate() {
        instrumentation.runOnMainSync {
            var capture=ThumbCapture(ThumbCalibration(ThumbCalibrationKey(UUID.randomUUID(),"device","surface",LayoutOrientation.PORTRAIT)),ThumbHand.entries)
            val view=ThumbCaptureSurface(context).apply {
                onPoint={ x,y,final -> capture=if(final) capture.finish(ThumbPoint.of(x,y),1) else capture.update(ThumbPoint.of(x,y)) }
                onCancel={ capture=capture.cancelDraft() };onEstimate={ capture=capture.estimate(1) }
            }
            view.layout(0,0,400,800)
            fun event(action: Int) { val e=MotionEvent.obtain(1,2,action,80f,600f,0);view.onTouchEvent(e);e.recycle() }
            event(MotionEvent.ACTION_DOWN);assertEquals(1,capture.draft.size)
            event(MotionEvent.ACTION_CANCEL);event(MotionEvent.ACTION_UP);assertTrue(capture.calibration.left.isEmpty());assertTrue(capture.draft.isEmpty())
            event(MotionEvent.ACTION_DOWN);event(MotionEvent.ACTION_POINTER_DOWN);event(MotionEvent.ACTION_UP);assertTrue(capture.calibration.left.isEmpty())
            event(MotionEvent.ACTION_DOWN);view.onWindowFocusChanged(false);event(MotionEvent.ACTION_UP);assertTrue(capture.calibration.left.isEmpty())
            event(MotionEvent.ACTION_DOWN);view.layout(0,0,800,400);event(MotionEvent.ACTION_UP);assertTrue(capture.calibration.left.isEmpty())
            view.performClick();assertEquals(ThumbHand.RIGHT,capture.activeHand);assertEquals(17,capture.calibration.left.size)
            view.enabledCapture=false;view.performClick();assertFalse(capture.complete)
        }
    }
}
