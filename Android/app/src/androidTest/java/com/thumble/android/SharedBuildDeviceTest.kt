package com.thumble.android

import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.ext.junit.runners.AndroidJUnit4
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject
import org.erdtman.jcs.JsonCanonicalizer
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class SharedBuildDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private val context get()=instrumentation.targetContext
    private var flags=0
    private lateinit var directory: File
    private lateinit var memory: MemorySessionStore
    private lateinit var original: ControllerProfile
    private var previousStore: ((android.content.Context)->SessionStore)?=null
    private var previousBuilds: ((android.content.Context)->SharedBuildSession)?=null
    private fun profile(id: String,name: String,control: String)=ControllerProfile.parse(JSONObject().put("id",id).put("name",name).put("orientationPreference","portrait")
        .put("customization",JSONObject().put("deviceCanvas",JSONObject().put("frameID","iphone-17-pro-portrait")).put("elements",JSONArray().put(JSONObject().put("id",control).put("label","Practice button").put("kind","button").put("layout",JSONObject().put("centerX",.5).put("centerY",.5))))))
    private fun artifact(): ByteArray {
        val first=profile("00000000-0000-0000-0000-000000000201","Shared One","00000000-0000-0000-0000-000000000203")
        val second=profile("00000000-0000-0000-0000-000000000202","Shared Two","00000000-0000-0000-0000-000000000204")
        val raw=JSONObject().put("schema","com.codybontecou.pocketpad.keypad-configuration").put("version",4).put("artifactVersion",1).put("exportedAt",1000)
            .put("profiles",JSONArray().put(first.source).put(second.source)).put("activeProfileID",first.id.toString()).put("defaultProfileID",second.id.toString())
            .put("catalogRevision",JSONObject().put("controllerTemplates",1).put("deviceFrames",1).put("generationSpec",1))
        val content=JSONObject(raw.toString()).apply { remove("exportedAt") }
        return raw.put("contentHash",JSONObject().put("algorithm","sha256").put("canonicalization","rfc8785").put("value",packageHash(JsonCanonicalizer(content.toString()).encodedUTF8))).toString().toByteArray()
    }
    @Before fun setup() {
        val info=instrumentation.uiAutomation.serviceInfo;flags=info.flags
        info.flags=info.flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;instrumentation.uiAutomation.serviceInfo=info
        finishActivities();SharedBuildInbox.take()
        directory=File(context.noBackupFilesDir,"shared-build-test-${UUID.randomUUID()}")
        original=profile("00000000-0000-0000-0000-000000000311","Mac Original","00000000-0000-0000-0000-000000000312")
        memory=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(original),original.id,original.id)) }
        previousStore=ClientDependencies.sessionStore;previousBuilds=ClientDependencies.sharedBuildSession
        ClientDependencies.sessionStore={memory};ClientDependencies.sharedBuildSession={SharedBuildSession(directory.toPath(),localTesting=true)}
    }
    @After fun cleanup() {
        finishActivities();previousStore?.let { ClientDependencies.sessionStore=it };previousBuilds?.let { ClientDependencies.sharedBuildSession=it }
        directory.deleteRecursively();SharedBuildInbox.take()
        val info=instrumentation.uiAutomation.serviceInfo;info.flags=flags;instrumentation.uiAutomation.serviceInfo=info
    }
    private fun finishActivities() {
        instrumentation.runOnMainSync { Stage.values().flatMap { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it) }.distinct().filterIsInstance<MainActivity>().forEach { it.finish() } }
        instrumentation.waitForIdleSync()
    }
    private fun activity(): MainActivity? {
        var activity: MainActivity?=null
        instrumentation.runOnMainSync { activity=ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull() };return activity
    }
    private fun owner(): ControllerSession? {
        var owner: ControllerSession?=null
        instrumentation.runOnMainSync { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull()?.let { owner=ViewModelProvider(it)[ControllerSession::class.java] } };return owner
    }
    private fun await(label: String,test: ()->Boolean) {
        val until=SystemClock.elapsedRealtime()+20_000
        while(SystemClock.elapsedRealtime()<until) { if(test()) return;SystemClock.sleep(30) }
        screenshot("failed-"+label.replace(Regex("[^a-zA-Z0-9]+"),"-").take(50));fail(label)
    }
    private fun node(label: String): AccessibilityNodeInfo? {
        fun walk(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if(!n.refresh()) return null
            if(n.isVisibleToUser && (n.text?.toString()==label || n.contentDescription?.toString()==label)) return n
            repeat(n.childCount) { n.getChild(it)?.let { walk(it)?.let { return it } } };return null
        }
        val ui=instrumentation.uiAutomation
        return (listOfNotNull(ui.rootInActiveWindow)+ui.windows.filter { it.isActive || it.isFocused }.mapNotNull { it.root }).firstNotNullOfOrNull(::walk)
    }
    private fun click(label: String) {
        var previous: Rect?=null;var since=0L;var target: Rect?=null
        await("stable $label") {
            node(label)?.takeIf { it.isEnabled }?.let { n ->
                val rect=Rect();n.getBoundsInScreen(rect)
                if(rect!=previous) { previous=Rect(rect);since=SystemClock.elapsedRealtime() }
                if(!rect.isEmpty && SystemClock.elapsedRealtime()-since>250) { target=rect;true } else false
            } ?: false
        }
        val rect=target!!;val start=SystemClock.uptimeMillis()
        for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP)) {
            val e=MotionEvent.obtain(start,SystemClock.uptimeMillis(),action,rect.exactCenterX(),rect.exactCenterY(),0);e.source=InputDevice.SOURCE_TOUCHSCREEN
            assertTrue(instrumentation.uiAutomation.injectInputEvent(e,true));e.recycle()
        }
    }
    private fun screenshot(name: String) {
        // State assertions can finish before Material's dialog exit animation.
        // Settle only the evidence capture; assertions above still drive the test.
        instrumentation.waitForIdleSync();SystemClock.sleep(350)
        instrumentation.uiAutomation.takeScreenshot()?.let { b ->
        File(context.getExternalFilesDir(null),"shared-build-$name.png").outputStream().use { b.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) };b.recycle()
    } }
    private fun shell(command: String)=instrumentation.uiAutomation.executeShellCommand(command).use { fd -> java.io.FileInputStream(fd.fileDescriptor).use { it.readBytes().toString(Charsets.UTF_8) } }
    private fun link(server: MockWebServer)=server.url("/share/bar_"+"a".repeat(64)).toString()+"#token="+"b".repeat(64)
    private fun send(link: String) {
        // UiAutomation splits command arguments directly; shell quotes become literal URL bytes.
        // This helper accepts only the whitespace-free URLs produced by the local fixture.
        require(link.none { it.isWhitespace() || it == '\'' || it == '"' })
        val output=shell("am start -n com.thumble.android.test/com.thumble.android.testfixtures.SharedBuildSenderActivity --es link $link")
        assertFalse("External sender could not start: $output",output.contains("Error:"))
    }
    private fun response(bytes: ByteArray=artifact())=MockResponse().setHeader("Content-Type","application/json").setBody(okio.Buffer().write(bytes))

    @Test fun realRustReceiverAdoptsReviewedBuildAndConfirmsAuthoritativeCopies() {
        val qr=InstrumentationRegistry.getArguments().getString("adoptionPairingQR")
        org.junit.Assume.assumeTrue("Requires isolated native receiver",qr!=null)
        val target=PairingTarget.parse(qr!!)
        val normalServer=InstrumentationRegistry.getArguments().getString("normalAdoptionServerID")
        require(target.serverID?.startsWith("adoption-")==true || normalServer!=null && normalServer==target.serverID)
        val server=MockWebServer();server.start()
        try {
            shell("am start -n com.thumble.android/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER")
            await("controller ready") { activity()!=null }
            val main=activity()!!
            instrumentation.runOnMainSync { main.connect(target) }
            await("native adoption capability") { owner()?.state?.let { it.paired && ArtifactAdoptionMetadata.CAPABILITY in it.capabilities }==true }
            val controller=owner()!!;val before=controller.state.snapshot
            val preferences=memory.loadPreferences();val client=System.identityHashCode(controller.client)
            val bytes=artifact();File(context.getExternalFilesDir(null),"shared-build-adoption-artifact.json").writeBytes(bytes)
            server.enqueue(response(bytes));send(link(server))
            await("native build review") { node("Preview Shared Build")!=null }
            click("Preview & Keep")
            await("native build kept") { controller.state.sharedBuildPreview!=null && controller.sharedBuilds.records.size==1 }
            val record=controller.sharedBuilds.records.single()
            click("Shared One");click("Shared builds")
            click("Adopt shared build Shared One on Mac");screenshot("native-adoption-review")
            click("Add to Mac")
            await("native adoption terminal result") { controller.state.artifactAdoption?.let { it.phase==ArtifactAdoptionPhase.FAILED || it.phase==ArtifactAdoptionPhase.SUCCEEDED && controller.sharedBuilds.records.isEmpty() }==true }
            assertEquals("Native adoption error: ${controller.state.artifactAdoption?.errorCode}; local: ${controller.sharedBuilds.error}",ArtifactAdoptionPhase.SUCCEEDED,controller.state.artifactAdoption?.phase)
            val adoption=controller.state.artifactAdoption!!;val after=controller.state.snapshot
            assertEquals(before.profiles.size+2,after.profiles.size)
            assertEquals(before.defaultID,after.defaultID)
            assertEquals(2,adoption.destinationProfileIDs.size)
            assertEquals(adoption.destinationProfileIDs.first(),after.selectedID)
            assertTrue(adoption.destinationProfileIDs.none { id -> before.profiles.any { it.id==id } })
            assertNull(controller.state.sharedBuildPreview);assertEquals(preferences,memory.loadPreferences())
            assertEquals(client,System.identityHashCode(owner()!!.client));assertTrue(directory.listFiles().orEmpty().isEmpty())
            val metadata=adoption.metadata
            val evidence=JSONObject().put("operationID",metadata.operationID.toString()).put("recordID",record.id.toString())
                .put("serverID",metadata.serverID).put("contentHash",metadata.contentHash).put("rawSHA256",metadata.rawSHA256)
                .put("destinationProfileIDs",JSONArray(adoption.destinationProfileIDs.map { it.toString() }))
                .put("oldDefaultID",before.defaultID.toString()).put("sourceProfileCount",2)
            File(context.getExternalFilesDir(null),"shared-build-adoption-result.json").writeText(evidence.toString())
            File(context.getExternalFilesDir(null),"shared-build-adoption-artifact.json").writeBytes(bytes)
            screenshot("native-adoption-confirmed")
        } finally { server.shutdown() }
    }

    @Test fun incomingBuildReviewBypassesUnfinishedOnboardingWithoutMarkingItComplete() {
        val freshStore=object: SessionStore by memory {
            override fun loadOnboardingCompleted()=false
            override fun saveOnboardingCompleted() { error("Incoming shares must not complete setup") }
        }
        ClientDependencies.sessionStore={freshStore}
        val server=MockWebServer();server.start()
        try {
            server.enqueue(response());send(link(server))
            await("share review is available during first-run setup") { node("Preview Shared Build")!=null }
            await("setup preference loaded") { owner()?.state?.onboardingLoaded==true }
            assertFalse(owner()!!.state.onboardingCompleted)
            assertEquals(original.id,owner()!!.state.snapshot.selectedID)
            assertTrue(directory.listFiles().orEmpty().isEmpty())
        } finally { server.shutdown() }
    }

    @Test fun externalLinkReviewsKeepsPreviewsReloadsAndDeletesWithoutTouchingMacState() {
        val server=MockWebServer();server.start()
        try {
            val bytes=artifact();server.enqueue(response(bytes));send(link(server))
            await("external review") { owner()?.sharedBuilds?.review!=null && node("Preview Shared Build")!=null }
            assertSame(original,memory.loadSnapshot().selected);assertFalse(memory.loadPreferences().practiceMode)
            assertTrue(owner()!!.sharedBuilds.records.isEmpty());assertEquals(1,server.requestCount)
            val request=server.takeRequest();assertFalse(request.path.orEmpty().contains("token"));assertEquals("ThumbleShare "+"b".repeat(64),request.getHeader("Authorization"))
            assertNull(activity()!!.intent.data);assertFalse(activity()!!.intent.toString().contains("token="));screenshot("review")
            val client=System.identityHashCode(owner()!!.client)
            val currentActivity=activity()!!
            instrumentation.runOnMainSync { currentActivity.recreate() }
            await("retained review") { node("Preview Shared Build")!=null && owner()?.sharedBuilds?.review!=null }
            assertEquals(client,System.identityHashCode(owner()!!.client));assertEquals(1,server.requestCount)
            click("Preview & Keep");await("practice preview") { owner()?.state?.sharedBuildPreview!=null && node("Shared preview · input off")!=null }
            val record=owner()!!.sharedBuilds.records.single()
            assertArrayEquals(bytes,PendingSharedBuildStore(directory.toPath()).load(record.id).rawData())
            assertSame(original,memory.loadSnapshot().selected);assertEquals(original.id,memory.loadSnapshot().defaultID)
            assertFalse(memory.loadPreferences().practiceMode);assertTrue(memory.loadPendingLayoutEdits().isEmpty());screenshot("preview")
            click("Shared One");click("Shared Two · Default");await("second practice profile") { owner()?.state?.sharedBuildPreview?.snapshot?.selected?.name=="Shared Two" }
            assertSame(original,memory.loadSnapshot().selected);assertEquals(0L,owner()!!.state.webSocketFrames);assertEquals(0L,owner()!!.state.udpFrames)
            click("Close preview");await("preview closed") { owner()?.state?.sharedBuildPreview==null && node("Shared builds")!=null }
            click("Shared builds");await("kept record") { node("Preview Shared One")!=null }
            click("Preview Shared One");await("kept preview reopened") { node("Shared preview · input off")!=null }
            click("Shared One");click("Shared builds");await("library over active preview") { node("Delete shared build Shared One")!=null }
            click("Delete shared build Shared One");click("Delete build");await("deleted") { owner()?.sharedBuilds?.records?.isEmpty()==true && owner()?.state?.sharedBuildPreview==null }
            assertSame(original,memory.loadSnapshot().selected);assertFalse(memory.loadPreferences().practiceMode)
            assertTrue(directory.listFiles().orEmpty().isEmpty());screenshot("deleted")
        } finally { server.shutdown() }
    }
    @Test fun cancelAndUnsafeResponsesDoNotLeavePendingDataOrReplayBearerLinks() {
        val server=MockWebServer();server.start()
        try {
            server.enqueue(response());send(link(server));await("cancel review ready") { node("Preview Shared Build")!=null }
            click("Cancel");assertTrue(owner()!!.sharedBuilds.records.isEmpty())
            val currentActivity=activity()!!
            instrumentation.runOnMainSync { currentActivity.recreate() }
            await("recreated library") { node("Shared builds")!=null && owner()!=null }
            assertNull(owner()!!.sharedBuilds.review);assertEquals(1,server.requestCount)
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location","http://127.0.0.1:1/stolen"));send(link(server))
            await("unsafe response message") { owner()?.sharedBuilds?.error?.contains("unsafe response")==true }
            assertEquals(2,server.requestCount);assertTrue(owner()!!.sharedBuilds.records.isEmpty());assertSame(original,memory.loadSnapshot().selected);screenshot("unsafe-response")
        } finally { server.shutdown() }
    }
    @Test fun newExternalShareCancelsAnOlderFetchWithoutReplacingTheController() {
        val server=MockWebServer();server.start()
        try {
            server.enqueue(MockResponse().setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.NO_RESPONSE));send(link(server))
            await("first download active") { owner()?.sharedBuilds?.fetching==true && server.requestCount==1 }
            val client=System.identityHashCode(owner()!!.client);val main=System.identityHashCode(activity()!!)
            server.enqueue(response());val newer=link(server).replace("bar_"+"a".repeat(64),"bar_"+"c".repeat(64));send(newer)
            await("new share reviewed") { owner()?.sharedBuilds?.review?.artifactID=="bar_"+"c".repeat(64) && !owner()!!.sharedBuilds.fetching }
            assertEquals(2,server.requestCount);assertEquals(client,System.identityHashCode(owner()!!.client));assertEquals(main,System.identityHashCode(activity()!!))
            assertTrue(owner()!!.sharedBuilds.records.isEmpty());assertSame(original,memory.loadSnapshot().selected)
        } finally { server.shutdown() }
    }
    @Test fun keptBuildReloadsInANewControllerSessionWithoutAutomaticallyEnteringPreview() {
        val server=MockWebServer();server.start()
        try {
            val bytes=artifact();server.enqueue(response(bytes));send(link(server))
            await("reload review") { node("Preview Shared Build")!=null }
            click("Preview & Keep");await("reload initial preview") { owner()?.state?.sharedBuildPreview!=null }
            val oldOwner=owner()!!;val record=oldOwner.sharedBuilds.records.single()
            finishActivities()
            shell("am start -n com.thumble.android/.MainActivity -a android.intent.action.MAIN -c android.intent.category.LAUNCHER")
            await("new controller session") { owner()?.let { it!==oldOwner && it.sharedBuilds.records.size==1 }==true }
            assertNull(owner()!!.state.sharedBuildPreview);assertNull(owner()!!.sharedBuilds.review)
            assertFalse(memory.loadPreferences().practiceMode);assertSame(original,memory.loadSnapshot().selected)
            assertEquals(record,owner()!!.sharedBuilds.records.single());assertEquals(1,server.requestCount)
            assertNull(activity()!!.intent.data)
            click("Shared builds");click("Preview Shared One")
            await("reloaded practice preview") { owner()?.state?.sharedBuildPreview?.recordID==record.id }
            assertArrayEquals(bytes,PendingSharedBuildStore(directory.toPath()).load(record.id).rawData())
            assertEquals(0L,owner()!!.state.webSocketFrames);assertEquals(0L,owner()!!.state.udpFrames)
        } finally { server.shutdown() }
    }
    @Test fun failedKeepRetainsReviewAndNeverStartsAPreviewOrChangesMacState() {
        val server=MockWebServer();server.start()
        try {
            server.enqueue(response());send(link(server));await("failed keep review") { node("Preview Shared Build")!=null }
            val review=owner()!!.sharedBuilds.review!!
            // Replace the already-created quarantine directory with a regular file.
            // This exercises a real Android filesystem failure without a fake store.
            assertTrue(directory.deleteRecursively());directory.writeText("storage unavailable")
            click("Preview & Keep")
            await("failed keep retained") { owner()?.sharedBuilds?.let { !it.busy && it.error!=null }==true }
            assertSame(review,owner()!!.sharedBuilds.review);assertTrue(owner()!!.sharedBuilds.records.isEmpty())
            assertNull(owner()!!.state.sharedBuildPreview);assertTrue(directory.isFile)
            assertSame(original,memory.loadSnapshot().selected);assertFalse(memory.loadPreferences().practiceMode)
            assertTrue(memory.loadPendingLayoutEdits().isEmpty());assertTrue(memory.loadPendingAppearancePreferences().isEmpty())
            assertEquals(1,server.requestCount);assertNotNull(node("Preview Shared Build"));screenshot("failed-keep-retained")
            click("Cancel");assertNull(owner()!!.sharedBuilds.review)
        } finally { server.shutdown() }
    }
    @Test fun manifestRoutesOnlyTheProductionSharePathToTheTransientEntry() {
        // Inspect our declared host/path filters independently of the device's
        // verified-link defaults. Production browser association has its own acceptance gate.
        fun entries(url: String)=context.packageManager.queryIntentActivities(android.content.Intent(android.content.Intent.ACTION_VIEW,android.net.Uri.parse(url))
            .setPackage(context.packageName).addCategory(android.content.Intent.CATEGORY_BROWSABLE),android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
            .filter { it.activityInfo.packageName==context.packageName }.map { it.activityInfo.name }
        val prefix="https://${BuilderArtifactShare.HOST}"
        assertEquals(listOf("com.thumble.android.SharedBuildLinkActivity"),entries(prefix+"/share/bar_"+"a".repeat(64)+"#token="+"b".repeat(64)))
        assertTrue(entries("https://example.com/share/other").isEmpty());assertTrue(entries(prefix+"/unrelated").isEmpty())
    }
    @Test fun realAndroidCanonicalizerAndProtectedStoreMatchNativeFixtureAndDetectTampering() {
        val bytes=instrumentation.context.assets.open("profile-artifact/v1.json").use { it.readBytes() }
        val artifact=PortableProfileArtifact.decode(bytes);val store=PendingSharedBuildStore(directory.toPath());val record=store.save(artifact)
        val reloaded=PendingSharedBuildStore(directory.toPath());assertArrayEquals(bytes,reloaded.load(record.id).rawData())
        assertEquals(artifact.contentHash,reloaded.list().single().contentHash)
        File(directory,"${record.id}.artifact.json").writeText("{}")
        assertTrue(runCatching { reloaded.load(record.id) }.isFailure);assertTrue(reloaded.list().isEmpty())
    }
    @Test fun livePracticePreviewSuppressesAllInputAndRestoresTheLatestMacSnapshot() {
        val other=profile("00000000-0000-0000-0000-000000000321","Other Mac","00000000-0000-0000-0000-000000000322")
        original=ControllerProfile.parse(JSONObject(original.source.toString()).put("launchTarget",JSONObject().put("kind","application").put("displayName","Fixture app")))
        val server=MockWebServer();val wire=CopyOnWriteArrayList<ByteArray>();val peer=AtomicReference<WebSocket>()
        fun snapshot(type: String,p: ControllerProfile)=WireCodec.message(type).put("gamepadProfiles",JSONArray().put(p.source).put(other.source)).put("gamepadProfileID",p.id.toString()).put("defaultGamepadProfileID",p.id.toString())
        server.enqueue(MockResponse().withWebSocketUpgrade(object: WebSocketListener() {
            override fun onOpen(webSocket: WebSocket,response: Response) { peer.set(webSocket) }
            override fun onMessage(socket: WebSocket,bytes: ByteString) { wire.add(bytes.toByteArray()) }
            override fun onMessage(socket: WebSocket,text: String) {
                if(JSONObject(text).optString("type")=="hello") socket.send(snapshot("pairing_accepted",original).put("inputProtocolVersion",3).put("serverID","shared-preview-mac").put("authToken","fixture-only").put("capabilities",JSONArray().put(ProfileActions.ORIENTATION_CAPABILITY)).toString())
                else wire.add(text.toByteArray())
            }
        }));server.start(InetAddress.getByName("127.0.0.1"),0)
        val state=AtomicReference(ClientState());val client=ControllerClient(memory) { state.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"));await("paired") { state.get().paired }
            val button=original.controls(false).first().id
            client.edge(button,true,1,state.get().surfaceRevision);await("held input") { wire.any { it.size==56 } }
            val before=wire.size;val preview=PortableProfileArtifact.decode(artifact()).profileSnapshot()
            client.beginSharedBuildPreview(UUID.randomUUID(),preview)
            await("release before preview") { state.get().sharedBuildPreview!=null && wire.drop(before).any { runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("type")=="release_all" }.getOrDefault(false) } }
            fun changes()=wire.count { bytes -> runCatching { JSONObject(bytes.toString(Charsets.UTF_8)).optString("type") !in setOf("heartbeat","release_all") }.getOrDefault(true) }
            val input=changes()
            client.edge(button,true,2,state.get().surfaceRevision);client.stick("left",1.0,1.0,true,state.get().surfaceRevision);client.pointer("move",2.0,1.0,null,null,state.get().surfaceRevision)
            client.setDefaultProfile(other.id);client.setOrientationPreference("landscape");client.launchProfileTarget();client.setAppearancePreference(AppearancePreference.DARK)
            client.beginLayoutEditing(original.id,LayoutOrientation.PORTRAIT);client.setPracticeMode(true)
            client.selectProfile(preview.profiles[1].id);await("local preview selection") { state.get().sharedBuildPreview?.snapshot?.selectedID==preview.profiles[1].id }
            SystemClock.sleep(400);assertEquals(input,changes());assertFalse(state.get().layoutEditing);assertFalse(memory.loadPreferences().practiceMode)
            assertTrue(memory.loadPendingAppearancePreferences().isEmpty());assertTrue(memory.loadPendingLayoutEdits().isEmpty())
            val newer=ControllerProfile.parse(JSONObject(original.source.toString()).put("name","Mac updated during preview"))
            peer.get().send(snapshot("gamepad_profiles",newer).toString());await("new authority retained") { state.get().snapshot.selected?.name==newer.name }
            assertEquals("Shared Two",state.get().sharedBuildPreview!!.snapshot.selected!!.name)
            client.endSharedBuildPreview();await("latest authority restored") { state.get().sharedBuildPreview==null && state.get().snapshot.selected?.name==newer.name }
            assertEquals(original.id,memory.loadSnapshot().defaultID);assertFalse(memory.loadPreferences().practiceMode)
            client.edge(button,true,3,state.get().surfaceRevision);await("input resumes after close") { changes()>input }
        } finally { client.dispose();server.shutdown() }
    }
}
