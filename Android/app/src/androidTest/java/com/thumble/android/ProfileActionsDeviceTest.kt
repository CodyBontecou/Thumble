package com.thumble.android

import android.os.SystemClock
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
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference
import java.io.File
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario

@RunWith(AndroidJUnit4::class)
class ProfileActionsDeviceTest {
    /** Invoked only by verify-profile-actions.py against its private Rust receiver. */
    @Test fun optionalRustProfileActionsInterop() {
        val qr=InstrumentationRegistry.getArguments().getString("profileActionsPairingQR")
        org.junit.Assume.assumeTrue("Provide private Rust profile-action pairing data",qr != null)
        val state=AtomicReference(ClientState());val client=ControllerClient { state.set(it) }
        try {
            client.connect(PairingTarget.parse(qr!!))
            await("Rust profile fixture paired") { state.get().paired || state.get().error != null }
            assertTrue(state.get().error,state.get().paired)
            assertTrue(ProfileActions.ORIENTATION_CAPABILITY in state.get().capabilities)
            assertEquals(2,state.get().snapshot.profiles.size)
            val selected=state.get().snapshot.selectedID
            val other=state.get().snapshot.profiles.first { it.id != selected }.id
            client.setDefaultProfile(other)
            await("Rust authoritative default") { state.get().snapshot.defaultID == other }
            for (preference in listOf("portrait","landscape","automatic")) {
                client.setOrientationPreference(preference)
                await("Rust authoritative orientation: $preference") { state.get().snapshot.selected?.orientationPreference == preference }
                assertEquals(selected,state.get().snapshot.selectedID)
            }
            assertTrue(state.get().paired)
        } finally { client.disconnect();client.dispose() }
    }
    /** The script checks real fixture execution and host completion independently. */
    @Test fun optionalRustApplicationLaunchInterop() {
        val qr=InstrumentationRegistry.getArguments().getString("applicationLaunchPairingQR")
        org.junit.Assume.assumeTrue("Provide private application-launch receiver pairing data",qr != null)
        val state=AtomicReference(ClientState());val client=ControllerClient { state.set(it) }
        try {
            client.connect(PairingTarget.parse(qr!!))
            await("Rust launch fixture paired") { state.get().paired || state.get().error != null }
            assertTrue(state.get().error,state.get().paired)
            assertEquals("Android launch acceptance",state.get().snapshot.selected?.name)
            assertEquals("Launch fixture",state.get().snapshot.selected?.launchTargetName)
            val held = state.get().snapshot.selected!!.controls(false).first { it.kind == "button" }
            client.edge(held.id, true, 73L, state.get().surfaceRevision)
            SystemClock.sleep(300)
            client.launchProfileTarget()
            SystemClock.sleep(1500)
            assertTrue("Application launch must preserve the paired connection",state.get().paired)
            assertNull(state.get().error)
        } finally { client.disconnect();client.dispose() }
    }
    private fun profile(): JSONObject = JSONObject(InstrumentationRegistry.getInstrumentation().context.assets
        .open("controller-templates/v1/productivityStarter.json").bufferedReader().use { it.readText() }).getJSONObject("profile")
        .put("orientationPreference","automatic").put("launchTarget",JSONObject().put("kind","application").put("displayName","Example"))
    private fun await(label: String,condition: ()->Boolean) {
        val deadline=SystemClock.elapsedRealtime()+10_000
        while (!condition() && SystemClock.elapsedRealtime()<deadline) SystemClock.sleep(20)
        assertTrue(label,condition())
    }
    @Test fun nativeClientWaitsForAuthoritativeDefaultsAndOrientationAndGatesUnsupportedOrOfflineActions() {
        val first=profile();val second=profile().put("id",UUID.randomUUID().toString()).put("name","Second")
        val firstID=UUID.fromString(first.getString("id"));val secondID=UUID.fromString(second.getString("id"))
        fun snapshot(type: String,default: UUID,rotation: Boolean) = WireCodec.message(type)
            .put("inputProtocolVersion",3).put("gamepadProfiles",JSONArray().put(first).put(second))
            .put("gamepadProfileID",firstID.toString()).put("defaultGamepadProfileID",default.toString())
            .put("capabilities",JSONArray().apply { if (rotation) put(ProfileActions.ORIENTATION_CAPABILITY) })
        val wire=CopyOnWriteArrayList<JSONObject>();val peer=AtomicReference<WebSocket>()
        val server=MockWebServer()
        server.enqueue(MockResponse().withWebSocketUpgrade(object: WebSocketListener() {
            override fun onOpen(webSocket: WebSocket,response: Response) { peer.set(webSocket) }
            override fun onMessage(webSocket: WebSocket,text: String) {
                val message=JSONObject(text)
                if (message.optString("type") == "hello") webSocket.send(snapshot("pairing_accepted",firstID,true).toString())
                else wire.add(message)
            }
        }))
        server.start(InetAddress.getByName("127.0.0.1"),0)
        val store=MemorySessionStore();val state=AtomicReference(ClientState())
        val client=ControllerClient(store) { state.set(it) }
        fun count(type: String)=wire.count { it.optString("type") == type }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"))
            await("paired with default metadata") { state.get().paired && state.get().snapshot.defaultID == firstID }
            client.setDefaultProfile(secondID)
            await("default request") { count("gamepad_default_profile") == 1 }
            assertEquals(firstID,state.get().snapshot.defaultID)
            assertEquals(secondID.toString().uppercase(),wire.first { it.optString("type") == "gamepad_default_profile" }.getString("defaultGamepadProfileID"))
            peer.get().send(snapshot("gamepad_profiles",secondID,true).toString())
            await("authoritative default persisted") { state.get().snapshot.defaultID == secondID }
            assertEquals(secondID,store.loadSnapshot().defaultID)
            client.setOrientationPreference("portrait")
            await("orientation request") { count(ProfileActions.ORIENTATION_CAPABILITY) == 1 }
            assertEquals("automatic",state.get().snapshot.selected!!.orientationPreference)
            first.put("orientationPreference","portrait")
            peer.get().send(snapshot("gamepad_profiles",secondID,false).toString())
            await("orientation applied and capability withdrawn") { state.get().snapshot.selected?.orientationPreference == "portrait" && state.get().capabilities.isEmpty() }
            client.setOrientationPreference("landscape")
            client.setHapticIntensity(.25)
            await("queue drained") { state.get().hapticIntensity == .25 }
            assertEquals(1,count(ProfileActions.ORIENTATION_CAPABILITY))
            client.launchProfileTarget()
            await("launch uses selected profile") { count("launch_profile_target") == 1 }
            assertEquals(firstID.toString().uppercase(),wire.first { it.optString("type") == "launch_profile_target" }.getString("gamepadProfileID"))
            client.setPracticeMode(true)
            await("practice active") { state.get().practiceMode }
            client.launchProfileTarget()
            await("ordinary practice still permits explicit Mac launch, matching iOS") { count("launch_profile_target") == 2 }
            peer.get().send(WireCodec.message("error").put("message","Fixture host rejected the profile request").toString())
            await("host rejection is visible") { !state.get().paired && state.get().error == "Fixture host rejected the profile request" }
            client.setDefaultProfile(firstID);client.setOrientationPreference("landscape");client.launchProfileTarget()
            client.setHapticIntensity(.75)
            await("offline request queue drained") { state.get().hapticIntensity == .75 }
            assertEquals(1,count("gamepad_default_profile"));assertEquals(2,count("launch_profile_target"))
            assertEquals(secondID,store.loadSnapshot().defaultID)
        } finally { client.dispose();server.shutdown() }
    }
    @Test fun offlineDefaultUpdatesOnlyTheSavedSnapshotAndPreservesSelection() {
        val first=ControllerProfile.parse(profile());val second=ControllerProfile.parse(profile().put("id",UUID.randomUUID().toString()))
        val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(first,second),first.id,first.id)) }
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            await("saved snapshot loaded") { state.get().snapshot.defaultID == first.id }
            client.viewSavedKeypad()
            await("offline practice") { state.get().viewingSaved && state.get().practiceMode && !state.get().paired }
            client.setDefaultProfile(second.id)
            await("local default saved") { state.get().snapshot.defaultID == second.id }
            assertEquals(second.id,store.loadSnapshot().defaultID)
            assertEquals(first.id,state.get().snapshot.selectedID)
        } finally { client.dispose() }
    }
    @Test fun defaultMetadataSurvivesPrivateSnapshotReload() {
        val context=InstrumentationRegistry.getInstrumentation().targetContext
        val namespace="profile-actions-test-${UUID.randomUUID()}"
        val store=AndroidSessionStore(context,namespace)
        try {
            val p=ControllerProfile.parse(profile())
            store.saveSnapshot(ProfileSnapshot(listOf(p),p.id,p.id))
            assertEquals(p.id,AndroidSessionStore(context,namespace).loadSnapshot().defaultID)
        } finally { store.forgetMac();File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
    @Test fun offlineProfileMenuShowsTheSavedDefaultAndDisablesHostOnlyMutations() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val p=ControllerProfile.parse(profile())
        val store=MemorySessionStore().apply { saveSnapshot(ProfileSnapshot(listOf(p),p.id,p.id)) }
        val previous=ClientDependencies.sessionStore;ClientDependencies.sessionStore={ store }
        fun node(text: String): AccessibilityNodeInfo? {
            fun find(value: AccessibilityNodeInfo): AccessibilityNodeInfo? {
                if (value.text?.toString() == text || value.contentDescription?.toString() == text) return value
                for (index in 0 until value.childCount) value.getChild(index)?.let { child -> find(child)?.let { return it } }
                return null
            }
            return instrumentation.uiAutomation.rootInActiveWindow?.let(::find)
        }
        fun actionAncestor(value: AccessibilityNodeInfo): AccessibilityNodeInfo {
            var current=value
            while (!current.isClickable && current.parent != null) current=current.parent
            return current
        }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.showSavedKeypad() }
            await("saved controller appears") { node(p.name) != null }
            assertTrue(actionAncestor(node(p.name)!!).performAction(AccessibilityNodeInfo.ACTION_CLICK))
            await("profile actions menu appears") { node("Default keypad") != null }
            for (label in listOf("Default keypad","Automatic rotation","Portrait only","Landscape only","Launch Example on Mac")) {
                val item=node(label)
                assertNotNull("menu item: $label",item)
                assertFalse("offline host mutation disabled: $label",actionAncestor(item!!).isEnabled)
            }
            assertNotNull(node(p.name+" · Default"))
            instrumentation.uiAutomation.waitForIdle(200,5_000)
            assertEquals("capture must belong to the tested app","com.thumble.android",
                instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString())
            instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
                File(instrumentation.targetContext.cacheDir,"profile-actions-offline.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG,100,it) }
                bitmap.recycle()
            }
            scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore=previous }
    }
}
