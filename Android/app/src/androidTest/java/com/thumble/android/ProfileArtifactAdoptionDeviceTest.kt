package com.thumble.android

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import org.erdtman.jcs.JsonCanonicalizer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class ProfileArtifactAdoptionDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private fun await(label: String,test: ()->Boolean) {
        val until=SystemClock.elapsedRealtime()+25_000
        while(SystemClock.elapsedRealtime()<until) { if(test()) return;SystemClock.sleep(20) }
        fail(label)
    }
    private fun profile(id: String,name: String,control: String)=ControllerProfile.parse(JSONObject().put("id",id).put("name",name)
        .put("customization",JSONObject().put("elements",JSONArray().put(JSONObject().put("id",control).put("kind","button").put("label","Owned")))))
    private val original=profile("00000000-0000-0000-0000-000000000311","Original Mac","00000000-0000-0000-0000-000000000312")
    private fun artifact(large: Boolean=false): PortableProfileArtifact {
        val data=instrumentation.context.assets.open("profile-artifact/v1.json").use { it.readBytes() }
        if(!large) return PortableProfileArtifact.decode(data)
        val raw=JSONObject(data.toString(Charsets.UTF_8)).put("futurePadding",JSONArray().apply { repeat(10) { put("x".repeat(200_000)) } })
        val content=JSONObject(raw.toString()).apply { remove("exportedAt");remove("contentHash") }
        raw.getJSONObject("contentHash").put("value",packageHash(JsonCanonicalizer(content.toString()).encodedUTF8))
        return PortableProfileArtifact.decode(raw.toString().toByteArray())
    }
    private inner class Fixture(val artifact: PortableProfileArtifact) : AutoCloseable {
        val server=MockWebServer()
        val peer=AtomicReference<WebSocket>()
        val state=AtomicReference(ClientState())
        val frames=CopyOnWriteArrayList<ByteArray>()
        val begins=CopyOnWriteArrayList<JSONObject>()
        val commits=CopyOnWriteArrayList<String>()
        val chunks=CopyOnWriteArrayList<Int>()
        val received=ByteArrayOutputStream()
        val memory=MemorySessionStore()
        val directory=File(instrumentation.targetContext.noBackupFilesDir,"adoption-test-${UUID.randomUUID()}")
        val record=PendingSharedBuildStore(directory.toPath()).save(artifact)
        val shared=SharedBuildSession(directory.toPath())
        val client=ControllerClient(memory) { value -> state.set(value);shared.observeAdoption(value.artifactAdoption) }
        init {
            shared.onAdopt={ record,artifact,operation,done -> client.adoptSharedBuild(record,artifact,operation,done) }
            shared.onCancelAdoption={ client.cancelSharedBuildAdoption() }
            server.enqueue(MockResponse().withWebSocketUpgrade(object: WebSocketListener() {
                override fun onOpen(socket: WebSocket,response: Response) { peer.set(socket) }
                override fun onMessage(socket: WebSocket,bytes: ByteString) { frames.add(bytes.toByteArray()) }
                override fun onMessage(socket: WebSocket,text: String) {
                    val message=JSONObject(text)
                    when(message.getString("type")) {
                        "hello" -> socket.send(snapshot("pairing_accepted",listOf(original),original.id).put("serverID","adoption-fixture").put("authToken","fictional-fixture-token")
                            .put("inputProtocolVersion",3).put("capabilities",JSONArray().put(ArtifactAdoptionMetadata.CAPABILITY)).toString())
                        "profile_artifact_adoption_begin" -> {
                            val metadata=message.getJSONObject("profileArtifactAdoptionMetadata");begins.add(metadata)
                            synchronized(received) { received.reset();chunks.clear() }
                            socket.send(result(metadata,"accepted",emptyList()).toString())
                        }
                        "profile_artifact_adoption_chunk" -> {
                            chunks.add(message.getInt("profileArtifactAdoptionChunkIndex"))
                            synchronized(received) { received.write(java.util.Base64.getDecoder().decode(message.getString("profileArtifactAdoptionChunkData"))) }
                        }
                        "profile_artifact_adoption_commit" -> commits.add(message.getString("profileArtifactAdoptionOperationID"))
                        else -> frames.add(text.toByteArray())
                    }
                }
            }));server.start()
            client.connect(PairingTarget.manual(server.url("/").toString().replace("http://","ws://"),"123456"))
            await("fixture paired") { state.get().paired && shared.records.size==1 }
        }
        fun begin() { instrumentation.runOnMainSync { shared.adopt(record.id,"adoption-fixture") } }
        fun inputs()=frames.count { it.size==56 || runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("type") in setOf("pointer","gamepad_analog") }.getOrDefault(false) }
        override fun close() { client.dispose();shared.close();server.shutdown();directory.deleteRecursively() }
    }
    private fun snapshot(type: String,profiles: List<ControllerProfile>,active: UUID)=WireCodec.message(type)
        .put("gamepadProfiles",JSONArray(profiles.map { it.source })).put("gamepadProfileID",active.toString()).put("defaultGamepadProfileID",original.id.toString())
    private fun result(metadata: JSONObject,status: String,ids: List<UUID>,error: String?=null)=WireCodec.message("profile_artifact_adoption_result")
        .put("profileArtifactAdoptionResult",JSONObject().put("operationID",metadata.getString("operationID")).put("recordID",metadata.getString("recordID"))
            .put("serverID",metadata.getString("intendedServerID")).put("contentHash",metadata.getString("contentHash")).put("rawSHA256",metadata.getString("rawSHA256"))
            .put("status",status).put("errorCode",error ?: JSONObject.NULL).put("destinationProfileIDs",JSONArray(ids.map { it.toString() })))

    @Test fun normalReceiverCancellationRetainsBuildAndCLICanCancelAPhoneUpload() {
        val args=InstrumentationRegistry.getArguments()
        val qr=args.getString("adoptionPairingQR");val expected=args.getString("normalAdoptionServerID")
        org.junit.Assume.assumeTrue("Requires explicit normal receiver identity",qr!=null && expected!=null)
        val target=PairingTarget.parse(qr!!);require(target.serverID==expected)
        val directory=File(instrumentation.targetContext.noBackupFilesDir,"normal-adoption-cancel-${UUID.randomUUID()}")
        val artifact=artifact(true);val store=PendingSharedBuildStore(directory.toPath());val kept=store.save(artifact)
        val shared=SharedBuildSession(directory.toPath());val state=AtomicReference(ClientState());val memory=MemorySessionStore()
        val client=ControllerClient(memory) { value -> state.set(value);shared.observeAdoption(value.artifactAdoption) }
        val external=instrumentation.targetContext.getExternalFilesDir(null)!!
        val http=okhttp3.OkHttpClient();val socket=AtomicReference<WebSocket>();val messages=CopyOnWriteArrayList<JSONObject>()
        try {
            client.connect(target);await("normal receiver paired") { state.get().paired }
            assertTrue(ArtifactAdoptionMetadata.CAPABILITY in state.get().capabilities)
            val before=state.get().snapshot
            // Queue cancellation immediately after begin, before accepted can
            // drive the automatic chunk loop. The coordinator remains the sole
            // owner of pending metadata, just as in the running app.
            shared.onAdopt={ record,artifact,operation,done ->
                client.adoptSharedBuild(record,artifact,operation,done)
                client.cancelSharedBuildAdoption()
            }
            instrumentation.runOnMainSync { shared.adopt(kept.id,expected!!) }
            await("normal phone cancellation retained") { state.get().artifactAdoption?.phase==ArtifactAdoptionPhase.FAILED && shared.records.singleOrNull()?.state==PendingBuildState.FAILED }
            val operation=state.get().artifactAdoption!!.metadata.operationID
            val record=shared.records.single()
            assertArrayEquals(artifact.rawData(),store.load(kept.id).rawData())
            assertEquals(before,state.get().snapshot)
            val trusted=memory.loadMac()!!
            client.dispose()

            // Hold another genuine Android WebSocket upload at begin so the
            // external public CLI has a deterministic cancellation window.
            val metadata=ArtifactAdoptionMetadata.forRecord(record,expected!!,UUID.randomUUID())
            fun receive(value: JSONObject) {
                messages.add(value)
                if(value.optString("type")=="pairing_accepted") socket.get().send(WireCodec.message("profile_artifact_adoption_begin").put("profileArtifactAdoptionMetadata",metadata.json()).toString())
            }
            http.newWebSocket(okhttp3.Request.Builder().url(target.urls.first()).build(),object: WebSocketListener() {
                override fun onOpen(ws: WebSocket,response: Response) {
                    socket.set(ws)
                    ws.send(WireCodec.message("hello").put("authToken",trusted.authToken).put("serverID",trusted.serverID).toString())
                }
                override fun onMessage(ws: WebSocket,text: String) { receive(JSONObject(text)) }
                override fun onMessage(ws: WebSocket,bytes: ByteString) { receive(WireCodec.decode(bytes.toByteArray())) }
            })
            await("normal CLI upload accepted") { messages.any { it.optJSONObject("profileArtifactAdoptionResult")?.optString("status")=="accepted" } }
            File(external,"shared-build-cli-cancel-ready.json").writeText(metadata.json().toString())
            await("normal CLI cancellation delivered to Android") { messages.any { it.optJSONObject("profileArtifactAdoptionResult")?.optString("errorCode")=="disconnected" } }
            assertArrayEquals(artifact.rawData(),store.load(kept.id).rawData())
            File(external,"shared-build-cancellation-result.json").writeText(JSONObject().put("phoneCanceledOperationID",operation.toString()).put("cliCanceledOperationID",metadata.operationID.toString()).put("bytesRetained",true).toString())
        } finally { socket.get()?.close(1000,"done");client.dispose();shared.close();http.dispatcher.executorService.shutdown();http.connectionPool.evictAll();directory.deleteRecursively() }
    }

    @Test fun multiChunkUploadReleasesInputRejectsSpoofedResultsAndDeletesOnlyAfterAuthoritativeSnapshot() {
        Fixture(artifact(true)).use { f ->
            val held=original.controls(false).first().id
            f.client.edge(held,true,1,f.state.get().surfaceRevision);await("held input before adoption") { f.inputs()>0 }
            f.begin();await("all chunks committed") { f.commits.size==1 }
            val metadata=f.begins.single();assertTrue(metadata.getInt("chunkCount")>1)
            assertEquals((0 until metadata.getInt("chunkCount")).toList(),f.chunks.toList())
            synchronized(f.received) { assertArrayEquals(f.artifact.rawData(),f.received.toByteArray()) }
            await("adoption input release") { f.frames.any { runCatching { JSONObject(it.toString(Charsets.UTF_8)).getString("type")=="release_all" }.getOrDefault(false) } }
            val count=f.inputs();val revision=f.state.get().surfaceRevision
            f.client.edge(held,true,2,revision);f.client.stick("left",1.0,1.0,true,revision);f.client.trigger("right",1.0,true,revision);f.client.pointer("move",1.0,1.0,null,null,revision)
            f.client.setOrientationPreference("landscape");f.client.setPracticeMode(true)
            SystemClock.sleep(200);assertEquals(count,f.inputs());assertFalse(f.memory.loadPreferences().practiceMode)
            val destination=UUID.randomUUID()
            val spoof=result(metadata,"succeeded",listOf(destination)).put("gamepadProfiles",JSONArray())
            f.peer.get().send(spoof.toString())
            val wrong=result(metadata,"succeeded",listOf(destination));wrong.getJSONObject("profileArtifactAdoptionResult").put("rawSHA256","c".repeat(64));f.peer.get().send(wrong.toString())
            SystemClock.sleep(200);assertEquals(ArtifactAdoptionPhase.UPLOADING,f.state.get().artifactAdoption?.phase)
            assertEquals(original.id,f.state.get().snapshot.selectedID);assertEquals(1,f.shared.records.size)
            f.peer.get().send(result(metadata,"succeeded",listOf(destination)).toString())
            await("wait for authority") { f.state.get().artifactAdoption?.phase==ArtifactAdoptionPhase.AWAITING_SNAPSHOT }
            assertTrue(f.directory.listFiles().orEmpty().isNotEmpty());assertEquals(1,f.shared.records.size)
            f.peer.get().send(snapshot("gamepad_profiles",listOf(original),original.id).toString())
            SystemClock.sleep(100);assertEquals(ArtifactAdoptionPhase.AWAITING_SNAPSHOT,f.state.get().artifactAdoption?.phase)
            val imported=ControllerProfile.parse(JSONObject(f.artifact.profileSnapshot().selected!!.source.toString()).apply { remove("portraitCustomization");remove("landscapeCustomization") }.put("id",destination.toString()))
            f.peer.get().send(snapshot("gamepad_profiles",listOf(original,imported),destination).toString())
            await("confirmed adoption and cleanup") { f.state.get().artifactAdoption?.phase==ArtifactAdoptionPhase.SUCCEEDED && f.shared.records.isEmpty() }
            assertTrue(f.directory.listFiles().orEmpty().isEmpty());assertEquals(original.id,f.memory.loadSnapshot().defaultID)
            f.client.edge(imported.controls(false).first().id,true,3,f.state.get().surfaceRevision)
            await("input resumes after confirmed adoption") { f.inputs()>count }
        }
    }
    @Test fun cancelKeepsTheBuildAndRetryUsesTheSameOperationRecordServerAndHashes() {
        Fixture(artifact()).use { f ->
            f.begin();await("first attempt") { f.commits.size==1 }
            val first=f.begins.single()
            f.client.cancelSharedBuildAdoption()
            await("canceled record retained") { f.state.get().artifactAdoption?.phase==ArtifactAdoptionPhase.FAILED && f.shared.records.singleOrNull()?.state==PendingBuildState.FAILED }
            assertArrayEquals(f.artifact.rawData(),PendingSharedBuildStore(f.directory.toPath()).load(f.record.id).rawData())
            f.begin();await("retry uses same operation") { f.commits.size==2 }
            val retry=f.begins.last()
            assertEquals(first.toString(),retry.toString());assertEquals(f.commits[0],f.commits[1])
            val destination=UUID.randomUUID();val imported=ControllerProfile.parse(JSONObject(f.artifact.profileSnapshot().selected!!.source.toString()).apply { remove("portraitCustomization");remove("landscapeCustomization") }.put("id",destination.toString()))
            f.peer.get().send(snapshot("gamepad_profiles",listOf(original,imported),destination).toString())
            f.peer.get().send(result(retry,"replayed",listOf(destination)).toString())
            await("replayed durable result completes retry") { f.state.get().artifactAdoption?.phase==ArtifactAdoptionPhase.SUCCEEDED && f.shared.records.isEmpty() }
            assertFalse(f.memory.loadPreferences().practiceMode)
        }
    }
}
