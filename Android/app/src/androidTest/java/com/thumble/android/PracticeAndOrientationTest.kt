package com.thumble.android

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.test.core.app.ActivityScenario
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
import org.junit.runner.RunWith
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class PracticeAndOrientationTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun profile() = JSONObject(instrumentation.context.assets.open("controller-templates/v1/productivityStarter.json")
        .bufferedReader().use { it.readText() }).getJSONObject("profile")
    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 12_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20)
        assertTrue(description, condition())
    }
    private fun findSurface(view: View): ControllerSurface? {
        if (view is ControllerSurface) return view
        if (view is android.view.ViewGroup) for (i in 0 until view.childCount) findSurface(view.getChildAt(i))?.let { return it }
        return null
    }
    private fun snapshot(vararg profiles: JSONObject) = ProfileSnapshot().applying(WireCodec.message("gamepad_profiles")
        .put("gamepadProfiles", JSONArray(profiles.toList())).put("gamepadProfileID", profiles.first().getString("id")))

    @Test fun connectedPracticeReleasesExistingHoldSuppressesEdgesAndRejectsRetiredSurface() {
        val server = MockWebServer()
        val frames = CopyOnWriteArrayList<ByteArray>()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (JSONObject(text).optString("type") == "hello") webSocket.send(WireCodec.message("pairing_accepted")
                    .put("inputProtocolVersion", 3).put("gamepadProfiles", JSONArray().put(profile()))
                    .put("gamepadProfileID", profile().getString("id")).toString())
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { frames.add(bytes.toByteArray()) }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val current = AtomicReference(ClientState())
        val store = MemorySessionStore()
        val client = ControllerClient(store) { current.set(it) }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}", "123456"))
            await("paired") { current.get().paired }
            val id = current.get().snapshot.selected!!.controls(false).first().id
            val originalRevision = current.get().surfaceRevision
            client.edge(id, true, 101, originalRevision)
            await("live down") { frames.any { it.size == 56 } }
            client.setPracticeMode(true)
            await("practice active") { current.get().practiceMode }
            val before = frames.count { it.size == 56 }
            val practiceRevision = current.get().surfaceRevision
            assertTrue(practiceRevision > originalRevision)
            assertTrue(store.loadPreferences().practiceMode)
            client.edge(id, true, 102, practiceRevision)
            client.edge(id, false, 102, practiceRevision)
            SystemClock.sleep(550)
            assertEquals("practice never sends buttons or refreshes old live holds", before, frames.count { it.size == 56 })
            assertTrue("entering practice emits a release barrier", frames.any { it.size != 56 &&
                runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("type") == "release_all" }.getOrDefault(false) })
            client.setPracticeMode(false)
            await("live input restored") { !current.get().practiceMode }
            client.edge(id, true, 103, practiceRevision)
            client.edge(id, true, 104, current.get().surfaceRevision)
            client.edge(id, false, 104, current.get().surfaceRevision)
            await("new live press only") { frames.count { it.size == 56 } == before + 2 }
        } finally { client.disconnect(); client.dispose(); server.shutdown() }
    }

    @Test fun offlinePracticeSwitchesSavedProfilesWithoutOpeningAConnection() {
        val server = MockWebServer().apply { start(InetAddress.getByName("127.0.0.1"), 0) }
        val first = profile()
        val second = profile().put("id", UUID.randomUUID().toString()).put("name", "Second saved keypad")
        val store = MemorySessionStore().apply {
            saveSnapshot(snapshot(first, second))
            saveMac(TrustedMac("offline-fixture", "unused-fixture-token", listOf("ws://127.0.0.1:${server.port}")))
        }
        val current = AtomicReference(ClientState())
        val client = ControllerClient(store) { current.set(it) }
        try {
            client.viewSavedKeypad()
            await("saved keypad") { current.get().viewingSaved }
            assertTrue(current.get().practiceMode)
            assertFalse(current.get().paired)
            val secondID = UUID.fromString(second.getString("id"))
            client.selectProfile(secondID)
            await("offline selection") { current.get().snapshot.selectedID == secondID }
            assertEquals(secondID, store.loadSnapshot().selectedID)
            val id = current.get().snapshot.selected!!.controls(false).first().id
            client.edge(id, true, 1, current.get().surfaceRevision)
            client.suspend(); client.resume(); client.networkAvailable()
            SystemClock.sleep(600)
            assertEquals("offline practice does not contact the saved Mac", 0, server.requestCount)
            assertTrue(store.loadPreferences().practiceMode)
        } finally { client.dispose(); server.shutdown() }
    }

    @Test fun profileLocksSwitchNativeOrientationWithoutActivityRecreationAndClearTouches() {
        val landscape = profile().put("orientationPreference", "landscape")
        val portrait = profile().put("id", UUID.randomUUID().toString()).put("orientationPreference", "portrait")
        val store = MemorySessionStore().apply { saveSnapshot(snapshot(landscape, portrait)) }
        val previous = ClientDependencies.sessionStore
        ClientDependencies.sessionStore = { store }
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { it.showSavedKeypad() }
                fun oriented(value: Int): Boolean {
                    var matches = false
                    scenario.onActivity {
                        val surface = findSurface(it.window.decorView)
                        matches = it.connectionState.viewingSaved && it.resources.configuration.orientation == value &&
                            surface != null && surface.width > 0 && surface.height > 0 && surface.childCount > 0
                    }
                    return matches
                }
                await("landscape profile lock") { oriented(Configuration.ORIENTATION_LANDSCAPE) }
                var identity = 0
                scenario.onActivity { activity ->
                    identity = System.identityHashCode(activity)
                    assertEquals(ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE, activity.requestedOrientation)
                    val surface = findSurface(activity.window.decorView)!!
                    val child = surface.getChildAt(0)
                    val event = MotionEvent.obtain(SystemClock.uptimeMillis(), SystemClock.uptimeMillis(), MotionEvent.ACTION_DOWN,
                        child.left + child.width / 2f, child.top + child.height / 2f, 0)
                    surface.dispatchTouchEvent(event); event.recycle()
                    assertTrue("native finger is held", child.isPressed)
                    activity.selectProfile(UUID.fromString(portrait.getString("id")))
                }
                await("portrait profile lock") { oriented(Configuration.ORIENTATION_PORTRAIT) }
                scenario.onActivity { activity ->
                    assertEquals("orientation change retains the connection owner", identity, System.identityHashCode(activity))
                    assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, activity.requestedOrientation)
                    assertTrue(activity.connectionState.practiceMode)
                    assertFalse(activity.connectionState.paired)
                    activity.finish()
                }
            }
        } finally { ClientDependencies.sessionStore = previous }
    }
}
