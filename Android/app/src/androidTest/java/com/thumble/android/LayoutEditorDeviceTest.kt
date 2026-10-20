package com.thumble.android

import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.Before
import org.junit.After
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(AndroidJUnit4::class)
class LayoutEditorDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private var originalServiceFlags=0
    @Before fun observeInteractiveWindows() {
        val info=instrumentation.uiAutomation.serviceInfo
        originalServiceFlags=info.flags
        info.flags=info.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        instrumentation.uiAutomation.serviceInfo=info
    }
    @After fun restoreServiceFlags() {
        val info=instrumentation.uiAutomation.serviceInfo;info.flags=originalServiceFlags
        instrumentation.uiAutomation.serviceInfo=info
    }
    private fun original(): ControllerProfile {
        val raw=JSONObject().put("id","00000000-0000-0000-0000-000000000301").put("name","Editor acceptance")
        val elements=JSONArray()
        for ((suffix,label,x) in listOf(Triple("302","Alpha",.25),Triple("303","Beta",.75))) elements.put(JSONObject()
            .put("id","00000000-0000-0000-0000-000000000$suffix").put("label",label).put("kind","button")
            .put("layout",JSONObject().put("centerX",x).put("centerY",.4).put("widthScale",1.0).put("heightScale",1.0)))
        raw.put("customization",JSONObject().put("deviceCanvas",JSONObject().put("frameID","iphone-17-pro-portrait"))
            .put("colorSchemePreference","system").put("elements",elements))
        return ControllerProfile.parse(raw)
    }
    private fun await(message: String, predicate: ()->Boolean) {
        val deadline=SystemClock.elapsedRealtime()+12_000
        while(!predicate() && SystemClock.elapsedRealtime()<deadline) SystemClock.sleep(25)
        assertTrue(message,predicate())
    }
    private fun node(label: String): AccessibilityNodeInfo? {
        fun find(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if(n.text?.toString()==label || n.contentDescription?.toString()==label) return n
            for(i in 0 until n.childCount) n.getChild(i)?.let { find(it)?.let { found -> return found } }
            return null
        }
        val automation=instrumentation.uiAutomation
        val root=automation.rootInActiveWindow ?: automation.windows.firstOrNull { it.isActive || it.isFocused }?.root
        root?.refresh()
        return root?.let(::find)
    }
    private fun click(label: String) {
        await("enabled $label") { actionNode(label)?.let { it.isClickable && it.isEnabled }==true }
        val target=actionNode(label)!!
        val bounds=Rect();target.getBoundsInScreen(bounds)
        val now=SystemClock.uptimeMillis()
        for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP)) {
            val event=MotionEvent.obtain(now,SystemClock.uptimeMillis(),action,bounds.exactCenterX(),bounds.exactCenterY(),0)
            event.source=InputDevice.SOURCE_TOUCHSCREEN
            assertTrue("tap $label",instrumentation.uiAutomation.injectInputEvent(event,true));event.recycle()
        }
        instrumentation.uiAutomation.waitForIdle(150,3_000)
    }
    private fun actionNode(label: String): AccessibilityNodeInfo? {
        var target=node(label) ?: return null
        while(!target.isClickable && target.parent!=null) target=target.parent
        return target
    }
    private fun capture(name: String) {
        instrumentation.uiAutomation.waitForIdle(150,3_000)
        SystemClock.sleep(250) // Let the platform dialog's presentation frames settle.
        val bitmap=instrumentation.uiAutomation.takeScreenshot()!!
        File(instrumentation.targetContext.getExternalFilesDir(null),"layout-editor-$name.png").outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it)
        };bitmap.recycle()
    }
    private fun drag(label: String,dx: Float,dy: Float) {
        // A native reply can replace the skin projection after the journal clears.
        // Refresh the node so cached pre-Undo bounds/readiness cannot start a drag.
        await("enabled gesture target") { node(label)?.let { it.refresh() && it.isEnabled }==true }
        val target=node(label)!!;assertTrue(target.refresh())
        val rect=Rect();target.getBoundsInScreen(rect)
        dragFrom(rect.exactCenterX(),rect.exactCenterY(),dx,dy)
    }
    private fun dragFrom(x: Float,y: Float,dx: Float,dy: Float) {
        val start=SystemClock.uptimeMillis()
        for(i in 0..10) {
            val action=when(i) { 0 -> MotionEvent.ACTION_DOWN;10 -> MotionEvent.ACTION_UP;else -> MotionEvent.ACTION_MOVE }
            val event=MotionEvent.obtain(start,SystemClock.uptimeMillis(),action,x+dx*i/10,y+dy*i/10,0)
            event.source=InputDevice.SOURCE_TOUCHSCREEN
            assertTrue(instrumentation.uiAutomation.injectInputEvent(event,true));event.recycle();SystemClock.sleep(32)
        }
    }
    private fun layout(store: SessionStore)=store.loadSnapshot().selected!!.source.getJSONObject("customization")
    private fun element(store: SessionStore)=layout(store).getJSONArray("elements").getJSONObject(0).getJSONObject("layout")
    private fun embeddedData(value: Any?): Set<String> = when(value) {
        is JSONObject -> value.keys().asSequence().flatMap { key ->
            val child=value.get(key)
            if(key=="data" && child is String) sequenceOf(child) else embeddedData(child).asSequence()
        }.toSet()
        is JSONArray -> (0 until value.length()).flatMap { embeddedData(value.get(it)) }.toSet()
        else -> emptySet()
    }
    /** Private receiver fixture supplied by verify-mac-layout-edits.py --editor-ui. */
    @Test fun realMacEditorSyncsUndoCancelAndOfflineGeometry() {
        val args=InstrumentationRegistry.getArguments()
        val qr=args.getString("layoutEditorPairingQR")
        org.junit.Assume.assumeTrue("Requires private real Mac receiver",qr!=null)
        val target=PairingTarget.parse(qr!!)
        val store=MemorySessionStore()
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.connect(target) }
            await("real profiles paired") { store.loadSnapshot().profiles.isNotEmpty() && store.loadMac()!=null }
            val initial=store.loadSnapshot().selected!!
            val skinReference=args.getString("layoutEditorSkinReference")?.takeIf { it.isNotEmpty() && it!="none" }
            val assetData=if(skinReference!=null) {
                val requested=SkinReference.parse(initial.source.getJSONObject("skinReference"))
                assertEquals(skinReference,requested.identifier+"@"+requested.version)
                val library=SkinLibrary(File(instrumentation.targetContext.filesDir,"skins"))
                await("authenticated archive installed") { runCatching { library.packageFor(requested) }.isSuccess }
                val pkg=library.packageFor(requested)
                pkg.assetIDs.mapNotNull { pkg.asset(it)?.takeIf { bytes -> bytes.isNotEmpty() }?.let { bytes -> java.util.Base64.getEncoder().encodeToString(bytes) } }
            } else emptyList()
            if(skinReference!=null) assertTrue("fixture must contain real artwork",assetData.isNotEmpty())
            val custom=args.getString("layoutEditorCustomControl")=="true"
            val control=initial.controls(false).first { it.kind=="button" && !it.style.optBoolean("isLocationLocked") && (!custom || !it.isBuiltin) }
            val label="Edit ${control.accessibilityName}"
            val entry=LayoutSnapshot.resolved(initial,LayoutOrientation.PORTRAIT).oriented(LayoutOrientation.PORTRAIT)
            fun savedLayout()=LayoutSnapshot.resolved(store.loadSnapshot().selected!!,LayoutOrientation.PORTRAIT)
            fun acknowledged()=store.loadPendingLayoutEdits().isEmpty()
            fun assertCanonical() {
                val data=embeddedData(store.loadSnapshot().selected!!.source)
                assertTrue("hydrated artwork must stay out of saved profiles",assetData.none { it in data })
                val pending=store.loadPendingLayoutEdits().flatMap { embeddedData(it.customization.json()) }.toSet()
                assertTrue("hydrated artwork must stay out of pending edits",assetData.none { it in pending })
            }
            await("keypad ready") { node(initial.name)!=null && node("Loading keypad appearance…")==null }
            click(initial.name);click("Edit layout")
            await("real editor") { node(label)?.isEnabled==true };capture("live-entry")
            if(assetData.isNotEmpty()) {
                val session=java.util.concurrent.atomic.AtomicReference<ControllerSession>()
                scenario.onActivity { session.set(androidx.lifecycle.ViewModelProvider(it)[ControllerSession::class.java]) }
                val projected=embeddedData(session.get().skinRenderer.resolve(store.loadSnapshot().selected,false,false).profile!!.layout(false))
                assertTrue("display projection must hydrate installed package artwork",assetData.any { it in projected })
            }
            fun awaitEdit(description: String,predicate: ()->Boolean) {
                try { await(description,predicate) }
                catch(error: AssertionError) {
                    val diagnostic=JSONObject().put("phase",description).put("pending",store.loadPendingLayoutEdits().size)
                        .put("sameAsEntry",savedLayout().samePresentation(entry))
                    scenario.onActivity { diagnostic.put("editing",it.connectionState.layoutEditing).put("paired",it.connectionState.paired)
                        .put("error",it.connectionState.error ?: JSONObject.NULL) }
                    val folder=instrumentation.targetContext.getExternalFilesDir(null)!!
                    File(folder,"layout-editor-live-diagnostic.json").writeText(diagnostic.toString())
                    File(folder,"layout-editor-android-saved-layout.json").writeText(savedLayout().json().toString())
                    store.loadPendingLayoutEdits().firstOrNull()?.let {
                        File(folder,"layout-editor-android-pending-layout.json").writeText(it.customization.json().toString())
                    }
                    capture("live-failure");throw error
                }
            }
            drag(label,60f,35f)
            awaitEdit("Mac acknowledges visible move") { !savedLayout().samePresentation(entry) && acknowledged() }
            assertCanonical();capture("live-synced")
            click("Undo")
            awaitEdit("Mac acknowledges Undo") { savedLayout().samePresentation(entry) && acknowledged() }
            fun controlAction(name: String) {
                awaitEdit("ready accessibility action $name") { node(label)?.let { it.refresh() && it.isEnabled && it.actionList.any { action -> action.label?.toString()==name } }==true }
                val target=node(label)!!;assertTrue(target.refresh())
                val action=target.actionList.first { it.label?.toString()==name }
                assertTrue("perform $name",target.performAction(action.id))
            }
            for ((action,description) in listOf("Rotate clockwise" to "rotation","Enlarge" to "resize")) {
                controlAction(action)
                awaitEdit("Mac acknowledges $description") { !savedLayout().samePresentation(entry) && acknowledged() }
                assertCanonical();click("Undo")
                awaitEdit("Mac acknowledges $description Undo") { savedLayout().samePresentation(entry) && acknowledged() }
            }
            controlAction("Delete ${control.accessibilityName}");click("Confirm deletion")
            awaitEdit("Mac acknowledges deletion") { store.loadSnapshot().selected!!.controls(false).none { it.id==control.id } && acknowledged() }
            assertCanonical();capture("live-deleted")
            click("Undo")
            awaitEdit("Mac acknowledges deletion Undo") { savedLayout().samePresentation(entry) && acknowledged() }
            drag(label,60f,35f)
            awaitEdit("second move acknowledged") { !savedLayout().samePresentation(entry) && acknowledged() }
            click("Cancel")
            awaitEdit("Cancel restores authority") { node(initial.name)!=null && savedLayout().samePresentation(entry) && acknowledged() }
            click("Disconnect");click("Practice with saved keypad")
            click(initial.name);click("Edit layout");drag(label,60f,35f)
            awaitEdit("offline gesture durable") { store.loadPendingLayoutEdits().size==1 && !savedLayout().samePresentation(entry) }
            val offline=savedLayout();assertCanonical();capture("live-offline")
            click("Done");click("Connection");click("Reconnect to saved Mac")
            awaitEdit("trusted reconnect acknowledges offline UI edit") { node("Disconnect")!=null && acknowledged() && savedLayout().samePresentation(offline) }
            assertCanonical();capture("live-reconnected")
            scenario.onActivity { activity ->
                assertTrue(activity.connectionState.paired);assertFalse(activity.connectionState.layoutEditing)
                assertEquals(initial.id,activity.connectionState.snapshot.selectedID)
                assertEquals(initial.id,activity.connectionState.snapshot.defaultID)
                androidx.lifecycle.ViewModelProvider(activity)[ControllerSession::class.java].client.disconnect()
            }
            awaitEdit("private receiver disconnected") { node("Reconnect to saved Mac")!=null }
            scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun visibleEditorPersistsGesturesUndoDeletionCancelAndDone() {
        val p=original();val memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id,p.id)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={ memory }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() }
            click(p.name);click("Edit layout")
            await("editor") { node("Edit Alpha")!=null };capture("entry")
            drag("Edit Alpha",60f,45f)
            await("gesture saved") { element(memory).optDouble("centerX")>.25 }
            val moved=element(memory).getDouble("centerX");capture("moved")
            click("Undo");await("undo saved") { element(memory).getDouble("centerX")==.25 }
            await("no extra preview history") { actionNode("Undo")?.isEnabled==false }
            await("rotation action ready") { node("Edit Alpha")?.actionList?.any { it.label?.toString()=="Rotate clockwise" }==true }
            val action=node("Edit Alpha")!!.actionList.first { it.label?.toString()=="Rotate clockwise" }
            assertTrue(node("Edit Alpha")!!.performAction(action.id))
            await("rotation saved") { element(memory).optDouble("rotationDegrees")==15.0 };capture("rotated")
            val delete=node("Edit Alpha")!!.actionList.first { it.label?.toString()=="Delete Alpha" }
            assertTrue(node("Edit Alpha")!!.performAction(delete.id))
            await("delete confirmation") { node("Delete element?")!=null };capture("delete-confirmation")
            click("Cancel deletion");assertEquals(2,layout(memory).getJSONArray("elements").length())
            capture("after-delete-cancel")
            await("canvas restored after confirmation") { node("Edit Alpha")!=null }
            assertTrue(node("Edit Alpha")!!.performAction(delete.id));click("Confirm deletion")
            await("custom element removed") { layout(memory).getJSONArray("elements").length()==1 }
            click("Undo");await("delete undone") { layout(memory).getJSONArray("elements").length()==2 }
            click("Cancel");await("editing exited") { node("Edit layout")==null && node(p.name)!=null }
            val orientation=LayoutOrientation.of(layout(memory))
            assertTrue(LayoutSnapshot.capture(layout(memory)).samePresentation(LayoutSnapshot.resolved(p,orientation).oriented(orientation)))
            click(p.name);click("Edit layout");await("second editor") { node("Edit Alpha")!=null }
            drag("Edit Alpha",60f,45f);await("second move saved") { element(memory).getDouble("centerX")>.25 }
            click("Done");await("done returns to keypad") { node(p.name)!=null }
            assertEquals(moved,element(memory).getDouble("centerX"),.00001)
            scenario.onActivity { activity ->
                assertFalse(activity.connectionState.layoutEditing);assertFalse(activity.connectionState.paired)
                assertEquals(0L,activity.connectionState.webSocketFrames);assertEquals(0L,activity.connectionState.udpFrames)
            }
            capture("done");scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun failedSaveKeepsUndoAndSavedLayoutAndCancelCanRetry() {
        val p=original();val memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id,p.id)) }
        val fail=AtomicBoolean(false)
        val store=object: SessionStore by memory {
            override fun saveEditingState(snapshot: ProfileSnapshot,skins: List<PendingSkinSelection>,appearance: List<PendingAppearancePreference>,layouts: List<PendingLayoutEdit>) {
                if(fail.get()) throw java.io.IOException("Fixture disk failure")
                memory.saveEditingState(snapshot,skins,appearance,layouts)
            }
        }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() };click(p.name);click("Edit layout")
            await("editor") { node("Edit Alpha")!=null }
            fail.set(true);drag("Edit Alpha",60f,45f)
            await("failure feedback") { node("Could not save this layout edit. Your saved keypad is unchanged.")!=null }
            assertEquals(.25,element(memory).getDouble("centerX"),.00001)
            await("failed save has no undo entry") { actionNode("Undo")?.isEnabled==false };capture("save-failed")
            fail.set(false);drag("Edit Alpha",60f,45f);await("retry saved") { element(memory).getDouble("centerX")>.25 }
            fail.set(true);click("Cancel")
            await("cancel failure keeps editor") { node("Could not save this layout edit. Your saved keypad is unchanged.")!=null && node("Edit Alpha")!=null }
            assertTrue(element(memory).getDouble("centerX")>.25)
            fail.set(false);click("Cancel");await("cancel retry exits") { node(p.name)!=null }
            assertEquals(.25,element(memory).getDouble("centerX"),.00001)
            scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun visibleResizeAndRotationHandlesCommitOneUndoEach() {
        val p=original();val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id,p.id)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() };click(p.name);click("Edit layout")
            await("canvas") { node("Edit Alpha")!=null };click("Edit Alpha")
            val before=Rect();node("Edit Alpha")!!.getBoundsInScreen(before)
            dragFrom(before.right.toFloat(),before.bottom.toFloat(),60f,45f)
            await("resize stored") { element(store).optDouble("widthScale")>1.0 && element(store).optDouble("heightScale")>1.0 }
            await("resize projection") { node("Edit Alpha")?.let { val r=Rect();it.getBoundsInScreen(r);r.width()>before.width() }==true }
            capture("resized")
            val resized=Rect();node("Edit Alpha")!!.getBoundsInScreen(resized)
            val d=instrumentation.targetContext.resources.displayMetrics.density
            val x=resized.right+26*d;val y=resized.top-26*d
            val dx=x-resized.exactCenterX();val dy=y-resized.exactCenterY()
            val angle=Math.PI/3
            val targetX=resized.exactCenterX()+dx*kotlin.math.cos(angle)-dy*kotlin.math.sin(angle)
            val targetY=resized.exactCenterY()+dx*kotlin.math.sin(angle)+dy*kotlin.math.cos(angle)
            dragFrom(x,y,(targetX-x).toFloat(),(targetY-y).toFloat())
            await("rotation stored") { element(store).optDouble("rotationDegrees") in 55.0..65.0 }
            capture("rotation-handle")
            click("Undo");await("rotation undo") { kotlin.math.abs(element(store).optDouble("rotationDegrees",0.0))<.01 }
            assertTrue(element(store).getDouble("widthScale")>1)
            click("Undo");await("resize undo") { element(store).getDouble("widthScale")==1.0 }
            await("exactly two history entries") { actionNode("Undo")?.isEnabled==false }
            click("Done");scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun hardwareBackCanKeepOrRestoreChangesAndExitsAnUnchangedEditor() {
        val p=original();val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id,p.id)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        fun back() {
            await("editor ready for Back") { actionNode("Done")?.isEnabled==true }
            instrumentation.sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() };click(p.name);click("Edit layout")
            await("editor") { node("Edit Alpha")!=null };drag("Edit Alpha",60f,45f)
            await("move stored") { element(store).getDouble("centerX")>.25 }
            val saved=element(store).getDouble("centerX")
            back();click("Keep changes");await("keep returns to keypad") { node(p.name)!=null }
            assertEquals(saved,element(store).getDouble("centerX"),.00001)
            click(p.name);click("Edit layout");await("second editor") { node("Edit Alpha")!=null }
            drag("Edit Alpha",60f,45f);await("second move") { element(store).getDouble("centerX")>saved }
            back();await("exit confirmation") { node("Finish editing?")!=null };capture("back-confirmation")
            click("Restore starting layout");await("restore returns to keypad") { node(p.name)!=null }
            assertEquals(saved,element(store).getDouble("centerX"),.00001)
            click(p.name);click("Edit layout");await("unchanged editor") { node("Edit Alpha")!=null }
            back();await("unchanged editor exits directly") { node(p.name)!=null }
            assertNull(node("Finish editing?"));scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun interruptedOverlayGesturesDiscardPreviewsAndCannotCommitFromRetiredTouches() {
        val memory=MemorySessionStore()
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={memory}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            for(reason in listOf("focus", "resize", "detach", "cancel", "missing-pointer")) {
                scenario.onActivity { activity ->
                    val root=android.widget.FrameLayout(activity)
                    val surface=LayoutEditorSurface(activity)
                    activity.setContentView(root)
                    root.addView(surface,android.widget.FrameLayout.LayoutParams(800,1000))
                    root.measure(android.view.View.MeasureSpec.makeMeasureSpec(800,android.view.View.MeasureSpec.EXACTLY),
                        android.view.View.MeasureSpec.makeMeasureSpec(1000,android.view.View.MeasureSpec.EXACTLY))
                    root.layout(0,0,800,1000)
                    surface.show(original(),false,false,true,android.graphics.Color.BLUE,android.graphics.Color.WHITE)
                    surface.measure(android.view.View.MeasureSpec.makeMeasureSpec(800,android.view.View.MeasureSpec.EXACTLY),
                        android.view.View.MeasureSpec.makeMeasureSpec(1000,android.view.View.MeasureSpec.EXACTLY))
                    surface.layout(0,0,800,1000)
                    val calls=mutableListOf<Pair<LayoutControlPatch?,Boolean>>()
                    surface.onPatch={patch,final -> calls += patch to final}
                    val overlay=surface.getChildAt(1) as android.view.ViewGroup
                    val child=overlay.getChildAt(0)
                    val x=child.left+child.width/2f;val y=child.top+child.height/2f
                    val start=SystemClock.uptimeMillis()
                    fun touch(action: Int,xPos: Float=x,yPos: Float=y,id: Int=7) {
                        val properties=arrayOf(MotionEvent.PointerProperties().apply { this.id=id;toolType=MotionEvent.TOOL_TYPE_FINGER })
                        val coords=arrayOf(MotionEvent.PointerCoords().apply { this.x=xPos;this.y=yPos;pressure=1f;size=1f })
                        val e=MotionEvent.obtain(start,SystemClock.uptimeMillis(),action,1,properties,coords,0,0,1f,1f,0,0,InputDevice.SOURCE_TOUCHSCREEN,0)
                        if(reason=="missing-pointer" && id==9) overlay.dispatchTouchEvent(e) else surface.dispatchTouchEvent(e)
                        e.recycle()
                    }
                    touch(MotionEvent.ACTION_DOWN);touch(MotionEvent.ACTION_MOVE,x+50,y+25)
                    assertTrue("$reason has a live preview",calls.any { it.first!=null && !it.second })
                    assertFalse("$reason has not committed",calls.any { it.second })
                    when(reason) {
                        "focus" -> surface.dispatchWindowFocusChanged(false)
                        "resize" -> {
                            surface.measure(android.view.View.MeasureSpec.makeMeasureSpec(850,android.view.View.MeasureSpec.EXACTLY),
                                android.view.View.MeasureSpec.makeMeasureSpec(1050,android.view.View.MeasureSpec.EXACTLY))
                            surface.layout(0,0,850,1050)
                        }
                        "detach" -> root.removeView(surface)
                        "cancel" -> touch(MotionEvent.ACTION_CANCEL,x+50,y+25)
                        else -> touch(MotionEvent.ACTION_MOVE,x+50,y+25,id=9)
                    }
                    assertEquals("$reason rolls back the preview",null to false,calls.last())
                    val cancelledCount=calls.size
                    touch(MotionEvent.ACTION_MOVE,x+60,y+30);touch(MotionEvent.ACTION_UP,x+60,y+30)
                    assertEquals("$reason ignores retired finger events",cancelledCount,calls.size)
                    if(reason=="detach") root.addView(surface,android.widget.FrameLayout.LayoutParams(800,1000))
                    surface.dispatchWindowFocusChanged(true)
                    touch(MotionEvent.ACTION_DOWN);touch(MotionEvent.ACTION_MOVE,x+30,y+20);touch(MotionEvent.ACTION_UP,x+30,y+20)
                    assertEquals("$reason permits one fresh commit",1,calls.count { it.second })
                }
            }
            scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
    @Test fun backgroundAndRotationKeepCompletedEditsAndDiscardAnUnfinishedDrag() {
        val p=original();val memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id,p.id)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={memory}
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() }
            click(p.name);click("Edit layout");await("editor ready") { node("Edit Alpha")?.isEnabled==true }
            drag("Edit Alpha",45f,25f);await("completed edit saved") { element(memory).getDouble("centerX")>.25 }
            val saved=LayoutSnapshot.capture(layout(memory));val pending=memory.loadPendingLayoutEdits()
            var activityID=0
            scenario.onActivity { activityID=System.identityHashCode(it) }
            fun unfinishedDrag(): Pair<Long,Rect> {
                await("fresh editor control") { node("Edit Alpha")?.let { it.refresh() && it.isEnabled }==true }
                val bounds=Rect();node("Edit Alpha")!!.getBoundsInScreen(bounds)
                val start=SystemClock.uptimeMillis()
                for((action,delta) in listOf(MotionEvent.ACTION_DOWN to 0f,MotionEvent.ACTION_MOVE to 50f)) {
                    val e=MotionEvent.obtain(start,SystemClock.uptimeMillis(),action,bounds.exactCenterX()+delta,bounds.exactCenterY()+delta/2,0)
                    e.source=InputDevice.SOURCE_TOUCHSCREEN
                    assertTrue(instrumentation.uiAutomation.injectInputEvent(e,true));e.recycle();SystemClock.sleep(50)
                }
                assertTrue("unfinished preview is not durable",LayoutSnapshot.capture(layout(memory)).samePresentation(saved))
                return start to bounds
            }
            val (start,bounds)=unfinishedDrag()
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
            await("Home really backgrounds activity") { scenario.state==androidx.lifecycle.Lifecycle.State.CREATED }
            val up=MotionEvent.obtain(start,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,bounds.exactCenterX()+50,bounds.exactCenterY()+25,0)
            up.source=InputDevice.SOURCE_TOUCHSCREEN;instrumentation.uiAutomation.injectInputEvent(up,true);up.recycle()
            // Resume the actual task from outside the instrumented app. An in-app
            // start is intercepted by ActivityScenario's monitor after global Home.
            instrumentation.uiAutomation.executeShellCommand(
                "am start -W -n com.thumble.android/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10020000"
            ).use { descriptor -> java.io.FileInputStream(descriptor.fileDescriptor).use { it.readBytes() } }
            await("activity really resumes") { scenario.state==androidx.lifecycle.Lifecycle.State.RESUMED }
            capture("interruption-foreground")
            try { await("foreground returns to keypad") { node(p.name)!=null && node("Edit Alpha")==null } }
            catch(failure: AssertionError) {
                scenario.onActivity { activity ->
                    throw AssertionError("Foreground state: editing=${activity.connectionState.layoutEditing}, saved=${activity.connectionState.viewingSaved}, profile=${activity.connectionState.snapshot.selected?.name}",failure)
                }
            }
            assertTrue("background preserves completed edit only",LayoutSnapshot.capture(layout(memory)).samePresentation(saved))
            assertEquals("background preserves journal",pending,memory.loadPendingLayoutEdits())
            capture("interruption-resumed")
            click(p.name);click("Edit layout");unfinishedDrag()
            scenario.onActivity { it.requestedOrientation=android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            await("real landscape rotation exits editing") {
                var ready=false
                scenario.onActivity { ready=it.resources.configuration.orientation==android.content.res.Configuration.ORIENTATION_LANDSCAPE && !it.connectionState.layoutEditing }
                ready && node(p.name)!=null
            }
            assertTrue("rotation discards unfinished preview",LayoutSnapshot.capture(layout(memory)).samePresentation(saved))
            assertEquals(pending,memory.loadPendingLayoutEdits())
            capture("interruption-rotated")
            scenario.onActivity {
                assertEquals("rotation retains activity owner",activityID,System.identityHashCode(it))
                assertEquals(0L,it.connectionState.webSocketFrames);assertEquals(0L,it.connectionState.udpFrames)
                it.requestedOrientation=android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            await("portrait returns") { var portrait=false;scenario.onActivity { portrait=it.resources.configuration.orientation==android.content.res.Configuration.ORIENTATION_PORTRAIT };portrait }
            // The old gesture must not leak into a new edit session or its Undo history.
            click(p.name);click("Edit layout");await("new session") { node("Edit Alpha")?.isEnabled==true }
            await("new session has no stale history") { actionNode("Undo")?.isEnabled==false }
            drag("Edit Alpha",30f,15f);await("fresh gesture saves") { !LayoutSnapshot.capture(layout(memory)).samePresentation(saved) }
            click("Undo");await("fresh undo restores completed edit") { LayoutSnapshot.capture(layout(memory)).samePresentation(saved) }
            click("Done");scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }

}
