package com.thumble.android

import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.InputDevice
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.lifecycle.ViewModelProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class SkinLibraryManagementDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private var oldFlags=0
    @org.junit.Before fun observeWindows() {
        val info=instrumentation.uiAutomation.serviceInfo;oldFlags=info.flags
        info.flags=info.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        instrumentation.uiAutomation.serviceInfo=info
    }
    @org.junit.After fun restoreWindows() {
        val info=instrumentation.uiAutomation.serviceInfo;info.flags=oldFlags;instrumentation.uiAutomation.serviceInfo=info
    }
    private fun await(label: String,condition: ()->Boolean) {
        val end=SystemClock.elapsedRealtime()+20_000
        while(SystemClock.elapsedRealtime()<end) { if(condition()) return;SystemClock.sleep(30) }
        screenshot("failed-"+label.replace(Regex("[^a-zA-Z0-9]+"),"-").take(70))
        fail(label)
    }
    private fun find(predicate: (AccessibilityNodeInfo)->Boolean): AccessibilityNodeInfo? {
        fun walk(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if(!n.refresh()) return null
            if(predicate(n)) return n
            repeat(n.childCount) { n.getChild(it)?.let { child -> walk(child)?.let { return it } } }
            return null
        }
        val automation=instrumentation.uiAutomation
        val roots=listOfNotNull(automation.rootInActiveWindow)+automation.windows.filter { it.isActive || it.isFocused }.mapNotNull { it.root }
        for(root in roots) { if(root.refresh()) walk(root)?.let { return it } }
        return null
    }
    private fun node(label: String)=find {
        val bounds=Rect();it.getBoundsInScreen(bounds)
        val metrics=instrumentation.targetContext.resources.displayMetrics
        it.isVisibleToUser && !bounds.isEmpty && bounds.height()>=12*metrics.scaledDensity && bounds.top>=0 && bounds.bottom<=metrics.heightPixels &&
            (it.text?.toString()==label || it.contentDescription?.toString()==label)
    }
    private fun click(label: String) {
        val cardAction=label.startsWith("Apply ") || label.startsWith("Share ") || label.startsWith("Save ") || (label.startsWith("Remove ") && label!="Remove skin")
        var previous: Rect?=null;var stableSince=0L;var tap: Rect?=null
        instrumentation.uiAutomation.waitForIdle(200,2_000)
        await("stable visible action $label") {
            val candidate=node(label)
            if(candidate==null) {
                previous=null
                // Authoritative apply/fork updates can move the card after scrolling.
                if(cardAction) swipe(true)
                false
            } else if(!candidate.isEnabled || !candidate.refresh()) { previous=null;false }
            else {
                val bounds=Rect();candidate.getBoundsInScreen(bounds)
                val now=SystemClock.elapsedRealtime()
                if(bounds!=previous) { previous=Rect(bounds);stableSince=now }
                if(now-stableSince>=300) { tap=Rect(bounds);true } else false
            }
        }
        val bounds=tap!!;val now=SystemClock.uptimeMillis()
        if(label.startsWith("Apply ")) screenshot("apply-before-tap")
        for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP)) {
            val e=MotionEvent.obtain(now,SystemClock.uptimeMillis(),action,bounds.exactCenterX(),bounds.exactCenterY(),0)
            e.source=InputDevice.SOURCE_TOUCHSCREEN;assertTrue(instrumentation.uiAutomation.injectInputEvent(e,true));e.recycle()
        }
        instrumentation.uiAutomation.waitForIdle(100,2_000)
    }
    private fun swipe(up: Boolean) {
        val metrics=instrumentation.targetContext.resources.displayMetrics
        val start=SystemClock.uptimeMillis();val from=metrics.heightPixels*(if(up) .75f else .3f)
        val to=metrics.heightPixels*(if(up) .3f else .75f)
        // The list's padding is outside the non-interactive preview view.
        for(i in 0..10) {
            val action=if(i==0) MotionEvent.ACTION_DOWN else MotionEvent.ACTION_MOVE
            val e=MotionEvent.obtain(start,SystemClock.uptimeMillis(),action,8f,from+(to-from)*i/10,0)
            e.source=InputDevice.SOURCE_TOUCHSCREEN;instrumentation.uiAutomation.injectInputEvent(e,true);e.recycle();SystemClock.sleep(20)
        }
        // Hold at the endpoint so this is a controlled scroll, not a fling.
        SystemClock.sleep(250)
        val upEvent=MotionEvent.obtain(start,SystemClock.uptimeMillis(),MotionEvent.ACTION_UP,8f,to,0)
        upEvent.source=InputDevice.SOURCE_TOUCHSCREEN;instrumentation.uiAutomation.injectInputEvent(upEvent,true);upEvent.recycle()
        instrumentation.uiAutomation.waitForIdle(250,2_000)
    }
    private fun scrollTo(label: String) {
        repeat(16) { if(node(label)!=null) return;swipe(true) }
        screenshot("scroll-failed");assertNotNull(label,node(label))
    }
    private fun top() { repeat(12) { if(node("Current keypad")!=null) return;swipe(false) } }
    private fun screenshot(name: String) {
        val b=instrumentation.uiAutomation.takeScreenshot()!!
        File(instrumentation.targetContext.getExternalFilesDir(null),"skin-library-$name.png").outputStream().use { b.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };b.recycle()
    }
    private fun shell(command: String)=instrumentation.uiAutomation.executeShellCommand(command).use { descriptor ->
        java.io.FileInputStream(descriptor.fileDescriptor).use { it.readBytes() }
    }
    @Test fun libraryAppliesForksSharesSavesAndRejectsRemovingAnInUsePackage() {
        val context=instrumentation.targetContext;val library=SkinLibrary(File(context.filesDir,"skins"))
        val bytes=instrumentation.context.assets.open("solar-sumi-1.0.0-edbecde5b708.pocketpad").use { it.readBytes() };val pkg=SkinPackageCodec.decode(bytes)
        val oldArchive=runCatching { library.archiveFor(pkg.reference) }.getOrNull()
        library.install(bytes,SkinInstallPolicy.REPLACE_SAME_VERSION)
        val profile=ControllerProfile.parse(JSONObject(instrumentation.context.assets.open("controller-templates/v1/arcadeStick.json").bufferedReader().use { it.readText() }).getJSONObject("profile").put("orientationPreference","portrait"))
        val memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(profile),profile.id,profile.id)) }
        val oldStore=ClientDependencies.sessionStore;ClientDependencies.sessionStore={memory}
        val filename="thumble-library-${UUID.randomUUID()}.pocketpad"
        val transferRoot=File(context.cacheDir,"skin-shares")
        val existingTransfers=transferRoot.listFiles().orEmpty().map { it.name }.toSet()
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() };click(profile.name);click("Skins")
            await("library current keypad") { node("Current keypad")!=null };screenshot("current")
            scrollTo("Apply ${pkg.name}");click("Apply ${pkg.name}")
            try { await("canonical appearance saved") { memory.loadSnapshot().selected!!.source.optJSONObject("skinReference")!=null } }
            catch(failure: AssertionError) {
                screenshot("apply-failed")
                scenario.onActivity { activity ->
                    val session=ViewModelProvider(activity)[ControllerSession::class.java]
                    throw AssertionError("Skin apply: busy=${session.skinBusy}, skinError=${session.skinError}, clientError=${activity.connectionState.error}",failure)
                }
            }
            assertEquals(profile.id,memory.loadSnapshot().selectedID)
            scrollTo("Remove ${pkg.name}");click("Remove ${pkg.name}");click("Remove skin")
            await("in-use guard") { var error=false;scenario.onActivity { error=it.connectionState.error?.contains("still used")==true };error }
            assertArrayEquals(bytes,library.archiveFor(pkg.reference))
            click("OK")
            scrollTo("Share ${pkg.name}");click("Share ${pkg.name}")
            // API 26 may open the sole installed share handler immediately.
            await("system share surface") { node("Share skin")!=null || find { it.packageName?.toString() in setOf("com.google.android.gm","com.android.intentresolver") }!=null }
            screenshot("share")
            // Gmail's first-run screen ignores Back. Leave the consumer untouched
            // and return through Home/the app launcher, as a user can always do.
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
            shell("am start -W -n com.thumble.android/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10020000")
            await("share returns to library") { node("Skins")!=null }
            scrollTo("Save ${pkg.name} package");click("Save ${pkg.name} package")
            await("system document picker") { find { it.packageName?.toString()?.contains("documentsui")==true }!=null }
            val field=find { it.className?.toString()=="android.widget.EditText" }!!
            assertTrue(field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,android.os.Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,filename) }))
            screenshot("save-picker")
            val save=find { it.text?.toString()?.equals("Save",true)==true && it.isClickable }!!
            assertTrue(save.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            await("save returns to library") { var ready=false;scenario.onActivity { ready=ViewModelProvider(it)[ControllerSession::class.java].skinNotice=="Skin package saved." };ready }
            assertArrayEquals("SAF export preserves exact archive",bytes,shell("cat /sdcard/Download/$filename"))
            scrollTo("Save ${pkg.name} package");click("Save ${pkg.name} package")
            await("second document picker") { find { it.packageName?.toString()?.contains("documentsui")==true }!=null }
            repeat(2) {
                if(node("Skins")==null) {
                    instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
                    val deadline=SystemClock.elapsedRealtime()+2_000
                    while(node("Skins")==null && SystemClock.elapsedRealtime()<deadline) SystemClock.sleep(50)
                }
            }
            await("cancelled picker returns without pending export") {
                var returned=false
                if(node("Skins")!=null) scenario.onActivity { returned=ViewModelProvider(it)[ControllerSession::class.java].documentExport==null }
                returned
            }
            assertNotNull(memory.loadSnapshot().selected!!.source.optJSONObject("skinReference"))
            screenshot("save-cancelled")
            top();scrollTo("Fork current appearance");click("Fork current appearance")
            await("fork removes dependency") { memory.loadSnapshot().selected!!.source.optJSONObject("skinReference")==null }
            scrollTo("Remove ${pkg.name}");click("Remove ${pkg.name}");click("Remove skin")
            await("unused archive removed") { runCatching { library.archiveFor(pkg.reference) }.isFailure }
            top();screenshot("removed")
            click("Done");await("library closes") { node(profile.name)!=null }
            click(profile.name);click("Skins");await("library reopened") { node("Current keypad")!=null }
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
            await("hardware Back closes library") { node(profile.name)!=null && node("Current keypad")==null }
            scenario.onActivity { assertFalse(it.connectionState.paired);assertEquals(0L,it.connectionState.webSocketFrames);assertEquals(0L,it.connectionState.udpFrames);it.finish() }
        } } finally {
            shell("rm -f /sdcard/Download/$filename")
            ClientDependencies.sessionStore=oldStore
            transferRoot.listFiles().orEmpty().filter { it.name !in existingTransfers }.forEach { it.deleteRecursively() }
            if(oldArchive!=null) library.install(oldArchive,SkinInstallPolicy.ALLOW_DOWNGRADE) else runCatching { library.remove(pkg.reference) }
        }
    }
    @Test fun shareProviderExposesOnlyExportedArchiveBytesAndReadPermission() {
        val context=instrumentation.targetContext
        val bytes=instrumentation.context.assets.open("solar-sumi-1.0.0-edbecde5b708.pocketpad").use { it.readBytes() }
        val file=SkinTransferFiles.prepare(context.cacheDir,SkinPackageCodec.decode(bytes))
        try {
            val intent=SkinTransferFiles.shareIntent(context,file)
            assertEquals(android.content.Intent.ACTION_SEND,intent.action)
            assertTrue(intent.flags and android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION!=0)
            assertEquals(0,intent.flags and android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            val uri=intent.clipData!!.getItemAt(0).uri
            assertEquals("content",uri.scheme)
            assertArrayEquals(bytes,context.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
            assertTrue(runCatching { androidx.core.content.FileProvider.getUriForFile(context,"${context.packageName}.skin-files",File(context.filesDir,"profiles.json")) }.isFailure)
        } finally { file.parentFile!!.deleteRecursively() }
    }
    @Test fun removalQueueSurvivesReloadTargetsOnlyItsMacAndRetiresReplayedArchivesInOrder() {
        val context=instrumentation.targetContext;val namespace="skin-removal-${UUID.randomUUID()}"
        val store=AndroidSessionStore(context,namespace)
        val reference=SkinReference("com.example.fixture","1.0.0")
        val a=PendingSkinRemoval(reference,"mac-a");val b=PendingSkinRemoval(reference,"mac-b")
        store.savePendingSkinRemovals(listOf(a,b))
        assertEquals(listOf(a,b),AndroidSessionStore(context,namespace).loadPendingSkinRemovals())
        val p=JSONObject(instrumentation.context.assets.open("controller-templates/v1/arcadeStick.json").bufferedReader().use { it.readText() }).getJSONObject("profile")
        val frames=java.util.concurrent.CopyOnWriteArrayList<JSONObject>();val order=java.util.concurrent.CopyOnWriteArrayList<String>()
        val server=okhttp3.mockwebserver.MockWebServer()
        server.enqueue(okhttp3.mockwebserver.MockResponse().withWebSocketUpgrade(object: okhttp3.WebSocketListener() {
            override fun onMessage(ws: okhttp3.WebSocket,text: String) {
                val message=JSONObject(text);frames+=message
                if(message.optString("type")=="hello") ws.send(WireCodec.message("pairing_accepted").put("inputProtocolVersion",3)
                    .put("serverID","mac-a").put("authToken","private-removal-fixture-token")
                    .put("capabilities",org.json.JSONArray().put("skin_packages"))
                    .put("gamepadProfiles",org.json.JSONArray().put(p)).put("gamepadProfileID",p.getString("id"))
                    .put("skinPackages",org.json.JSONArray().put(java.util.Base64.getEncoder().encodeToString(byteArrayOf(1)))).toString())
            }
        }))
        server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val state=java.util.concurrent.atomic.AtomicReference(ClientState())
        val client=ControllerClient(store,incomingSkins={ order+="archives";true },removedSkins={ _,completed -> order+="remove";completed(true) }) { state.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"))
            await("removal sent only to paired owner") { frames.count { it.optString("type")=="skin_package_removal" }==1 && order.lastOrNull()=="remove" && state.get().pendingSkinRemovals==1 }
            assertEquals(listOf(b),store.loadPendingSkinRemovals())
            assertEquals(listOf("archives","remove"),order.toList())
            assertEquals(reference,SkinReference.parse(frames.first { it.optString("type")=="skin_package_removal" }.getJSONObject("skinReference")))
            assertEquals(listOf(b),AndroidSessionStore(context,namespace).loadPendingSkinRemovals())
            val done=java.util.concurrent.atomic.AtomicBoolean()
            client.cancelSkinRemoval(reference) { done.set(it) };await("reimport cancels queued removal") { done.get() }
            assertTrue(store.loadPendingSkinRemovals().isEmpty())
        } finally { client.dispose();server.shutdown();store.forgetMac();File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
    @Test fun failedRemovalJournalSaveRejectsTheRemovalBeforeTouchingTheLibrary() {
        val p=ControllerProfile.parse(JSONObject(instrumentation.context.assets.open("controller-templates/v1/arcadeStick.json").bufferedReader().use { it.readText() }).getJSONObject("profile"))
        val memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id)) }
        val store=object: SessionStore by memory {
            override fun savePendingSkinRemovals(values: List<PendingSkinRemoval>) { throw java.io.IOException("Fixture disk failure") }
        }
        val state=java.util.concurrent.atomic.AtomicReference(ClientState())
        val client=ControllerClient(store) { state.set(it) }
        val result=java.util.concurrent.atomic.AtomicReference<Boolean>()
        try {
            client.queueSkinRemoval(SkinReference("com.example.fixture","1.0.0")) { result.set(it) }
            await("removal failure returned") { result.get()!=null }
            assertFalse(result.get());assertTrue(state.get().error!!.contains("package is kept"));assertTrue(memory.loadPendingSkinRemovals().isEmpty())
        } finally { client.dispose() }
    }

    @Test fun previewDoesNotCaptureTouchesOrExposeRuntimeControlAccessibility() {
        val context=instrumentation.targetContext
        val profile=ControllerProfile.parse(JSONObject(instrumentation.context.assets.open("controller-templates/v1/arcadeStick.json").bufferedReader().use { it.readText() }).getJSONObject("profile"))
        instrumentation.runOnMainSync {
            val preview=SkinPreviewSurface(context);preview.show(profile,false,false,true)
            preview.measure(android.view.View.MeasureSpec.makeMeasureSpec(700,android.view.View.MeasureSpec.EXACTLY),android.view.View.MeasureSpec.makeMeasureSpec(500,android.view.View.MeasureSpec.EXACTLY))
            preview.layout(0,0,700,500)
            val renderer=preview.getChildAt(0) as ControllerSurface
            var inputs=0;renderer.onEdge={_,_,_ -> inputs++}
            for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_MOVE,MotionEvent.ACTION_UP)) {
                val e=MotionEvent.obtain(0,SystemClock.uptimeMillis(),action,350f,250f,0)
                assertFalse("preview leaves scrolling to its parent",preview.dispatchTouchEvent(e));e.recycle()
            }
            assertEquals(0,inputs)
            assertEquals(android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS,preview.importantForAccessibility)
            assertEquals(android.view.ViewGroup.FOCUS_BLOCK_DESCENDANTS,preview.descendantFocusability)
            repeat(renderer.childCount) { assertFalse(renderer.getChildAt(it).isPressed) }
        }
    }

    @Test fun failedJournalClearDoesNotResendOnEverySnapshotButRetriesOnReconnect() {
        val reference=SkinReference("com.example.fixture","1.0.0")
        val memory=MemorySessionStore().apply { savePendingSkinRemovals(listOf(PendingSkinRemoval(reference,"mac-a"))) }
        val store=object: SessionStore by memory {
            override fun savePendingSkinRemovals(values: List<PendingSkinRemoval>) { throw java.io.IOException("Fixture journal clear failure") }
        }
        val p=JSONObject(instrumentation.context.assets.open("controller-templates/v1/arcadeStick.json").bufferedReader().use { it.readText() }).getJSONObject("profile")
        val connections=java.util.concurrent.atomic.AtomicInteger();val removals=java.util.concurrent.atomic.AtomicInteger()
        val peer=java.util.concurrent.atomic.AtomicReference<okhttp3.WebSocket>()
        val server=okhttp3.mockwebserver.MockWebServer()
        repeat(2) { server.enqueue(okhttp3.mockwebserver.MockResponse().withWebSocketUpgrade(object: okhttp3.WebSocketListener() {
            override fun onOpen(ws: okhttp3.WebSocket,response: okhttp3.Response) { peer.set(ws);connections.incrementAndGet() }
            override fun onMessage(ws: okhttp3.WebSocket,text: String) {
                when(JSONObject(text).optString("type")) {
                    "hello" -> ws.send(WireCodec.message("pairing_accepted").put("inputProtocolVersion",3).put("serverID","mac-a")
                        .put("authToken","private-clear-fixture-token").put("capabilities",org.json.JSONArray().put("skin_packages"))
                        .put("gamepadProfiles",org.json.JSONArray().put(p)).put("gamepadProfileID",p.getString("id")).toString())
                    "skin_package_removal" -> removals.incrementAndGet()
                }
            }
        })) }
        server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val state=java.util.concurrent.atomic.AtomicReference(ClientState())
        val client=ControllerClient(store) { state.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"))
            await("first removal enqueued") { state.get().paired && removals.get()==1 }
            repeat(12) { peer.get().send(WireCodec.message("gamepad_profiles").put("gamepadProfiles",org.json.JSONArray().put(p)).put("gamepadProfileID",p.getString("id")).toString()) }
            SystemClock.sleep(750)
            assertEquals("failed clear must not flood this connection",1,removals.get())
            assertEquals(1,memory.loadPendingSkinRemovals().size)
            client.disconnect();await("explicit disconnect") { !state.get().paired }
            client.reconnect();await("new connection retries retained intent") { state.get().paired && connections.get()==2 && removals.get()==2 }
        } finally { client.dispose();server.shutdown() }
    }

    @Test fun removalIntentSurvivesDisposalBeforeLocalReplayCleanupFinishes() {
        val reference=SkinReference("com.example.fixture","1.0.0")
        val memory=MemorySessionStore().apply { savePendingSkinRemovals(listOf(PendingSkinRemoval(reference,"mac-a"))) }
        val p=JSONObject(instrumentation.context.assets.open("controller-templates/v1/arcadeStick.json").bufferedReader().use { it.readText() }).getJSONObject("profile")
        val removals=java.util.concurrent.atomic.AtomicInteger()
        val server=okhttp3.mockwebserver.MockWebServer()
        repeat(2) { server.enqueue(okhttp3.mockwebserver.MockResponse().withWebSocketUpgrade(object: okhttp3.WebSocketListener() {
            override fun onMessage(ws: okhttp3.WebSocket,text: String) {
                when(JSONObject(text).optString("type")) {
                    "hello" -> ws.send(WireCodec.message("pairing_accepted").put("inputProtocolVersion",3).put("serverID","mac-a")
                        .put("authToken","private-disposal-fixture-token").put("capabilities",org.json.JSONArray().put("skin_packages"))
                        .put("gamepadProfiles",org.json.JSONArray().put(p)).put("gamepadProfileID",p.getString("id")).toString())
                    "skin_package_removal" -> removals.incrementAndGet()
                }
            }
        })) }
        server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val cleanup=java.util.concurrent.atomic.AtomicReference<((Boolean)->Unit)>()
        val first=ControllerClient(memory,removedSkins={ _,done -> cleanup.set(done) }) { }
        var second: ControllerClient?=null
        try {
            first.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"))
            await("removal awaits local replay cleanup") { cleanup.get()!=null && removals.get()==1 }
            assertEquals(1,memory.loadPendingSkinRemovals().size)
            val cancelled=java.util.concurrent.atomic.AtomicBoolean()
            first.cancelSkinRemoval(reference) { cancelled.set(it) };await("cancel first removal") { cancelled.get() }
            val replacement=java.util.concurrent.atomic.AtomicBoolean()
            first.queueSkinRemoval(reference) { replacement.set(it) };await("record newer same-owner intent") { replacement.get() }
            cleanup.get().invoke(true)
            val barrier=java.util.concurrent.atomic.AtomicBoolean()
            first.cancelSkinRemoval(SkinReference("com.example.unrelated","1.0.0")) { barrier.set(it) }
            await("old completion processed") { barrier.get() }
            assertEquals("an older completion cannot clear the newer intent",1,memory.loadPendingSkinRemovals().size)
            first.dispose()
            val state=java.util.concurrent.atomic.AtomicReference(ClientState())
            second=ControllerClient(memory) { state.set(it) }
            second.reconnect()
            await("reload retries and commits after cleanup") { state.get().paired && state.get().pendingSkinRemovals==0 && removals.get()==2 }
            assertTrue(memory.loadPendingSkinRemovals().isEmpty())
            val queued=java.util.concurrent.atomic.AtomicBoolean()
            val newerReference=SkinReference("com.example.newer","1.0.0")
            second.queueSkinRemoval(newerReference) { queued.set(it) }
            await("new owner records a new removal") { queued.get() }
            cleanup.get().invoke(true) // A late completion must not erase the new owner's intent.
            SystemClock.sleep(200)
            assertEquals(listOf(PendingSkinRemoval(newerReference,"mac-a")),memory.loadPendingSkinRemovals())
        } finally { first.dispose();second?.dispose();server.shutdown() }
    }

}
