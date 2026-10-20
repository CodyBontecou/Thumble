package com.thumble.android

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import okhttp3.*
import okhttp3.mockwebserver.*
import okio.ByteString
import org.erdtman.jcs.JsonCanonicalizer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** USB-driven physical-radio test. A phone-local relay gates one protocol boundary.
 * Upstream traffic uses the real Mac on wlan0; actual upstream I/O failure closes
 * the production client connection. No synthetic result/disconnect is injected.
 */
@RunWith(AndroidJUnit4::class)
class WifiAdoptionRecoveryDeviceTest {
    private val instrumentation get()=InstrumentationRegistry.getInstrumentation()
    private fun await(label: String, seconds: Int=35, predicate: ()->Boolean) {
        val deadline=SystemClock.elapsedRealtime()+seconds*1000
        while(SystemClock.elapsedRealtime()<deadline) { if(predicate()) return;SystemClock.sleep(25) };fail(label)
    }
    @Test fun physicalWifiLossRetainsBuildAndRetryIsIdempotent() = runBoundary(false)
    @Test fun prepareForProcessDeathDuringAdoption() = runBoundary(true)
    private fun runBoundary(processDeath: Boolean) {
        val args=InstrumentationRegistry.getArguments()
        val qr=args.getString("adoptionPairingQR");val expected=args.getString("normalAdoptionServerID");val mode=args.getString("wifiRecoveryMode")
        val rawRunID=args.getString("processDeathRunID")
        assumeTrue("Requires explicit receiver identity and external interruption driver",qr!=null && expected!=null && mode in setOf("partial","committed") && (!processDeath || rawRunID!=null))
        val runID=if(processDeath) UUID.fromString(rawRunID).toString() else null
        val target=PairingTarget.parse(qr!!);require(target.serverID==expected)
        val external=instrumentation.targetContext.getExternalFilesDir(null)!!
        val prefix=if(processDeath) "death-$mode" else "wifi-$mode"
        fun signal(name: String,value: JSONObject) {
            if(processDeath) value.put("pid",android.os.Process.myPid()).put("runID",runID)
            val file=File(external,"$prefix-$name.json");val temp=File(external,"$prefix-$name.tmp")
            temp.writeText(value.toString());check(temp.renameTo(file))
        }
        val raw=JSONObject(instrumentation.context.assets.open("profile-artifact/v1.json").use { it.readBytes() }.toString(Charsets.UTF_8))
            .put("futurePadding",JSONArray().apply { repeat(10) { put("w".repeat(200_000)) } })
        val content=JSONObject(raw.toString()).apply { remove("exportedAt");remove("contentHash") }
        raw.getJSONObject("contentHash").put("value",packageHash(JsonCanonicalizer(content.toString()).encodedUTF8))
        val artifact=PortableProfileArtifact.decode(raw.toString().toByteArray())
        val directory=File(instrumentation.targetContext.noBackupFilesDir,if(processDeath) "process-adoption-$runID-pending" else "wifi-recovery-${UUID.randomUUID()}")
        val kept=PendingSharedBuildStore(directory.toPath()).save(artifact);val shared=SharedBuildSession(directory.toPath())
        val state=AtomicReference(ClientState());val attempts=AtomicInteger()
        val upstreamFailure=AtomicReference<String>();val upstreamResult=AtomicReference<JSONObject>()
        val begins=java.util.concurrent.CopyOnWriteArrayList<JSONObject>()
        val http=OkHttpClient.Builder().pingInterval(1,TimeUnit.SECONDS).connectTimeout(3,TimeUnit.SECONDS).build()
        val relay=MockWebServer()
        relay.dispatcher=object: okhttp3.mockwebserver.Dispatcher() {
            override fun dispatch(request: RecordedRequest)=MockResponse().withWebSocketUpgrade(object: WebSocketListener() {
                val first=attempts.incrementAndGet()==1
                val lock=Any();val pending=mutableListOf<String>();var upstream: WebSocket?=null
                @Volatile var gated=false
                lateinit var downstream: WebSocket
                override fun onOpen(socket: WebSocket,response: Response) {
                    downstream=socket
                    http.newWebSocket(Request.Builder().url(target.urls.first()).build(),object: WebSocketListener() {
                        override fun onOpen(ws: WebSocket,response: Response) { synchronized(lock) { upstream=ws;pending.forEach { ws.send(it) };pending.clear() } }
                        fun receive(message: JSONObject,forward: ()->Unit) {
                            val result=message.optJSONObject("profileArtifactAdoptionResult")
                            if(first && result?.optString("status") in setOf("succeeded","replayed")) {
                                upstreamResult.set(result)
                                if(mode=="committed") signal("checkpoint",JSONObject().put("mode",mode).put("metadata",begins.first()).put("result",result))
                            }
                            if(!(first && mode=="committed" && gated)) forward()
                        }
                        override fun onMessage(ws: WebSocket,text: String) { receive(JSONObject(text)) { downstream.send(text) } }
                        override fun onMessage(ws: WebSocket,bytes: ByteString) { receive(WireCodec.decode(bytes.toByteArray())) { downstream.send(bytes) } }
                        override fun onFailure(ws: WebSocket,t: Throwable,response: Response?) { if(first) upstreamFailure.set(t.javaClass.simpleName);downstream.close(1001,"upstream I/O failed") }
                        override fun onClosing(ws: WebSocket,code: Int,reason: String) { downstream.close(code,"upstream closed");ws.close(code,null) }
                    })
                }
                override fun onMessage(socket: WebSocket,text: String) {
                    val message=JSONObject(text);val type=message.optString("type")
                    if(type=="profile_artifact_adoption_begin") begins.add(message.getJSONObject("profileArtifactAdoptionMetadata"))
                    if(first && mode=="partial" && type=="profile_artifact_adoption_chunk" && message.getInt("profileArtifactAdoptionChunkIndex")==1) {
                        gated=true;signal("checkpoint",JSONObject().put("mode",mode).put("metadata",begins.first()).put("forwardedChunks",1))
                    }
                    if(first && mode=="partial" && gated) return
                    if(first && mode=="committed" && type=="profile_artifact_adoption_commit") gated=true
                    synchronized(lock) { upstream?.send(text) ?: pending.add(text) }
                }
                override fun onMessage(socket: WebSocket,bytes: ByteString) { synchronized(lock) { upstream?.send(bytes) } }
                override fun onFailure(socket: WebSocket,t: Throwable,response: Response?) { synchronized(lock) { upstream?.cancel() } }
                override fun onClosing(socket: WebSocket,code: Int,reason: String) { synchronized(lock) { upstream?.close(code,null) };socket.close(code,null) }
            })
        }
        relay.start()
        val local=PairingTarget(listOf(relay.url("/").toString().replace("http://","ws://")),target.code,target.serverID)
        val sessionStore=if(processDeath) AndroidSessionStore(instrumentation.targetContext,"process-adoption-$runID-session") else MemorySessionStore()
        val client=ControllerClient(sessionStore) { value -> state.set(value);shared.observeAdoption(value.artifactAdoption) }
        shared.onAdopt={ record,value,operation,done -> client.adoptSharedBuild(record,value,operation,done) }
        try {
            client.connect(local);await("real receiver paired through phone relay") { state.get().paired && shared.records.size==1 }
            val before=state.get().snapshot
            if(processDeath) {
                val trusted=sessionStore.loadMac()!!
                // The relay is disposable. Persist the real LAN endpoint so a
                // new process reconnects directly using encrypted credentials.
                sessionStore.saveMac(TrustedMac(trusted.serverID,trusted.authToken,target.urls))
                signal("before",JSONObject().put("profileCount",before.profiles.size).put("defaultID",before.defaultID.toString()))
            }
            instrumentation.runOnMainSync { shared.adopt(kept.id,expected!!) }
            if(processDeath) {
                // The USB driver must kill this process while disk metadata is
                // ADOPTING. No orderly dispose/finally runs on force-stop.
                SystemClock.sleep(60_000)
                fail("USB driver did not kill the prepared process")
            }
            await("Wi-Fi loss reported by upstream I/O and retained by coordinator") {
                upstreamFailure.get()!=null && state.get().artifactAdoption?.phase==ArtifactAdoptionPhase.FAILED && shared.records.singleOrNull()?.state==PendingBuildState.FAILED
            }
            val failed=state.get().artifactAdoption!!;assertEquals("disconnected",failed.errorCode)
            assertArrayEquals(artifact.rawData(),PendingSharedBuildStore(directory.toPath()).load(kept.id).rawData())
            assertEquals(before,state.get().snapshot);assertEquals(mode=="committed",upstreamResult.get()!=null)
            signal("retained",JSONObject().put("bytesRetained",true).put("pendingCount",shared.records.size).put("metadata",failed.metadata.json())
                .put("errorCode",failed.errorCode).put("upstreamFailure",upstreamFailure.get()))
            await("host restored Wi-Fi route",60) { File(external,"wifi-$mode-reconnect.json").exists() }
            client.reconnect();await("trusted reconnect to same Mac") { state.get().paired }
            instrumentation.runOnMainSync { shared.adopt(kept.id,expected!!) }
            await("retry confirmed by authoritative snapshot and pending cleanup") { state.get().artifactAdoption?.phase==ArtifactAdoptionPhase.SUCCEEDED && shared.records.isEmpty() }
            val success=state.get().artifactAdoption!!;assertEquals(failed.metadata,success.metadata)
            assertTrue(begins.size>=2);begins.forEach { assertEquals(begins.first().toString(),it.toString()) }
            assertEquals(before.profiles.size+artifact.profileSnapshot().profiles.size,state.get().snapshot.profiles.size)
            assertEquals(before.defaultID,state.get().snapshot.defaultID);assertTrue(directory.listFiles().orEmpty().isEmpty())
            File(external,"wifi-$mode-artifact.json").writeBytes(artifact.rawData())
            signal("result",JSONObject().put("metadata",success.metadata.json()).put("destinationProfileIDs",JSONArray(success.destinationProfileIDs.map { it.toString() }))
                .put("pendingRemovedAfterConfirmation",true).put("originalProfileCount",before.profiles.size).put("finalProfileCount",state.get().snapshot.profiles.size))
        } finally {
            client.dispose();shared.close();relay.shutdown();http.dispatcher.executorService.shutdown();http.connectionPool.evictAll();directory.deleteRecursively()
        }
    }
}
