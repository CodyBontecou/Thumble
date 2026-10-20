package com.thumble.android

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

@RunWith(AndroidJUnit4::class)
class IncomingSkinSyncDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val firstName="solar-sumi-1.0.0-edbecde5b708.pocketpad"
    private val otherName="foldline-relay-1.0.0-d04c121e9b0a.pocketpad"
    private fun archive(name:String=firstName)=instrumentation.context.assets.open(name).use { it.readBytes() }
    private fun profile()=ControllerProfile.parse(instrumentation.context.assets.open("controller-templates/v1/productivityStarter.json")
        .use { JSONObject(it.bufferedReader().readText()) }.getJSONObject("profile"))
    private fun packages(type:String,vararg bytes:ByteArray)=WireCodec.message(type).put("skinPackages",JSONArray().also { a -> bytes.forEach { a.put(Base64.getEncoder().encodeToString(it)) } })
    private fun accepted(p:ControllerProfile)=WireCodec.message("pairing_accepted").put("inputProtocolVersion",3).put("serverID","incoming-skin-test")
        .put("authToken","private-fixture-token").put("gamepadProfiles",JSONArray().put(p.source)).put("gamepadProfileID",p.id.toString())
    private fun target(server:MockWebServer)=PairingTarget.manual("ws://127.0.0.1:${server.port}","123456")
    private fun await(label:String,condition:()->Boolean) {
        val limit=SystemClock.elapsedRealtime()+15_000
        while(!condition() && SystemClock.elapsedRealtime()<limit) SystemClock.sleep(20)
        assertTrue(label,condition())
    }
    private fun find(view:View):ControllerSurface? {
        if(view is ControllerSurface) return view
        if(view is ViewGroup) repeat(view.childCount) { find(view.getChildAt(it))?.let { return it } }
        return null
    }
    private fun replacement(bytes:ByteArray,marker:String):ByteArray {
        val files=linkedMapOf<String,ByteArray>()
        ZipInputStream(ByteArrayInputStream(bytes)).use { z -> while(true) { val e=z.nextEntry ?: break;files[e.name]=z.readBytes();z.closeEntry() } }
        val manifest=JSONObject(files.getValue("manifest.json").toString(Charsets.UTF_8));val path=manifest.getString("skinPath")
        val skin=JSONObject(files.getValue(path).toString(Charsets.UTF_8))
        val first=skin.getJSONObject("base").getJSONObject("styleLibrary").getJSONArray("styles").getJSONObject(0)
        val tokenID=first.getString("id");first.put("name",marker)
        val variants=skin.getJSONArray("variants")
        repeat(variants.length()) { index ->
            val styles=variants.getJSONObject(index).getJSONObject("appearance").optJSONObject("styleLibrary")?.optJSONArray("styles")
            if(styles!=null) repeat(styles.length()) { i -> styles.getJSONObject(i).takeIf { it.getString("id")==tokenID }?.put("name",marker) }
        }
        files[path]=skin.toString().toByteArray();manifest.put("skinSHA256",packageHash(files.getValue(path)));files["manifest.json"]=manifest.toString().toByteArray()
        val output=ByteArrayOutputStream()
        ZipOutputStream(output).use { z -> files.forEach { (name,data) -> z.putNextEntry(ZipEntry(name));z.write(data);z.closeEntry() } }
        return output.toByteArray()
    }
    @Test fun realSessionInstallsEmbeddedAndStandalonePackagesWithoutRetiringUnrelatedHoldAndRefreshesInactiveCache() {
        val context=instrumentation.targetContext;val library=SkinLibrary(File(context.filesDir,"skins"))
        val bytes=archive();val other=archive(otherName);val reference=SkinPackageCodec.decode(bytes).reference
        val references=listOf(reference,SkinPackageCodec.decode(other).reference)
        val backups=references.associateWith { runCatching { library.archiveFor(it) }.getOrNull() }
        references.forEach { if(backups[it]!=null) library.remove(it) }
        val p=profile();p.source.getJSONObject("customization").put("colorSchemePreference","light")
        p.source.put("skinReference",JSONObject().put("identifier",reference.identifier).put("version",reference.version))
        val second=ControllerProfile.parse(JSONObject(p.source.toString()).put("id",UUID.randomUUID().toString()).put("name","Unskinned").also { it.remove("skinReference") })
        val expectedLayout=SkinProfileResolver.apply(SkinPackageCodec.decode(bytes),p.layout(false),"portrait","light").customization
        val expectedProfile=ControllerProfile.parse(JSONObject(p.source.toString()).put("portraitCustomization",expectedLayout))
        val expectedFace=ControlPresentation.resolve(expectedProfile.controls(false).last(),expectedLayout,PresentationState.NORMAL,false)
        val store=MemorySessionStore();val prior=ClientDependencies.sessionStore;ClientDependencies.sessionStore={store}
        val peer=AtomicReference<WebSocket>();val downs=AtomicInteger();val releases=AtomicInteger()
        val server=MockWebServer()
        server.enqueue(MockResponse().withWebSocketUpgrade(object:WebSocketListener() {
            override fun onOpen(ws:WebSocket,response:Response) {
                peer.set(ws)
                val hello=accepted(p).put("gamepadProfiles",JSONArray().put(p.source).put(second.source))
                hello.put("skinPackages",packages("skin_packages",bytes).getJSONArray("skinPackages"));ws.send(hello.toString())
            }
            override fun onMessage(ws:WebSocket,text:String) { if(JSONObject(text).optString("type")=="release_all") releases.incrementAndGet() }
            override fun onMessage(ws:WebSocket,bytes:ByteString) {
                if(bytes.size==56 && bytes[0]==80.toByte() && bytes[21]==1.toByte()) downs.incrementAndGet()
                else if(bytes.size>0 && bytes[0]==123.toByte() && JSONObject(bytes.utf8()).optString("type")=="release_all") releases.incrementAndGet()
            }
        }));server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.connect(target(server)) }
            var session:ControllerSession?=null
            await("embedded package installed and surface rendered") {
                var ready=false
                scenario.onActivity { a ->
                    session=ViewModelProvider(a)[ControllerSession::class.java]
                    val surface=find(a.window.decorView)
                    val actual=surface?.takeIf { it.childCount>0 }?.let { it.getChildAt(it.childCount-1) as? ControlFaceView }?.appliedPresentation
                    ready=a.connectionState.paired && session!!.skinRevision>0 && sameSkinJSON(expectedFace,actual)
                }
                ready
            }
            assertArrayEquals(bytes,library.archiveFor(reference))
            val revision=AtomicReference<Long>();lateinit var held:View
            scenario.onActivity { a ->
                val surface=find(a.window.decorView)!!;held=surface.getChildAt(surface.childCount-1)
                val event=MotionEvent.obtain(0,SystemClock.uptimeMillis(),MotionEvent.ACTION_DOWN,held.left+held.width/2f,held.top+held.height/2f,0)
                surface.dispatchTouchEvent(event);event.recycle();assertTrue(held.isPressed);revision.set(session!!.skinRevision)
            }
            await("physical hold reached wire") { downs.get()>0 }
            val initialReleases=releases.get()
            peer.get().send(packages("skin_packages",bytes,other).toString())
            await("standalone unrelated package installed") { library.installed().any { it.reference==references[1] } }
            await("unrelated sync completion published") {
                var ready=false;scenario.onActivity { ready=session!!.skinSyncInFlight==0 && session!!.installedSkins.any { it.reference==references[1] } };ready
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertEquals(revision.get(),session!!.skinRevision);assertTrue("Unrelated package must preserve physical hold",held.isPressed)
            }
            assertEquals(initialReleases,releases.get())
            val updated=replacement(bytes,"Incoming active token")
            peer.get().send(packages("skin_packages","bad zip".toByteArray(),updated).toString())
            await("active replacement committed with independent failure") {
                var ready=false;scenario.onActivity { ready=session!!.skinRevision>revision.get() && session!!.skinError!=null && !held.isPressed };ready
            }
            await("replacement neutralized retired hold") { releases.get()>initialReleases }
            val replacementReleases=releases.get()
            assertArrayEquals(updated,library.archiveFor(reference))
            val selectedB=WireCodec.message("gamepad_profiles").put("gamepadProfiles",JSONArray().put(p.source).put(second.source)).put("gamepadProfileID",second.id.toString())
            peer.get().send(selectedB.toString())
            await("other profile selected") { var ready=false;scenario.onActivity { ready=it.connectionState.snapshot.selectedID==second.id };ready }
            session!!.skinRenderer.resolve(second,false,false)
            var inactiveRevision=0L;scenario.onActivity { inactiveRevision=session!!.skinRevision }
            val inactive=replacement(bytes,"Incoming inactive token")
            peer.get().send(packages("skin_packages",inactive).toString())
            await("inactive replacement installed") { runCatching { library.archiveFor(reference).contentEquals(inactive) }.getOrDefault(false) }
            await("inactive install completion published") { var ready=false;scenario.onActivity { ready=session!!.skinError==null };ready }
            scenario.onActivity { assertEquals(inactiveRevision,session!!.skinRevision) }
            val resolved=session!!.skinRenderer.resolve(p,false,false).profile!!.layout(false).getJSONObject("styleLibrary").getJSONArray("styles")
            assertTrue((0 until resolved.length()).any { resolved.getJSONObject(it).getString("name")=="Incoming inactive token" })
            scenario.onActivity { a -> assertTrue(a.connectionState.paired);find(a.window.decorView)?.cancelTouches() }
            File(context.getExternalFilesDir(null),"incoming-skin-result.json").writeText(JSONObject()
                .put("sdk",android.os.Build.VERSION.SDK_INT).put("embeddedArchiveSHA256",packageHash(bytes))
                .put("unrelatedAndExactResyncRetainHold",true).put("activeReplacementNeutralizesHold",true)
                .put("wireDownRefreshCount",downs.get()).put("releaseAllCountBeforeUnrelatedSync",initialReleases)
                .put("releaseAllCountAfterActiveReplacement",replacementReleases)
                .put("activeReplacementSHA256",packageHash(updated)).put("inactiveReplacementSHA256",packageHash(inactive))
                .put("invalidArchivePreservesConnectionAndOtherInstalls",true).put("inactiveCacheInvalidated",true)
                .put("normalMacSkinSyncVerified",false).toString(2))
        } } finally {
            ClientDependencies.sessionStore=prior;server.shutdown()
            references.forEach { ref -> val old=backups[ref];if(old==null) runCatching { library.remove(ref) } else library.install(old,SkinInstallPolicy.REPLACE_SAME_VERSION) }
        }
    }
    @Test fun unauthenticatedOrWrongIdentityPackagesCannotReachInstallation() {
        val offered=AtomicInteger();val state=AtomicReference(ClientState());val store=MemorySessionStore();val server=MockWebServer()
        server.enqueue(MockResponse().withWebSocketUpgrade(object:WebSocketListener() {
            override fun onOpen(ws:WebSocket,response:Response) {
                ws.send(packages("skin_packages",archive()).toString())
                val hello=accepted(profile());hello.put("skinPackages",packages("skin_packages",archive()).getJSONArray("skinPackages"));ws.send(hello.toString())
            }
        }));server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val client=ControllerClient(store,incomingSkins={offered.incrementAndGet();true}) { state.set(it) }
        try {
            client.connect(target(server).copy(serverID="different-expected-mac"))
            await("identity rejected") { state.get().error!=null }
            assertEquals(0,offered.get());assertFalse(state.get().paired);assertNull(store.loadMac());assertTrue(store.loadSnapshot().profiles.isEmpty())
        } finally { client.dispose();server.shutdown() }
    }
    @Test fun malformedTypedDataCannotCommitAnEmbeddedProfileSnapshot() {
        val offered=AtomicInteger();val state=AtomicReference(ClientState());val store=MemorySessionStore();val server=MockWebServer();val peer=AtomicReference<WebSocket>();val p=profile()
        server.enqueue(MockResponse().withWebSocketUpgrade(object:WebSocketListener() {
            override fun onOpen(ws:WebSocket,response:Response) { peer.set(ws);ws.send(accepted(p).toString()) }
        }));server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val client=ControllerClient(store,incomingSkins={offered.incrementAndGet();true}) { state.set(it) }
        try {
            client.connect(target(server));await("paired") { state.get().paired }
            val changed=JSONObject(p.source.toString()).put("name","Must not commit")
            peer.get().send(WireCodec.message("gamepad_profiles").put("gamepadProfiles",JSONArray().put(changed))
                .put("skinPackages",JSONArray().put(Base64.getEncoder().encodeToString(archive())).put(5)).toString())
            await("malformed Data rejected") { !state.get().paired && state.get().error!=null }
            assertEquals(0,offered.get());assertEquals(p.name,store.loadSnapshot().selected!!.name)
        } finally { client.dispose();server.shutdown() }
    }
    @Test fun workerBackpressureRetainsTrustAndReconnectsInsteadOfDroppingAValidBatch() {
        val state=AtomicReference(ClientState());val store=MemorySessionStore();val server=MockWebServer()
        server.enqueue(MockResponse().withWebSocketUpgrade(object:WebSocketListener() {
            override fun onOpen(ws:WebSocket,response:Response) {
                val hello=accepted(profile());hello.put("skinPackages",packages("skin_packages",archive()).getJSONArray("skinPackages"));ws.send(hello.toString())
            }
        }));server.start(java.net.InetAddress.getByName("127.0.0.1"),0)
        val client=ControllerClient(store,incomingSkins={false}) { state.set(it) }
        try {
            client.connect(target(server));await("bounded retry exposed") { state.get().error?.contains("Skin sync is busy")==true }
            assertFalse(state.get().paired);assertTrue(state.get().canReconnect);assertNotNull(store.loadMac())
        } finally { client.dispose();server.shutdown() }
    }
}
