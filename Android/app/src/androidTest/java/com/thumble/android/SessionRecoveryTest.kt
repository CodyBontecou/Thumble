package com.thumble.android

import android.os.SystemClock
import androidx.lifecycle.Lifecycle
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
import java.io.File
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class SessionRecoveryTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun await(description: String, test: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 12_000
        while (!test() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20)
        assertTrue(description, test())
    }
    private fun profile() = JSONObject(instrumentation.context.assets.open("controller-templates/v1/productivityStarter.json")
        .bufferedReader().use { it.readText() }).getJSONObject("profile")
    private fun acceptance(serverID: String = "recovery-fixture") = WireCodec.message("pairing_accepted")
        .put("inputProtocolVersion", 3).put("serverID", serverID).put("authToken", "fixture-trust-only")
        .put("gamepadProfiles", JSONArray().put(profile())).put("gamepadProfileID", profile().getString("id"))

    @Test fun encryptedTrustAndProfilesSurviveStoreRecreationAndTamperingFailsClosed() {
        val namespace = "recovery-test-${UUID.randomUUID()}"
        val context = instrumentation.targetContext
        val first = AndroidSessionStore(context, namespace)
        try {
            val mac = TrustedMac("fixture-id", "fixture-secret-never-plaintext", listOf("ws://127.0.0.1:8765"))
            first.saveMac(mac)
            first.saveSnapshot(ProfileSnapshot().applying(acceptance()))
            val file = File(context.noBackupFilesDir, "$namespace/trusted-mac.enc")
            val original = file.readBytes()
            assertFalse(original.toString(Charsets.ISO_8859_1).contains(mac.authToken))
            assertFalse(mac.toString().contains(mac.authToken))
            first.saveMac(mac)
            assertFalse("each save uses a fresh GCM IV", original.contentEquals(file.readBytes()))
            val second = AndroidSessionStore(context, namespace)
            assertEquals(mac.authToken, second.loadMac()!!.authToken)
            assertEquals(profile().getString("id").lowercase(), second.loadSnapshot().selectedID.toString())
            val tampered = file.readBytes().also { it[it.lastIndex] = (it.last().toInt() xor 1).toByte() }
            file.writeBytes(tampered)
            assertNull("tampered credentials must not reconnect", second.loadMac())
            second.saveMac(mac)
            assertEquals("fresh pairing can replace an invalidated key", mac.authToken, first.loadMac()!!.authToken)
            second.forgetMac()
            assertNull(first.loadMac())
            assertTrue(first.loadSnapshot().profiles.isEmpty())
        } finally { first.forgetMac(); File(context.noBackupFilesDir, namespace).deleteRecursively() }
    }

    @Test fun socketLossReconnectsWithTrustButNeverReplaysOldHoldsOrExplicitDisconnect() {
        val server = MockWebServer()
        val hellos = CopyOnWriteArrayList<JSONObject>()
        val frames = CopyOnWriteArrayList<ByteArray>()
        val live = AtomicReference<WebSocket>()
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { live.set(webSocket) }
            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = JSONObject(text)
                if (message.optString("type") == "hello") {
                    hellos.add(message); webSocket.send(acceptance().toString())
                }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { frames.add(bytes.toByteArray()) }
        }
        repeat(3) { server.enqueue(MockResponse().withWebSocketUpgrade(listener)) }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val store = MemorySessionStore()
        val current = AtomicReference(ClientState())
        val client = ControllerClient(store) { current.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}", "123456"))
            await("initial pairing") { current.get().paired }
            val oldRevision = current.get().surfaceRevision
            val control = current.get().snapshot.selected!!.controls(false).first().id
            client.edge(control, true, 70, oldRevision)
            await("initial hold sent") { frames.any { it.size == 56 } }
            live.get().close(1001, "Simulated transport interruption")
            await("trusted reconnect") { hellos.size == 2 && current.get().paired && current.get().surfaceRevision > oldRevision }
            assertEquals("fixture-trust-only", hellos[1].getString("authToken"))
            assertEquals("recovery-fixture", hellos[1].getString("serverID"))
            assertFalse("pairing codes are not reused", hellos[1].has("pairingCode"))
            val before = frames.count { it.size == 56 }
            client.edge(control, true, 71, oldRevision)
            SystemClock.sleep(550) // More than two hold-refresh intervals.
            assertEquals("reconnected surfaces cannot replay old holds", before, frames.count { it.size == 56 })
            client.disconnect()
            await("user disconnect") { !current.get().paired }
            client.suspend(); client.resume()
            SystemClock.sleep(1200) // Longer than the first retry delay.
            assertEquals("explicit disconnect survives a foreground cycle", 2, hellos.size)
            client.reconnect()
            await("explicit trusted reconnect") { hellos.size == 3 && current.get().paired }
            assertNotNull(store.loadMac())
        } finally { client.disconnect(); client.dispose(); server.shutdown() }
    }

    @Test fun revokedTrustRequiresFreshPairingAndDoesNotLoop() {
        val server = MockWebServer()
        val requests = AtomicInteger()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (JSONObject(text).optString("type") == "hello") {
                    requests.incrementAndGet()
                    webSocket.send(WireCodec.message("error").put("message", "Trusted pairing expired. Request pairing again from Thumble Host.").toString())
                }
            }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val store = MemorySessionStore().apply { saveMac(TrustedMac("recovery-fixture", "revoked-fixture", listOf("ws://127.0.0.1:${server.port}"))) }
        val current = AtomicReference(ClientState())
        val client = ControllerClient(store) { current.set(it) }
        try {
            client.resume()
            await("expired trust surfaces recovery") { current.get().error?.contains("expired") == true }
            assertFalse(current.get().canReconnect)
            assertNull(store.loadMac())
            client.resume()
            SystemClock.sleep(1200)
            assertEquals(1, requests.get())
        } finally { client.dispose(); server.shutdown() }
    }

    @Test fun activityRecreationAndBackgroundReturnReconnectWithoutQr() {
        val server = MockWebServer()
        val requests = CopyOnWriteArrayList<JSONObject>()
        repeat(3) { server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = JSONObject(text)
                if (message.optString("type") == "hello") { requests.add(message); webSocket.send(acceptance().toString()) }
            }
        })) }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val previous = ClientDependencies.sessionStore
        val store = MemorySessionStore()
        ClientDependencies.sessionStore = { store }
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { it.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}", "123456")) }
                fun paired(): Boolean {
                    var paired = false
                    scenario.onActivity { paired = it.connectionState.paired }
                    return paired
                }
                await("activity pairs") { paired() }
                scenario.recreate()
                await("activity retains session across recreation") { paired() }
                assertEquals("recreation retains the existing connection", 1, requests.size)
                scenario.moveToState(Lifecycle.State.CREATED)
                val before = requests.size
                SystemClock.sleep(1200)
                assertEquals("background stays disconnected", before, requests.size)
                scenario.moveToState(Lifecycle.State.RESUMED)
                await("foreground trusted reconnect") { requests.size == 2 && paired() }
                assertTrue(requests.drop(1).all { it.optString("authToken") == "fixture-trust-only" && !it.has("pairingCode") })
                scenario.onActivity { it.finish() }
            }
        } finally { ClientDependencies.sessionStore = previous; server.shutdown() }
    }
    @Test fun recreationDuringPairingRetainsThePendingSocket() {
        val server = MockWebServer()
        val helloCount = AtomicInteger()
        val socket = AtomicReference<WebSocket>()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { socket.set(webSocket) }
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (JSONObject(text).optString("type") == "hello") helloCount.incrementAndGet()
            }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val previous = ClientDependencies.sessionStore
        val store = MemorySessionStore()
        ClientDependencies.sessionStore = { store }
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { it.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}", "123456")) }
                await("hello reaches host before acknowledgement") { helloCount.get() == 1 }
                scenario.recreate()
                socket.get().send(acceptance().toString())
                await("pending pairing completes on recreated screen") {
                    var paired = false
                    scenario.onActivity { paired = it.connectionState.paired }
                    paired
                }
                assertEquals("pairing code is sent once", 1, helloCount.get())
                scenario.onActivity { it.finish() }
            }
        } finally { ClientDependencies.sessionStore = previous; server.shutdown() }
    }

    private class FixtureDiscovery : MacDiscovery {
        @Volatile var callback: ((List<String>) -> Unit)? = null
        @Volatile var expected: String? = null
        override fun start(serverID: String?, serviceName: String?, resolved: (List<String>) -> Unit) {
            expected = serverID; callback = resolved
        }
        override fun stop() {}
    }

    @Test fun discoveryRecoversAChangedAddressAndRetiredCallbacksCannotReconnectForgottenMac() {
        val server = MockWebServer()
        val requests = CopyOnWriteArrayList<JSONObject>()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = JSONObject(text)
                if (message.optString("type") == "hello") { requests.add(message); webSocket.send(acceptance().toString()) }
            }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val store = MemorySessionStore().apply { saveMac(TrustedMac("recovery-fixture", "fixture-trust-only", listOf("ws://127.0.0.1:1"))) }
        val browser = FixtureDiscovery()
        val current = AtomicReference(ClientState())
        val client = ControllerClient(store, browser) { current.set(it) }
        try {
            client.resume()
            await("discovery starts for trusted server identity") { browser.callback != null }
            assertEquals("recovery-fixture", browser.expected)
            val callback = browser.callback!!
            callback(listOf("ws://127.0.0.1:${server.port}"))
            await("changed endpoint reconnects") { current.get().paired }
            assertEquals("fixture-trust-only", requests.single().getString("authToken"))
            assertEquals("ws://127.0.0.1:${server.port}", store.loadMac()!!.urls.first())
            client.forgetMac()
            await("forgotten") { !current.get().paired && !current.get().canReconnect }
            callback(listOf("ws://127.0.0.1:${server.port}"))
            client.networkAvailable(); client.resume()
            SystemClock.sleep(1200)
            assertEquals(1, requests.size)
        } finally { client.dispose(); server.shutdown() }
    }

    @Test fun serviceOnlyQrDiscoversAndPairsWithoutAnInitialUrl() {
        val server = MockWebServer()
        val hello = AtomicReference<JSONObject>()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                val message = JSONObject(text)
                if (message.optString("type") == "hello") { hello.set(message); webSocket.send(acceptance().toString()) }
            }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val browser = FixtureDiscovery()
        val current = AtomicReference(ClientState())
        val client = ControllerClient(MemorySessionStore(), browser) { current.set(it) }
        try {
            client.connect(PairingTarget.parse("""{"type":"pocketpad-pair","serverID":"recovery-fixture","urls":[],"pairingCode":"123456"}"""))
            await("nearby pairing started") { browser.callback != null }
            browser.callback!!(listOf("ws://127.0.0.1:${server.port}"))
            await("nearby Mac paired") { current.get().paired }
            assertEquals("123456", hello.get().getString("pairingCode"))
        } finally { client.disconnect(); client.dispose(); server.shutdown() }
    }

    @Test fun unexpectedServerIdentityCannotReplaceSavedTrustOrProfile() {
        val server = MockWebServer()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (JSONObject(text).optString("type") == "hello") webSocket.send(acceptance("wrong-server").toString())
            }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val store = MemorySessionStore().apply { saveMac(TrustedMac("expected-server", "existing-fixture-trust", listOf("ws://127.0.0.1:${server.port}"))) }
        val current = AtomicReference(ClientState())
        val client = ControllerClient(store) { current.set(it) }
        try {
            client.resume()
            await("identity mismatch reported") { current.get().error != null }
            assertFalse(current.get().paired)
            assertEquals("existing-fixture-trust", store.loadMac()!!.authToken)
            assertEquals("expected-server", store.loadMac()!!.serverID)
            assertTrue(store.loadSnapshot().profiles.isEmpty())
        } finally { client.dispose(); server.shutdown() }
    }

    @Test fun optionalMacSavedTrustAndNearbyDiscovery() {
        val qr = InstrumentationRegistry.getArguments().getString("macPairingQR")
        org.junit.Assume.assumeTrue("Supply macPairingQR for live Mac recovery verification", qr != null)
        val target = PairingTarget.parse(qr!!)
        assertNotNull("live Mac must have a stable server ID", target.serverID)
        val context = instrumentation.targetContext
        val store = AndroidSessionStore(context)
        val current = AtomicReference(ClientState())
        var client = ControllerClient(store, NsdMacDiscovery(context)) { current.set(it) }
        var original: TrustedMac? = null
        try {
            // First prove the QR's service identity works without a cached address.
            client.connect(PairingTarget(emptyList(), target.code, target.serverID, target.serviceName))
            await("real Bonjour service-only QR pairing") { current.get().paired || current.get().error != null }
            assertTrue(current.get().error, current.get().paired)
            assertTrue(current.get().snapshot.profiles.isNotEmpty())
            original = store.loadMac()
            assertNotNull("real credential stored through Android Keystore", original)
            val profileID = current.get().snapshot.selectedID
            client.disconnect()
            await("first client disconnects") { !current.get().paired }
            client.dispose()
            // Simulate a changed Wi-Fi address, then instantiate a fresh client/store.
            store.saveMac(TrustedMac(original!!.serverID, original!!.authToken, listOf("ws://127.0.0.1:1")))
            current.set(ClientState())
            client = ControllerClient(AndroidSessionStore(context), NsdMacDiscovery(context)) { current.set(it) }
            client.resume()
            await("trusted discovery recovers an unavailable saved address") { current.get().paired }
            assertEquals(profileID, current.get().snapshot.selectedID)
            assertEquals(target.serverID, store.loadMac()!!.serverID)
            assertNotEquals("ws://127.0.0.1:1", store.loadMac()!!.urls.first())
            File(context.cacheDir, "session-recovery-result.json").writeText(JSONObject()
                .put("serviceOnlyPairing", true).put("encryptedTrustReload", true)
                .put("changedAddressDiscovery", true).put("profileCount", current.get().snapshot.profiles.size).toString())
            client.disconnect()
            await("live recovery client disconnects") { !current.get().paired }
        } finally {
            client.disconnect(); client.dispose()
            original?.let { store.saveMac(it) } // Leave the user's known reachable endpoint saved even if discovery fails.
        }
    }

}
