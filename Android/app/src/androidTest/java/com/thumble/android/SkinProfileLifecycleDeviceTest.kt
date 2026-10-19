package com.thumble.android

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class SkinProfileLifecycleDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private fun oracle()=instrumentation.context.assets.open("skin-resolution/v1/native-lifecycle-oracle.json").use { JSONObject(it.bufferedReader().readText()) }
    private fun profile()=ControllerProfile.parse(oracle().getJSONArray("cases").getJSONObject(0).getJSONObject("input"))
    private fun archive()=instrumentation.context.assets.open("solar-sumi-1.0.0-edbecde5b708.pocketpad").use { it.readBytes() }
    private fun await(label: String,condition: ()->Boolean) {
        val limit=SystemClock.elapsedRealtime()+10_000
        while(!condition() && SystemClock.elapsedRealtime()<limit) SystemClock.sleep(20)
        assertTrue(label,condition())
    }
    @Test fun allNativeApplyReapplyDetachTransitionsMatchOnMinimumAPI() = SkinLifecycleOracle(::oracle).applicationAndDetachmentMatchNative()

    @Test fun privateAtomicProfileFileRetainsPendingIntentsAcrossOrdinarySavesAndReload() {
        val name="skin-journal-${UUID.randomUUID()}";val store=AndroidSessionStore(instrumentation.targetContext,name)
        try {
            val p=profile();val pending=PendingSkinSelection(p.id,SkinReference("com.example.test","1.0.0"),123,"mac-a")
            val snapshot=ProfileSnapshot(listOf(p),p.id,p.id)
            store.saveSkinState(snapshot,listOf(pending))
            val reloaded=AndroidSessionStore(instrumentation.targetContext,name)
            assertEquals(listOf(pending),reloaded.loadPendingSkinSelections())
            assertEquals(p.source.toString(),reloaded.loadSnapshot().selected!!.source.toString())
            reloaded.saveSnapshot(snapshot.copy(defaultID=null))
            assertEquals(listOf(pending),AndroidSessionStore(instrumentation.targetContext,name).loadPendingSkinSelections())
            val path=File(instrumentation.targetContext.noBackupFilesDir,"$name/profiles.json")
            val before=path.readBytes()
            val malformed=JSONObject(before.toString(Charsets.UTF_8)).put("androidPendingSkinSelections","corrupt journal")
            path.writeText(malformed.toString())
            try { reloaded.saveSnapshot(snapshot);fail("Must not overwrite an unreadable pending journal") } catch(_:Exception) { }
            assertEquals(malformed.toString(),path.readText())
            path.writeBytes(before)
            reloaded.forgetMac()
            assertTrue(reloaded.loadPendingSkinSelections().isEmpty())
        } finally { store.forgetMac();File(instrumentation.targetContext.noBackupFilesDir,name).deleteRecursively() }
    }

    @Test fun reconnectUploadsArchiveBeforeSelectionAndAcknowledgesOnlyMatchingAuthoritativeReference() {
        val bytes=archive();val pkg=SkinPackageCodec.decode(bytes);val original=profile()
        val applied=SkinProfileLifecycle.apply(original,pkg,"light",123)
        val store=MemorySessionStore().apply {
            saveSkinState(ProfileSnapshot(listOf(applied),applied.id),listOf(PendingSkinSelection(applied.id,pkg.reference,123)))
        }
        val wire=CopyOnWriteArrayList<JSONObject>();val peer=AtomicReference<WebSocket>()
        val server=MockWebServer()
        fun snapshot(type: String,p: ControllerProfile)=WireCodec.message(type).put("inputProtocolVersion",3)
            .put("serverID","skin-fixture").put("authToken","private-test-token")
            .put("gamepadProfiles",JSONArray().put(p.source)).put("gamepadProfileID",p.id.toString())
            .put("capabilities",JSONArray().put("skin_packages").put("gamepad_profile_skin_selection"))
        server.enqueue(MockResponse().withWebSocketUpgrade(object:WebSocketListener() {
            override fun onOpen(webSocket:WebSocket,response:Response) { peer.set(webSocket);webSocket.send(snapshot("pairing_accepted",original).toString()) }
            override fun onMessage(webSocket:WebSocket,text:String) { wire.add(JSONObject(text)) }
        }))
        server.start()
        val state=AtomicReference(ClientState());var client=ControllerClient(store,skinArchive={ bytes }) { state.set(it) }
        try {
            client.connect(PairingTarget.manual(server.url("/").toString().replaceFirst("http://","ws://"),"123456"))
            await("pending selection replayed") { wire.any { it.optString("type")=="gamepad_profile_skin_selection" } }
            val types=wire.map { it.optString("type") }
            assertTrue(types.indexOf("skin_packages")<types.indexOf("gamepad_profile_skin_selection"))
            val sent=wire.first { it.optString("type")=="skin_packages" }.getJSONArray("skinPackages").getString(0)
            assertArrayEquals(bytes,Base64.getDecoder().decode(sent))
            assertEquals(1,store.loadPendingSkinSelections().size)
            peer.get().send(snapshot("gamepad_profiles",original).toString())
            SystemClock.sleep(100)
            assertEquals(1,store.loadPendingSkinSelections().size)
            peer.get().send(snapshot("gamepad_profiles",applied).toString())
            await("matching authoritative reference acknowledged") { state.get().pendingSkinChanges==0 && store.loadPendingSkinSelections().isEmpty() }
            val selected=state.get().snapshot.selected!!
            val detached=SkinProfileLifecycle.detach(selected,pkg,"light",124)
            client.commitSkinChange(selected,detached,null)
            await("offline detach persisted") { state.get().pendingSkinChanges==1 && store.loadPendingSkinSelections().singleOrNull()?.reference==null }
            val revision=state.get().surfaceRevision
            peer.get().send(WireCodec.message("gamepad_customization").put("gamepadCustomization",selected.layout(false)).toString())
            await("legacy scalar processed without acknowledging local skin reference") { state.get().surfaceRevision>revision }
            assertEquals(1,state.get().pendingSkinChanges);assertEquals(1,store.loadPendingSkinSelections().size)
            client.disconnect();await("disconnected") { !state.get().paired }
            client.dispose()
            val restarted=MemorySessionStore().apply { saveSkinState(store.loadSnapshot(),store.loadPendingSkinSelections());store.loadMac()?.let(::saveMac) }
            wire.clear()
            server.enqueue(MockResponse().withWebSocketUpgrade(object:WebSocketListener() {
                override fun onOpen(webSocket:WebSocket,response:Response) { peer.set(webSocket);webSocket.send(snapshot("pairing_accepted",applied).toString()) }
                override fun onMessage(webSocket:WebSocket,text:String) { wire.add(JSONObject(text)) }
            }))
            client=ControllerClient(restarted,skinArchive={ bytes }) { state.set(it) }
            client.reconnect()
            await("offline detach replayed after new client") { wire.any { it.optString("type")=="gamepad_profile_skin_selection" } }
            assertFalse(wire.first { it.optString("type")=="gamepad_profile_skin_selection" }.has("skinReference"))
            assertFalse(wire.any { it.optString("type")=="skin_packages" })
            peer.get().send(snapshot("gamepad_profiles",detached).toString())
            await("detach acknowledged") { state.get().pendingSkinChanges==0 && restarted.loadPendingSkinSelections().isEmpty() }
            client.disconnect();await("disconnected before unsupported host") { !state.get().paired }
            val local=state.get().snapshot.selected!!
            client.commitSkinChange(local,SkinProfileLifecycle.apply(local,pkg,"light"),pkg.reference)
            await("new offline intent saved") { state.get().pendingSkinChanges==1 }
            wire.clear()
            server.enqueue(MockResponse().withWebSocketUpgrade(object:WebSocketListener() {
                override fun onOpen(webSocket:WebSocket,response:Response) {
                    val hello=snapshot("pairing_accepted",original);hello.remove("capabilities");webSocket.send(hello.toString())
                }
                override fun onMessage(webSocket:WebSocket,text:String) { wire.add(JSONObject(text)) }
            }))
            client.reconnect();await("host without skin capabilities paired") { state.get().paired }
            assertTrue(state.get().capabilities.isEmpty());assertEquals(1,restarted.loadPendingSkinSelections().size)
            assertFalse(wire.any { it.optString("type") in setOf("skin_packages","gamepad_profile_skin_selection") })
        } finally { client.dispose();server.shutdown() }
    }

    @Test fun nativeImportReviewAndProfileMenuApplyDetachPersistOfflineWithoutInput() {
        val context=instrumentation.targetContext;val library=SkinLibrary(File(context.filesDir,"skins"))
        val bytes=archive();val pkg=SkinPackageCodec.decode(bytes)
        val old=runCatching { library.archiveFor(pkg.reference) }.getOrNull()
        if(old!=null) library.remove(pkg.reference)
        val original=profile();val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(original),original.id)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        val automation=instrumentation.uiAutomation
        val serviceInfo=automation.serviceInfo
        val originalFlags=serviceInfo.flags
        serviceInfo.flags=serviceInfo.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        automation.serviceInfo=serviceInfo
        fun node(text:String):AccessibilityNodeInfo? {
            fun find(n:AccessibilityNodeInfo):AccessibilityNodeInfo? {
                if(n.text?.toString()==text || n.contentDescription?.toString()==text) return n
                repeat(n.childCount) { n.getChild(it)?.let { child -> find(child)?.let { return it } } }
                return null
            }
            automation.rootInActiveWindow?.let(::find)?.let { return it }
            // API 26 can retain the dismissed dialog as its active-window ID.
            // Query only windows Android reports as currently interactive.
            return automation.windows.asSequence().filter { it.isFocused || it.isActive }
                .mapNotNull { it.root?.let(::find) }.firstOrNull()
        }
        fun click(text:String) {
            try { await("visible action $text") {
                var n=node(text) ?: return@await false
                while(!n.isClickable && n.parent!=null) n=n.parent
                n.isEnabled
            } } catch(e:AssertionError) {
                instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
                    File(context.getExternalFilesDir(null),"skin-lifecycle-failure.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()
                }
                fun dump(n:AccessibilityNodeInfo):List<String> = listOfNotNull(n.text?.toString(),n.contentDescription?.toString())+(0 until n.childCount).flatMap { i -> n.getChild(i)?.let(::dump).orEmpty() }
                println("Isolated skin UI diagnostic: "+instrumentation.uiAutomation.rootInActiveWindow?.let(::dump))
                val descriptor=instrumentation.uiAutomation.executeShellCommand("dumpsys window windows")
                val windows=java.io.FileInputStream(descriptor.fileDescriptor).bufferedReader().use { it.readText() }
                descriptor.close()
                println("Isolated skin focus diagnostic: "+windows.lineSequence().filter { it.contains("mCurrentFocus") || it.contains("mFocusedApp") }.joinToString())
                throw e
            }
            var n=node(text)!!;while(!n.isClickable && n.parent!=null) n=n.parent
            assertTrue(n.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        }
        fun capture(name:String) {
            instrumentation.uiAutomation.waitForIdle(200,5_000)
            val bitmap=instrumentation.uiAutomation.takeScreenshot()!!
            File(context.getExternalFilesDir(null),name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };bitmap.recycle()
        }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() }
            await("saved keypad") { node(original.name)!=null }
            // Feed the selected document bytes through the same worker used by SAF.
            // System document-provider navigation is a separate acceptance gate.
            scenario.onActivity { ViewModelProvider(it)[ControllerSession::class.java].prepareSkinImport { bytes.inputStream() } }
            await("native import review") { node("Import skin")!=null }
            assertNotNull(node(pkg.name));capture("skin-import-review.png")
            click("Cancel")
            await("review dismissed without installation") { node("Import skin")==null }
            assertTrue(library.installed().none { it.reference==pkg.reference })
            scenario.onActivity { ViewModelProvider(it)[ControllerSession::class.java].prepareSkinImport { bytes.inputStream() } }
            await("second review") { node("Import skin")!=null }
            click("Import")
            await("archive installed") { runCatching { library.archiveFor(pkg.reference).contentEquals(bytes) }.getOrDefault(false) }
            await("review closed") { node("Import skin")==null }
            assertSame(original,store.loadSnapshot().selected)
            capture("skin-after-import.png")
            click(original.name)
            click("Apply ${pkg.name} · ${pkg.reference.version}")
            await("skin selection persisted") { store.loadSnapshot().selected?.source?.optJSONObject("skinReference")?.optString("identifier")==pkg.reference.identifier }
            assertEquals(1,store.loadPendingSkinSelections().size)
            assertEquals(pkg.reference,store.loadPendingSkinSelections().single().reference)
            assertEquals(original.id,store.loadSnapshot().selected!!.id)
            await("applied appearance finished loading") {
                node("1 skin change waiting for Mac sync")!=null && node("Loading keypad appearance…")==null && node("Preparing skin…")==null
            }
            capture("skin-applied-offline.png")
            click(original.name);click("Detach skin")
            await("detached profile persisted") { store.loadSnapshot().selected?.source?.has("skinReference")==false }
            assertEquals(1,store.loadPendingSkinSelections().size);assertNull(store.loadPendingSkinSelections().single().reference)
            scenario.onActivity { activity ->
                assertTrue(activity.connectionState.practiceMode);assertFalse(activity.connectionState.paired)
                assertEquals(0L,activity.connectionState.udpFrames);assertEquals(0L,activity.connectionState.webSocketFrames)
                assertEquals(original.id,activity.connectionState.snapshot.selected!!.id)
            }
            capture("skin-detached-offline.png")
            File(context.getExternalFilesDir(null),"skin-lifecycle-result.json").writeText(JSONObject()
                .put("sdk",android.os.Build.VERSION.SDK_INT).put("archiveSHA256",pkg.archiveSHA256)
                .put("importReviewCancelPreservesLibrary",true).put("importDoesNotApplyOrAdoptBindings",true)
                .put("menuApplyDetachPersisted",true).put("pendingLastIntentRetained",true)
                .put("offlineNoInput",true).put("safDocumentNavigationVerified",false)
                .put("macSkinSyncImplemented",false).toString(2))
        } } finally {
            ClientDependencies.sessionStore=previous
            serviceInfo.flags=originalFlags;automation.serviceInfo=serviceInfo
            if(old==null) runCatching { library.remove(pkg.reference) } else library.install(old,SkinInstallPolicy.REPLACE_SAME_VERSION)
        }
    }

    @Test fun failedAtomicSaveKeepsOriginalProfilePendingIntentAndInputRevision() {
        val memory=MemorySessionStore();val original=profile();memory.saveSnapshot(ProfileSnapshot(listOf(original),original.id))
        val failing=object:SessionStore by memory {
            override fun saveSkinState(snapshot:ProfileSnapshot,pending:List<PendingSkinSelection>) { throw java.io.IOException("Fixture save failure") }
        }
        val state=AtomicReference(ClientState());val client=ControllerClient(failing) { state.set(it) }
        try {
            await("saved profile loaded") { state.get().snapshot.selected!=null }
            val revision=state.get().surfaceRevision
            val result=SkinProfileLifecycle.apply(original,SkinPackageCodec.decode(archive()),"light")
            client.commitSkinChange(original,result,SkinPackageCodec.decode(archive()).reference)
            await("save failure reported") { state.get().error?.contains("Could not save the skin change")==true }
            assertSame(original,state.get().snapshot.selected);assertSame(original,memory.loadSnapshot().selected)
            assertEquals(revision,state.get().surfaceRevision);assertEquals(0,state.get().pendingSkinChanges)
            assertTrue(memory.loadPendingSkinSelections().isEmpty())
        } finally { client.dispose() }
    }
}
