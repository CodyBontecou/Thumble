package com.thumble.android

import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import java.io.File
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(AndroidJUnit4::class)
class AppearancePreferenceDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun profile(): ControllerProfile = ControllerProfile.parse(JSONObject(instrumentation.context.assets
        .open("controller-templates/v1/productivityStarter.json").bufferedReader().use { it.readText() }).getJSONObject("profile"))
    private fun snapshot(profile: ControllerProfile) = ProfileSnapshot(listOf(profile),profile.id,profile.id)
    private fun await(description: String, condition: ()->Boolean) {
        val deadline=SystemClock.elapsedRealtime()+12_000
        while(!condition() && SystemClock.elapsedRealtime()<deadline) SystemClock.sleep(20)
        assertTrue(description,condition())
    }
    @Test fun offlineAppearanceSurvivesClientRestartAndSkinSaves() {
        val context=instrumentation.targetContext
        val namespace="appearance-device-${UUID.randomUUID()}"
        val store=AndroidSessionStore(context,namespace)
        val state=AtomicReference(ClientState())
        val original=profile()
        store.saveSnapshot(snapshot(original))
        store.saveMac(TrustedMac("appearance-mac","fixture-private-token",listOf("ws://127.0.0.1:1")))
        var client=ControllerClient(store) { state.set(it) }
        try {
            client.viewSavedKeypad();await("offline keypad") { state.get().viewingSaved }
            val revision=state.get().surfaceRevision
            client.setAppearancePreference(AppearancePreference.DARK)
            await("appearance saved") { state.get().pendingAppearanceChanges==1 }
            assertTrue(state.get().surfaceRevision>revision)
            assertEquals(AppearancePreference.DARK,AppearancePreference.forProfile(state.get().snapshot.selected!!))
            client.dispose()
            val reloaded=AndroidSessionStore(context,namespace)
            assertEquals(1,reloaded.loadPendingAppearancePreferences().size)
            reloaded.saveSkinState(reloaded.loadSnapshot(),emptyList())
            client=ControllerClient(reloaded) { state.set(it) }
            client.viewSavedKeypad();await("appearance restored") {
                state.get().viewingSaved && state.get().pendingAppearanceChanges==1 &&
                    AppearancePreference.forProfile(state.get().snapshot.selected!!)==AppearancePreference.DARK
            }
            assertEquals(original.id,state.get().snapshot.selectedID)
            client.forgetMac();await("forgotten") { state.get().status=="Mac forgotten" }
            assertTrue(reloaded.loadPendingAppearancePreferences().isEmpty())
        } finally { client.dispose();store.forgetMac();File(context.noBackupFilesDir,namespace).deleteRecursively() }
    }
    @Test fun authoritativeEchoClearsIntentAndReconnectSnapshotCannotDiscardIt() {
        val server=MockWebServer()
        val peer=AtomicReference<WebSocket>()
        val requests=CopyOnWriteArrayList<JSONObject>()
        val wire=CopyOnWriteArrayList<ByteArray>()
        val original=profile()
        fun incoming(p: ControllerProfile,type: String="gamepad_profiles") = WireCodec.message(type)
            .put("gamepadProfiles",JSONArray().put(p.source)).put("gamepadProfileID",p.id.toString())
        server.enqueue(MockResponse().withWebSocketUpgrade(object: WebSocketListener() {
            override fun onOpen(webSocket: WebSocket,response: okhttp3.Response) { peer.set(webSocket) }
            override fun onMessage(webSocket: WebSocket,bytes: ByteString) { wire.add(bytes.toByteArray()) }
            override fun onMessage(webSocket: WebSocket,text: String) {
                val request=JSONObject(text)
                if(request.optString("type")=="hello") webSocket.send(incoming(original,"pairing_accepted")
                    .put("inputProtocolVersion",3).put("serverID","appearance-mac").put("authToken","fixture-private-token")
                    .put("capabilities",JSONArray().put(ProfileActions.ORIENTATION_CAPABILITY)).toString())
                else if(request.optString("type")=="gamepad_customization") requests.add(request)
            }
        }))
        server.start(InetAddress.getByName("127.0.0.1"),0)
        val memory=MemorySessionStore().apply {
            saveSnapshot(snapshot(original));saveMac(TrustedMac("appearance-mac","fixture-private-token",listOf("ws://127.0.0.1:${server.port}")))
        }
        val failAcknowledgement=AtomicBoolean(false)
        val store=object: SessionStore by memory {
            override fun saveProfileState(snapshot: ProfileSnapshot,skins: List<PendingSkinSelection>,appearance: List<PendingAppearancePreference>) {
                if(failAcknowledgement.get()) throw java.io.IOException("fixture ACK disk failure")
                memory.saveProfileState(snapshot,skins,appearance)
            }
        }
        val state=AtomicReference(ClientState())
        val client=ControllerClient(store) { state.set(it) }
        try {
            client.viewSavedKeypad();await("offline") { state.get().viewingSaved }
            client.setAppearancePreference(AppearancePreference.DARK)
            await("pending") { state.get().pendingAppearanceChanges==1 }
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"))
            await("paired and uploaded") { state.get().paired && requests.isNotEmpty() }
            assertEquals("dark",requests.last().getJSONObject("gamepadCustomization").getString("colorSchemePreference"))
            assertEquals(original.id,UUID.fromString(requests.last().getString("gamepadProfileID")))
            assertEquals(1,store.loadPendingAppearancePreferences().size)
            val renamed=ControllerProfile.parse(JSONObject(original.source.toString()).put("name","Renamed on Mac"))
            peer.get().send(incoming(renamed).toString())
            await("new metadata retained") { state.get().snapshot.selected?.name=="Renamed on Mac" }
            assertEquals(AppearancePreference.DARK,AppearancePreference.forProfile(state.get().snapshot.selected!!))
            assertEquals(1,state.get().pendingAppearanceChanges)
            val authoritative=ControllerProfile.parse(JSONObject(renamed.source.toString()).apply {
                getJSONObject("customization").put("colorSchemePreference","dark")
            })
            await("reconciled upload") { requests.size>=2 }
            val beforeEcho=requests.size
            val scalar=WireCodec.message("gamepad_customization").put("gamepadProfileID",original.id.toString())
                .put("gamepadCustomization",authoritative.source.getJSONObject("customization"))
            failAcknowledgement.set(true)
            peer.get().send(scalar.toString())
            await("acknowledgement save failure") { state.get().error?.contains("could not save your keypad")==true }
            assertEquals(1,state.get().pendingAppearanceChanges)
            assertEquals(1,store.loadPendingAppearancePreferences().size)
            SystemClock.sleep(400)
            assertEquals("failed disk acknowledgement must not create a wire loop",beforeEcho,requests.size)
            failAcknowledgement.set(false)
            peer.get().send(scalar.toString())
            await("acknowledged") { state.get().pendingAppearanceChanges==0 }
            assertTrue(store.loadPendingAppearancePreferences().isEmpty())
            assertEquals("Renamed on Mac",store.loadSnapshot().selected!!.name)
            client.setPracticeMode(false)
            await("live input enabled for mock-wire hold") { !state.get().practiceMode }
            val oldRevision=state.get().surfaceRevision
            val control=state.get().snapshot.selected!!.controls(false).first { it.kind=="button" }.id
            client.edge(control,true,123,oldRevision)
            await("held edge on wire") { wire.any { it.size==56 } }
            val beforeChoice=wire.size
            client.setAppearancePreference(AppearancePreference.LIGHT)
            await("live appearance releases hold") {
                state.get().surfaceRevision>oldRevision && requests.last().getJSONObject("gamepadCustomization").optString("colorSchemePreference")=="light" &&
                    wire.drop(beforeChoice).any { runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("type")=="release_all" }.getOrDefault(false) }
            }
            val buttonCount=wire.count { it.size==56 }
            client.edge(control,true,124,oldRevision)
            SystemClock.sleep(400)
            assertEquals("retired surface and refreshes cannot recreate old hold",buttonCount,wire.count { it.size==56 })
            val light=ControllerProfile.parse(JSONObject(authoritative.source.toString()).apply {
                getJSONObject("customization").put("colorSchemePreference","light")
            })
            peer.get().send(incoming(light).toString())
            await("live appearance acknowledged") { state.get().pendingAppearanceChanges==0 }
        } finally { client.dispose();server.shutdown() }
    }
    @Test fun realRustReceiverPersistsAndAcknowledgesBothAppearanceChoices() {
        val qr=InstrumentationRegistry.getArguments().getString("appearancePairingQR")
        assumeTrue("Requires a private Rust receiver fixture",qr!=null)
        val target=PairingTarget.parse(qr!!)
        val main=profile()
        val inactive=ControllerProfile.parse(JSONObject(instrumentation.context.assets
            .open("controller-templates/v1/gameBoy.json").bufferedReader().use { it.readText() }).getJSONObject("profile")
            .put("id","4FD20F4A-3C83-40B5-87C0-64512F4AC925"))
        val edit=PendingAppearancePreference.create(inactive,AppearancePreference.DARK,System.currentTimeMillis(),target.serverID)
        val state=AtomicReference(ClientState())
        val store=MemorySessionStore().apply {
            savePreferences(ClientPreferences(practiceMode=true))
            saveProfileState(ProfileSnapshot(listOf(main,AppearancePreferenceJournal.applying(inactive,edit)),main.id,main.id),emptyList(),listOf(edit))
        }
        val client=ControllerClient(store) { state.set(it) }
        try {
            client.connect(target)
            await("real receiver paired") { state.get().paired }
            await("inactive appearance acknowledged without changing selection") {
                state.get().pendingAppearanceChanges==0 && state.get().snapshot.selectedID==main.id &&
                    state.get().snapshot.profiles.firstOrNull { it.id==inactive.id }?.let { AppearancePreference.forProfile(it)==AppearancePreference.DARK }==true
            }
            assertEquals(AppearancePreference.SYSTEM,AppearancePreference.forProfile(state.get().snapshot.selected!!))
            val id=state.get().snapshot.selectedID
            assertTrue(ProfileActions.ORIENTATION_CAPABILITY in state.get().capabilities)
            for(choice in listOf(AppearancePreference.DARK,AppearancePreference.LIGHT)) {
                client.setAppearancePreference(choice)
                await("real receiver acknowledged ${choice.wireValue}") {
                    state.get().paired && state.get().pendingAppearanceChanges==0 &&
                        state.get().snapshot.selected?.let { AppearancePreference.forProfile(it)==choice }==true &&
                        store.loadPendingAppearancePreferences().isEmpty()
                }
                assertEquals(id,state.get().snapshot.selectedID)
                assertEquals(choice,AppearancePreference.forProfile(store.loadSnapshot().selected!!))
            }
            assertTrue(state.get().practiceMode)
        } finally { client.dispose() }
    }
    @Test fun failedSaveKeepsAppearanceAndJournalUnchanged() {
        val original=profile()
        val memory=MemorySessionStore().apply { saveSnapshot(snapshot(original)) }
        val store=object: SessionStore by memory {
            override fun saveProfileState(snapshot: ProfileSnapshot,skins: List<PendingSkinSelection>,appearance: List<PendingAppearancePreference>) {
                throw java.io.IOException("fixture disk failure")
            }
        }
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            client.viewSavedKeypad();await("offline") { state.get().viewingSaved }
            val previous=AppearancePreference.forProfile(state.get().snapshot.selected!!)
            val chosen=if(previous==AppearancePreference.DARK) AppearancePreference.LIGHT else AppearancePreference.DARK
            client.setAppearancePreference(chosen)
            await("save failure") { state.get().error?.contains("Could not save keypad appearance")==true }
            assertEquals(previous,AppearancePreference.forProfile(state.get().snapshot.selected!!))
            assertEquals(0,state.get().pendingAppearanceChanges)
            assertTrue(memory.loadPendingAppearancePreferences().isEmpty())
        } finally { client.dispose() }
    }
}
