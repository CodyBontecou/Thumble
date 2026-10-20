package com.thumble.android

import android.os.SystemClock
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
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class LayoutEditClientDeviceTest {
    @Test fun realRustReceiverAcceptsActiveInactiveAndRecoveredLayouts() {
        val qr=InstrumentationRegistry.getArguments().getString("layoutPairingQR")
        assumeTrue("Requires private native receiver",qr!=null)
        val target=PairingTarget.parse(qr!!)
        val main=profile()
        val missing=ControllerProfile.parse(JSONObject(main.source.toString()).put("id","4FD20F4A-3C83-40B5-87C0-64512F4AC926"))
        val recovery=PendingLayoutEdit.create(missing.id,LayoutOrientation.PORTRAIT,changed(missing).json(),42,target.serverID)
        val store=MemorySessionStore().apply {
            savePreferences(ClientPreferences(practiceMode=true))
            saveEditingState(ProfileSnapshot(listOf(main,LayoutEditJournal.applying(missing,recovery)),main.id,main.id),emptyList(),emptyList(),listOf(recovery))
        }
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            client.connect(target)
            await("recovered layout acknowledged") { state.get().paired && state.get().pendingLayoutChanges==0 &&
                state.get().snapshot.profiles.any { it.id==missing.id && it.name=="Recovered Phone Layout" } }
            if(InstrumentationRegistry.getArguments().getString("expectLayoutSkinLibraryUnavailable")=="true")
                assertFalse("layout sync must work without archive-store readiness","skin_packages" in state.get().capabilities)
            assertEquals(main.id,state.get().snapshot.selectedID)
            client.beginLayoutEditing(main.id,LayoutOrientation.PORTRAIT);await("active portrait editor") { state.get().layoutEditing }
            client.commitLayoutEdit(changed(state.get().snapshot.selected!!),state.get().layoutEditToken)
            await("active portrait stored and acknowledged") { state.get().pendingLayoutChanges==0 &&
                state.get().snapshot.selected!!.source.optJSONObject("portraitCustomization")?.optBoolean("showsButtonLabels")==!main.source.getJSONObject("customization").optBoolean("showsButtonLabels",true) }
            client.finishLayoutEditing();await("active edit complete") { !state.get().layoutEditing }
            val inactiveID=java.util.UUID.fromString("4FD20F4A-3C83-40B5-87C0-64512F4AC925")
            client.viewSavedKeypad();await("offline cache") { state.get().viewingSaved && !state.get().paired }
            client.selectProfile(inactiveID);await("inactive cached profile") { state.get().snapshot.selectedID==inactiveID }
            val old=state.get().snapshot.selected!!
            client.beginLayoutEditing(inactiveID,LayoutOrientation.LANDSCAPE);await("offline editor") { state.get().layoutEditing }
            client.commitLayoutEdit(changed(old),state.get().layoutEditToken);await("inactive edit saved offline") { state.get().pendingLayoutChanges==1 }
            client.finishLayoutEditing();client.selectProfile(main.id)
            await("original selection restored locally") { !state.get().layoutEditing && state.get().snapshot.selectedID==main.id }
            client.reconnect()
            await("inactive edit durably acknowledged") { state.get().paired && state.get().pendingLayoutChanges==0 &&
                state.get().snapshot.profiles.first { it.id==inactiveID }.source.getJSONObject("customization").optBoolean("showsButtonLabels")==!old.source.getJSONObject("customization").optBoolean("showsButtonLabels",true) }
            assertEquals(main.id,state.get().snapshot.selectedID)
            assertTrue(store.loadPendingLayoutEdits().isEmpty())
            assertTrue(state.get().practiceMode)
        } finally { client.dispose() }
    }
    private fun profile() = ControllerProfile.parse(JSONObject(InstrumentationRegistry.getInstrumentation().context.assets
        .open("controller-templates/v1/productivityStarter.json").bufferedReader().use { it.readText() }).getJSONObject("profile"))
    private fun snapshot(profile: ControllerProfile) = ProfileSnapshot(listOf(profile),profile.id,profile.id)
    private fun changed(profile: ControllerProfile): LayoutSnapshot = LayoutSnapshot.capture(JSONObject(profile.source.getJSONObject("customization").toString())
        .put("showsButtonLabels",!profile.source.getJSONObject("customization").optBoolean("showsButtonLabels",true)))
    private fun await(label: String, predicate: ()->Boolean) {
        val end=SystemClock.elapsedRealtime()+12_000
        while(!predicate() && SystemClock.elapsedRealtime()<end) SystemClock.sleep(20)
        assertTrue(label,predicate())
    }
    @Test fun offlineCommitSurvivesRestartAndStaleEditorTokensCannotWrite() {
        val original=profile()
        val memory=MemorySessionStore().apply {
            saveSnapshot(snapshot(original));saveMac(TrustedMac("mac","fixture-token",listOf("ws://127.0.0.1:1")))
        }
        val state=AtomicReference(ClientState())
        var client=ControllerClient(memory) { state.set(it) }
        try {
            client.viewSavedKeypad();await("offline") { state.get().viewingSaved }
            client.beginLayoutEditing(original.id,LayoutOrientation.PORTRAIT);await("editing") { state.get().layoutEditing }
            val token=state.get().layoutEditToken
            client.commitLayoutEdit(changed(original),token)
            await("durable pending edit") { state.get().pendingLayoutChanges==1 }
            assertEquals(LayoutOrientation.PORTRAIT,LayoutOrientation.of(memory.loadSnapshot().selected!!.source.getJSONObject("customization")))
            client.suspend();await("suspended editor") { !state.get().layoutEditing }
            val rejected=AtomicReference<Boolean?>()
            client.commitLayoutEdit(LayoutSnapshot.capture(original.source.getJSONObject("customization")),token) { rejected.set(it) }
            await("stale callback rejected") { rejected.get()!=null };assertFalse(rejected.get()!!)
            client.setAppearancePreference(AppearancePreference.DARK)
            await("later global mode saved") { state.get().pendingAppearanceChanges==1 }
            assertEquals("dark",memory.loadPendingLayoutEdits().single().customization.json().getString("colorSchemePreference"))
            client.dispose()
            client=ControllerClient(memory) { state.set(it) }
            await("pending edit reloaded") { state.get().pendingLayoutChanges==1 }
            assertEquals(1,state.get().pendingAppearanceChanges)
            assertFalse(state.get().layoutEditing)
            assertEquals(1,memory.loadPendingLayoutEdits().size)
            client.forgetMac();await("forgotten") { state.get().status=="Mac forgotten" }
            assertTrue(memory.loadPendingLayoutEdits().isEmpty())
        } finally { client.dispose() }
    }
    @Test fun failedLocalSaveKeepsSnapshotAndJournalUnchanged() {
        val original=profile()
        val memory=MemorySessionStore().apply { saveSnapshot(snapshot(original)) }
        val store=object: SessionStore by memory {
            override fun saveEditingState(snapshot: ProfileSnapshot,skins: List<PendingSkinSelection>,appearance: List<PendingAppearancePreference>,layouts: List<PendingLayoutEdit>) {
                throw java.io.IOException("fixture disk failure")
            }
        }
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            client.viewSavedKeypad();await("offline") { state.get().viewingSaved }
            client.beginLayoutEditing(original.id,LayoutOrientation.LANDSCAPE);await("editor") { state.get().layoutEditing }
            client.commitLayoutEdit(changed(original),state.get().layoutEditToken)
            await("save rejected") { state.get().error?.contains("Could not save this layout")==true }
            assertTrue(LayoutSnapshot.capture(original.source.getJSONObject("customization")).samePresentation(
                LayoutSnapshot.capture(state.get().snapshot.selected!!.source.getJSONObject("customization"))))
            assertEquals(0,state.get().pendingLayoutChanges);assertTrue(memory.loadPendingLayoutEdits().isEmpty())
        } finally { client.dispose() }
    }
    @Test fun editingReleasesAndSuppressesInputAndFailedEchoPersistenceDoesNotLoop() {
        val original=profile();val server=MockWebServer()
        val peer=AtomicReference<WebSocket>();val requests=CopyOnWriteArrayList<JSONObject>();val wire=CopyOnWriteArrayList<ByteArray>()
        val selections=CopyOnWriteArrayList<JSONObject>()
        fun message(profile: ControllerProfile,type: String="gamepad_profiles") = WireCodec.message(type)
            .put("gamepadProfiles",JSONArray().put(profile.source)).put("gamepadProfileID",profile.id.toString())
        val listener=object: WebSocketListener() {
            override fun onOpen(socket: WebSocket,response: Response) { peer.set(socket) }
            override fun onMessage(socket: WebSocket,bytes: ByteString) { wire.add(bytes.toByteArray()) }
            override fun onMessage(socket: WebSocket,text: String) {
                val value=JSONObject(text)
                if(value.optString("type")=="hello") socket.send(message(original,"pairing_accepted").put("inputProtocolVersion",3)
                    .put("serverID","mac").put("authToken","fixture-token").put("capabilities",JSONArray().put(ProfileActions.ORIENTATION_CAPABILITY).put("gamepad_profile_skin_selection")).toString())
                else if(value.optString("type")=="gamepad_customization") requests.add(value)
                else if(value.optString("type")=="gamepad_profile_skin_selection") selections.add(value)
            }
        }
        server.enqueue(MockResponse().withWebSocketUpgrade(listener))
        server.start(InetAddress.getByName("127.0.0.1"),0)
        val memory=MemorySessionStore();val fail=AtomicBoolean(false)
        val store=object: SessionStore by memory {
            override fun saveEditingState(snapshot: ProfileSnapshot,skins: List<PendingSkinSelection>,appearance: List<PendingAppearancePreference>,layouts: List<PendingLayoutEdit>) {
                if(fail.get()) throw java.io.IOException("fixture ACK disk failure")
                memory.saveEditingState(snapshot,skins,appearance,layouts)
            }
        }
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"));await("paired") { state.get().paired }
            val control=original.controls(false).first { it.kind=="button" }.id
            client.edge(control,true,1,state.get().surfaceRevision);await("held wire edge") { wire.any { it.size==56 } }
            val before=wire.size
            client.beginLayoutEditing(original.id,LayoutOrientation.LANDSCAPE);await("editor release") {
                state.get().layoutEditing && wire.drop(before).any { runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("type")=="release_all" }.getOrDefault(false) }
            }
            val count=wire.count { it.size==56 }
            fun liveFrames() = wire.count { runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("type") !in setOf("heartbeat","release_all") }.getOrDefault(true) }
            val liveCount=liveFrames()
            client.edge(control,true,2,state.get().surfaceRevision)
            client.stick("left",1.0,1.0,true,state.get().surfaceRevision)
            client.pointer("move",1.0,1.0,null,null,state.get().surfaceRevision)
            SystemClock.sleep(400);assertEquals(count,wire.count { it.size==56 });assertEquals(liveCount,liveFrames())
            client.commitLayoutEdit(changed(original),state.get().layoutEditToken)
            await("edit uploaded") { requests.isNotEmpty() && state.get().pendingLayoutChanges==1 }
            val edit=store.loadPendingLayoutEdits().single()
            val beforeReconnect=requests.size
            server.enqueue(MockResponse().withWebSocketUpgrade(listener))
            client.disconnect();await("explicit disconnect") { !state.get().paired }
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}","123456"))
            await("saved layout replayed after reconnect") { state.get().paired && requests.size>beforeReconnect }
            assertFalse(state.get().layoutEditing)
            assertEquals(1,state.get().pendingLayoutChanges)
            assertTrue(LayoutSnapshot.capture(state.get().snapshot.selected!!.source.getJSONObject("customization")).samePresentation(edit.customization))
            client.beginLayoutEditing(original.id,LayoutOrientation.LANDSCAPE);await("editor resumed deliberately") { state.get().layoutEditing }
            val renamed=ControllerProfile.parse(JSONObject(original.source.toString()).put("name","New Mac name"))
            peer.get().send(message(renamed).toString())
            await("new metadata and offline layout") { state.get().snapshot.selected?.name=="New Mac name" && requests.size>=2 }
            assertTrue(LayoutSnapshot.capture(state.get().snapshot.selected!!.source.getJSONObject("customization")).samePresentation(edit.customization))
            val acknowledged=LayoutEditJournal.applying(renamed,edit)
            val sent=requests.size
            fail.set(true);peer.get().send(message(acknowledged).toString())
            await("ACK save failure") { state.get().error?.contains("could not save your keypad")==true }
            assertEquals(1,state.get().pendingLayoutChanges)
            SystemClock.sleep(400);assertEquals(sent,requests.size)
            fail.set(false);peer.get().send(message(acknowledged).toString())
            await("ACK durable") { state.get().pendingLayoutChanges==0 }
            assertTrue(store.loadPendingLayoutEdits().isEmpty())
            assertTrue(state.get().layoutEditing)
            client.finishLayoutEditing();await("editor finished") { !state.get().layoutEditing }
            client.beginLayoutEditing(original.id,LayoutOrientation.LANDSCAPE);await("next edit") { state.get().layoutEditing }
            val beforeNext=requests.size
            client.commitLayoutEdit(changed(state.get().snapshot.selected!!),state.get().layoutEditToken)
            await("second layout pending") { state.get().pendingLayoutChanges==1 && requests.size>beforeNext }
            client.finishLayoutEditing();await("ready for skin") { !state.get().layoutEditing }
            val current=state.get().snapshot.selected!!
            val reference=SkinReference("com.example.client-edit-skin","1.0.0")
            val referenceJSON=JSONObject().put("identifier",reference.identifier).put("version",reference.version)
            fun skinned(profile: ControllerProfile): ControllerProfile = ControllerProfile.parse(JSONObject(profile.source.toString()).apply {
                put("skinReference",referenceJSON)
                getJSONObject("customization").put("accentStyle","purple")
                getJSONObject("landscapeCustomization").put("accentStyle","purple")
            })
            val replacement=skinned(current)
            val beforeSkin=requests.size
            client.commitSkinChange(current,replacement,reference)
            await("skin request pending") { state.get().pendingSkinChanges==1 && selections.isNotEmpty() }
            assertEquals("purple",store.loadPendingLayoutEdits().single().customization.json().getString("accentStyle"))
            peer.get().send(message(acknowledged).toString())
            SystemClock.sleep(400)
            assertEquals("layout must wait for skin acknowledgement",beforeSkin,requests.size)
            peer.get().send(message(skinned(acknowledged)).toString())
            await("layout uploaded after skin acknowledgement") { state.get().pendingSkinChanges==0 && requests.size>beforeSkin }
            assertEquals("purple",requests.last().getJSONObject("gamepadCustomization").getString("accentStyle"))
            peer.get().send(message(replacement).toString())
            await("skin and layout fully acknowledged") { state.get().pendingLayoutChanges==0 && state.get().pendingSkinChanges==0 }
        } finally { client.dispose();server.shutdown() }
    }
    @Test fun corruptPendingJournalBlocksNewEditsAndPreservesTheSavedIntent() {
        val original=profile()
        val edit=PendingLayoutEdit.create(original.id,LayoutOrientation.LANDSCAPE,changed(original).json(),42,"mac")
        val memory=MemorySessionStore().apply { saveEditingState(snapshot(original),emptyList(),emptyList(),listOf(edit)) }
        val store=object: SessionStore by memory {
            override fun loadPendingLayoutEdits(): List<PendingLayoutEdit> = throw java.io.IOException("fixture journal unreadable")
        }
        val state=AtomicReference(ClientState());val client=ControllerClient(store) { state.set(it) }
        try {
            client.viewSavedKeypad();await("offline") { state.get().viewingSaved }
            client.beginLayoutEditing(original.id,LayoutOrientation.LANDSCAPE)
            await("editor blocked") { state.get().error?.contains("Could not restore pending")==true }
            assertFalse(state.get().layoutEditing)
            client.setAppearancePreference(AppearancePreference.DARK)
            SystemClock.sleep(200)
            assertEquals(listOf(edit),memory.loadPendingLayoutEdits())
            assertTrue(memory.loadPendingAppearancePreferences().isEmpty())
        } finally { client.dispose() }
    }
}
