package com.thumble.android

import android.graphics.Bitmap
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.MultiFormatReader
import com.google.zxing.MultiFormatWriter
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
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
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class VerticalSliceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun profile(): JSONObject = JSONObject(instrumentation.context.assets.open("controller-templates/v1/productivityStarter.json")
        .bufferedReader().use { it.readText() }).getJSONObject("profile")

    private fun await(description: String, timeoutMs: Long = 10_000, condition: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (!condition() && SystemClock.elapsedRealtime() < end) SystemClock.sleep(20)
        assertTrue(description, condition())
    }
    @Test fun realProfileMultitouchMirrorsOverUDPAndFallsBackToWebSocket() {
        val server = MockWebServer()
        val wsFrames = CopyOnWriteArrayList<ByteArray>()
        val udpFrames = CopyOnWriteArrayList<ByteArray>()
        val current = AtomicReference(ClientState())
        val rawProfile = profile()
        var hostSocket: WebSocket? = null
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) { hostSocket = webSocket }
            override fun onMessage(webSocket: WebSocket, text: String) {
                val hello = JSONObject(text)
                if (hello.optString("type") == "hello") {
                    assertEquals("123456", hello.getString("pairingCode"))
                    webSocket.send(WireCodec.message("pairing_accepted").put("inputProtocolVersion", 3)
                        .put("serverID", "fixture-host").put("realtimeToken", "fixture-only-token")
                        .put("gamepadProfiles", JSONArray().put(rawProfile)).put("gamepadProfileID", rawProfile.getString("id")).toString())
                }
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { wsFrames.add(bytes.toByteArray()) }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val udp = DatagramSocket(server.port, InetAddress.getByName("127.0.0.1"))
        val reader = Thread {
            try { while (!udp.isClosed) {
                val packet = DatagramPacket(ByteArray(8192), 8192)
                udp.receive(packet)
                udpFrames.add(packet.data.copyOf(packet.length))
            } } catch (_: Exception) { }
        }.apply { start() }
        val client = ControllerClient { current.set(it) }
        try {
            val qr = WireCodec.message("unused").put("type", "pocketpad-pair").put("urls", JSONArray().put("ws://127.0.0.1:${server.port}"))
                .put("pairingCode", "123456").put("serverID", "fixture-host").toString()
            // Exercise the scanner decoder with a real QR bitmap, then the same parser used by ScanContract.
            val bits = MultiFormatWriter().encode(qr, BarcodeFormat.QR_CODE, 800, 800)
            val pixels = IntArray(800 * 800) { i -> if (bits[i % 800, i / 800]) android.graphics.Color.BLACK else android.graphics.Color.WHITE }
            val decoded = MultiFormatReader().decode(BinaryBitmap(HybridBinarizer(RGBLuminanceSource(800, 800, pixels)))).text
            client.connect(PairingTarget.parse(decoded))
            await("paired with real profile") { current.get().paired }
            assertEquals(rawProfile.getString("id"), current.get().snapshot.selected!!.id.toString().uppercase())
            await("UDP authentication hello") { udpFrames.any { it.size != 56 && runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("realtimeToken") == "fixture-only-token" }.getOrDefault(false) } }
            lateinit var surface: ControllerSurface
            instrumentation.runOnMainSync {
                surface = ControllerSurface(instrumentation.targetContext)
                val revision = current.get().surfaceRevision
                surface.onEdge = { id, down, press -> client.edge(id, down, press, revision) }
                surface.onReleaseAll = { client.releaseAll() }
                surface.show(current.get().snapshot.selected, revision, true, false)
                surface.measure(View.MeasureSpec.makeMeasureSpec(1000, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(420, View.MeasureSpec.EXACTLY))
                surface.layout(0, 0, 1000, 420)
            }
            val downTime = SystemClock.uptimeMillis()
            fun event(action: Int, pointers: Int) {
                instrumentation.runOnMainSync {
                    val props = Array(pointers) { i -> MotionEvent.PointerProperties().apply { id = i + 5; toolType = MotionEvent.TOOL_TYPE_FINGER } }
                    val coords = Array(pointers) { i -> MotionEvent.PointerCoords().apply {
                        val child = surface.getChildAt(if (i == 0) 0 else 4)
                        x = child.left + child.width / 2f; y = child.top + child.height / 2f; pressure = 1f; size = 1f
                    } }
                    val e = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, pointers, props, coords, 0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
                    surface.dispatchTouchEvent(e); e.recycle()
                }
            }
            event(MotionEvent.ACTION_DOWN, 1)
            event(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2)
            await("both finger downs mirrored") { wsFrames.count { it.size == 56 && it[21] == 1.toByte() } >= 2 }
            await("held presses refreshed") { wsFrames.count { it.size == 56 && it[21] == 1.toByte() } >= 4 }
            event(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2)
            event(MotionEvent.ACTION_UP, 1)
            await("both finger ups mirrored") { wsFrames.count { it.size == 56 && it[21] == 2.toByte() } == 2 }
            val upFrames = wsFrames.filter { it.size == 56 && it[21] == 2.toByte() }
            await("identical UDP and WebSocket up frames") { upFrames.all { frame -> udpFrames.any { it.contentEquals(frame) } } }
            client.setUDPEnabled(false)
            await("UDP disabled") { !current.get().udpEnabled }
            val udpBefore = udpFrames.count { it.size == 56 }
            val wsBefore = wsFrames.count { it.size == 56 }
            event(MotionEvent.ACTION_DOWN, 1); event(MotionEvent.ACTION_CANCEL, 1)
            await("cancel sends up over fallback") { wsFrames.count { it.size == 56 } >= wsBefore + 2 }
            assertEquals(udpBefore, udpFrames.count { it.size == 56 })
            // Host emergency release invalidates touch surface state, including generation adoption.
            val oldRevision = current.get().surfaceRevision
            hostSocket!!.send(WireCodec.message("release_all", 100_000).toString())
            await("host emergency release invalidates surface") { current.get().surfaceRevision > oldRevision }
            val framesBeforeStaleTouch = wsFrames.count { it.size == 56 }
            client.edge(current.get().snapshot.selected!!.controls(true).first().id, true, 999, oldRevision)
            SystemClock.sleep(300)
            assertEquals("touch from retired surface cannot re-press", framesBeforeStaleTouch, wsFrames.count { it.size == 56 })
            client.disconnect()
            await("explicit disconnect") { !current.get().paired }
        } finally {
            client.dispose(); udp.close(); reader.join(1000); hostSocket?.close(1000, "Test complete"); server.shutdown()
        }
    }

    @Test fun optionalMacControllerUIScreen() {
        val qr = InstrumentationRegistry.getArguments().getString("macPairingQR")
        org.junit.Assume.assumeTrue("Provide -e macPairingQR for the live UI test", qr != null)
        val target = PairingTarget.parse(qr!!)
        val observed = AtomicReference(ClientState())
        val previousStore = ClientDependencies.sessionStore
        val fixtureStore = MemorySessionStore()
        ClientDependencies.sessionStore = { fixtureStore }
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { it.connect(target) }
            await("visible controller paired", 30_000) {
                scenario.onActivity { observed.set(it.connectionState) }
                observed.get().paired || observed.get().error != null
            }
            assertTrue(observed.get().error, observed.get().paired)
            await("authoritative profile orientation applied") {
                var ready = false
                scenario.onActivity { activity ->
                    val value = activity.connectionState
                    val orientation = activity.resources.configuration.orientation
                    ready = value.paired && when (value.snapshot.selected?.orientationPreference) {
                        "landscape" -> orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
                        "portrait" -> orientation == android.content.res.Configuration.ORIENTATION_PORTRAIT
                        else -> true
                    }
                }
                ready
            }
            await("paired controller composed and laid out") {
                var ready = false
                scenario.onActivity { activity ->
                    fun find(view: View): ControllerSurface? {
                        if (view is ControllerSurface) return view
                        if (view is android.view.ViewGroup) for (i in 0 until view.childCount) {
                            find(view.getChildAt(i))?.let { return it }
                        }
                        return null
                    }
                    val surface = find(activity.window.decorView)
                    ready = surface != null && surface.width > 0 && surface.height > 0 && surface.childCount >= 2
                }
                ready
            }
            scenario.onActivity { activity ->
                fun find(view: android.view.View): ControllerSurface? {
                    if (view is ControllerSurface) return view
                    if (view is android.view.ViewGroup) for (i in 0 until view.childCount) {
                        find(view.getChildAt(i))?.let { return it }
                    }
                    return null
                }
                val surface = find(activity.window.decorView)
                assertNotNull("native control surface is visible", surface)
                assertTrue("real profile exposes multiple controls", surface!!.childCount >= 2)
                assertTrue("canvas has usable dimensions", surface.width > 0 && surface.height > 0)
                val first = surface.getChildAt(0)
                val second = surface.getChildAt(1)
                assertFalse("default buttons occupy distinct positions", first.left == second.left && first.top == second.top)
            }
            if (InstrumentationRegistry.getArguments().getString("macRequireUDP") == "true") {
                assertTrue("receiver advertised UDP", observed.get().udpAvailable)
                assertTrue("UDP remains enabled throughout packet-loss test", observed.get().udpEnabled)
            }
            if (InstrumentationRegistry.getArguments().getString("macExerciseInput") == "true") {
                val ids = InstrumentationRegistry.getArguments().getString("macControlIDs")!!.split(",")
                val downTime = SystemClock.uptimeMillis()
                fun touch(action: Int, count: Int) {
                    scenario.onActivity { activity ->
                        fun find(view: View): ControllerSurface? {
                            if (view is ControllerSurface) return view
                            if (view is android.view.ViewGroup) for (i in 0 until view.childCount) {
                                find(view.getChildAt(i))?.let { return it }
                            }
                            return null
                        }
                        val surface = find(activity.window.decorView)!!
                        val config = activity.resources.configuration
                        val controls = activity.connectionState.snapshot.selected!!.controls(config.screenWidthDp >= config.screenHeightDp)
                        val props = Array(count) { i -> MotionEvent.PointerProperties().apply { id = i + 30; toolType = MotionEvent.TOOL_TYPE_FINGER } }
                        val coords = Array(count) { i -> MotionEvent.PointerCoords().apply {
                            val index = controls.indexOfFirst { it.id.toString().equals(ids[i], ignoreCase = true) }
                            assertTrue("requested keyboard control exists", index >= 0)
                            val child = surface.getChildAt(index)
                            x = child.left + child.width / 2f; y = child.top + child.height / 2f; pressure = 1f; size = 1f
                        } }
                        val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, count, props, coords, 0, 0, 1f, 1f, 0, 0, android.view.InputDevice.SOURCE_TOUCHSCREEN, 0)
                        surface.dispatchTouchEvent(event); event.recycle()
                    }
                }
                touch(MotionEvent.ACTION_DOWN, 1)
                touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2)
                SystemClock.sleep(600)
                touch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 2)
                touch(MotionEvent.ACTION_UP, 1)
                SystemClock.sleep(200)
                touch(MotionEvent.ACTION_DOWN, 1)
                SystemClock.sleep(150)
                touch(MotionEvent.ACTION_CANCEL, 1)
                SystemClock.sleep(300)
                if (InstrumentationRegistry.getArguments().getString("macRequireUDP") == "true") {
                    scenario.onActivity { observed.set(it.connectionState) }
                    assertTrue("Android kept UDP enabled while the network dropped packets", observed.get().udpEnabled)
                    assertTrue("Android continued sending real UDP frames", observed.get().udpFrames >= 6)
                }
            }
            instrumentation.waitForIdleSync()
            val copied = CountDownLatch(1)
            val copyStatus = java.util.concurrent.atomic.AtomicInteger(-1)
            lateinit var screenshot: Bitmap
            scenario.onActivity { activity ->
                screenshot = Bitmap.createBitmap(activity.window.decorView.width, activity.window.decorView.height, Bitmap.Config.ARGB_8888)
                android.view.PixelCopy.request(activity.window, screenshot, { result ->
                    copyStatus.set(result); copied.countDown()
                }, android.os.Handler(android.os.Looper.getMainLooper()))
            }
            assertTrue("controller frame copied", copied.await(5, TimeUnit.SECONDS))
            assertEquals(android.view.PixelCopy.SUCCESS, copyStatus.get())
            java.io.File(instrumentation.targetContext.cacheDir, "vertical-slice-controller.png").outputStream().use {
                screenshot.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
            screenshot.recycle()
            scenario.onActivity { it.finish() }
        } } finally { ClientDependencies.sessionStore = previousStore }
    }

    @Test fun optionalMacHostPairingWithRealProfile() {
        val qr = InstrumentationRegistry.getArguments().getString("macPairingQR")
        org.junit.Assume.assumeTrue("Provide -e macPairingQR to run against a live Mac", qr != null)
        val current = AtomicReference(ClientState())
        val client = ControllerClient { current.set(it) }
        try {
            client.connect(PairingTarget.parse(qr!!))
            await("live Mac accepted pairing: ${current.get().error}") { current.get().paired || current.get().error != null }
            assertTrue(current.get().error, current.get().paired)
            assertNotNull(current.get().snapshot.selected)
            assertTrue(current.get().snapshot.selected!!.controls(false).isNotEmpty())
            if (InstrumentationRegistry.getArguments().getString("macRequireUDP") == "true") {
                assertTrue("native Mac advertised a UDP token", current.get().udpAvailable)
            }
            if (InstrumentationRegistry.getArguments().getString("macExerciseInput") == "true") {
                val controls = current.get().snapshot.selected!!.controls(false).filter { it.kind == "button" }
                assertTrue("two executable controls", controls.size >= 2)
                val revision = current.get().surfaceRevision
                client.edge(controls[0].id, true, 701, revision)
                client.edge(controls[1].id, true, 702, revision)
                SystemClock.sleep(600)
                client.edge(controls[0].id, false, 701, revision)
                client.edge(controls[1].id, false, 702, revision)
                client.releaseAll()
                client.setUDPEnabled(false)
                await("fallback selected") { !current.get().udpEnabled }
                client.edge(controls[0].id, true, 703, revision)
                SystemClock.sleep(150)
                client.edge(controls[0].id, false, 703, revision)
                await("input packets sent") { current.get().webSocketFrames >= 8 }
                if (InstrumentationRegistry.getArguments().getString("macRequireUDP") == "true") {
                    assertTrue("UDP packets sent", current.get().udpFrames >= 4)
                }
                SystemClock.sleep(150)
                client.releaseAll()
                SystemClock.sleep(300)
            }
        } finally { client.disconnect(); client.dispose() }
    }
}
