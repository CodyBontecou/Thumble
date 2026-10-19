package com.thumble.android

import android.os.Bundle
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
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
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class AdvancedControlsDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val buttonID = UUID.fromString("b979b12b-aa10-4bb0-8220-6c23fed80200")
    private val joystickID = UUID.fromString("b979b12b-aa10-4bb0-8220-6c23fed80201")
    private val triggerID = UUID.fromString("b979b12b-aa10-4bb0-8220-6c23fed80202")
    private val padID = UUID.fromString("b979b12b-aa10-4bb0-8220-6c23fed80203")
    private fun await(description: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20)
        assertTrue(description, condition())
    }
    private fun profile(): JSONObject {
        val raw = JSONObject(instrumentation.context.assets.open("controller-templates/v1/productivityStarter.json").bufferedReader().use { it.readText() }).getJSONObject("profile")
        val elements = JSONArray()
        for ((index, kind) in listOf("button", "joystick", "trigger", "trackpad").withIndex()) {
            val id = listOf(buttonID, joystickID, triggerID, padID)[index]
            val element = JSONObject().put("id", id.toString()).put("label", kind).put("kind", kind)
                .put("layout", JSONObject().put("centerX", .125 + index * .25).put("centerY", .5)
                    .put("shape", if (kind == "joystick") "circle" else "rectangle").put("widthScale", 1).put("heightScale", 1))
            if (kind == "joystick") element.put("joystickOutputSettings", JSONObject().put("analogTarget", "leftStick"))
            if (kind == "trigger") element.put("triggerSettings", JSONObject().put("target", "right").put("sendsDigitalButton", true))
            elements.put(element)
        }
        for (key in listOf("customization", "portraitCustomization", "landscapeCustomization")) {
            raw.put(key, JSONObject().put("elements", elements).put("controlScale", "standard"))
        }
        return raw
    }
    private fun messages(frames: List<ByteArray>) = frames.filter { it.size != 56 }
        .mapNotNull { runCatching { JSONObject(it.toString(Charsets.UTF_8)) }.getOrNull() }
    private fun inputCount(frames: List<ByteArray>) = frames.count { it.size == 56 } + messages(frames).count { it.optString("type") in setOf("pointer", "gamepad_analog") }

    @Test fun mixedNativePointersMirrorPartsAndAnalogThenFallbackAndPracticeNeutralizeEverything() {
        val server = MockWebServer()
        val ws = CopyOnWriteArrayList<ByteArray>()
        val udp = CopyOnWriteArrayList<ByteArray>()
        val current = AtomicReference(ClientState())
        val raw = profile()
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (JSONObject(text).optString("type") == "hello") webSocket.send(WireCodec.message("pairing_accepted")
                    .put("inputProtocolVersion", 3).put("serverID", "advanced-fixture").put("realtimeToken", "advanced-fixture-token")
                    .put("virtualGamepadStatus", JSONObject().put("phase", "recording-only"))
                    .put("gamepadProfiles", JSONArray().put(raw)).put("gamepadProfileID", raw.getString("id")).toString())
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { ws.add(bytes.toByteArray()) }
        }))
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        val socket = DatagramSocket(server.port, InetAddress.getByName("127.0.0.1"))
        val reader = Thread {
            try { while (!socket.isClosed) {
                val packet = DatagramPacket(ByteArray(8192), 8192)
                socket.receive(packet); udp.add(packet.data.copyOf(packet.length))
            } } catch (_: Exception) { }
        }.apply { start() }
        val client = ControllerClient { current.set(it) }
        lateinit var surface: ControllerSurface
        instrumentation.runOnMainSync { surface = ControllerSurface(instrumentation.targetContext) }
        fun bind() = instrumentation.runOnMainSync {
            val revision = current.get().surfaceRevision
            surface.onEdge = { id, down, press -> client.edge(id, down, press, revision) }
            surface.onPartEdge = { id, part, down, press -> client.elementEdge(id, part, down, press, revision) }
            surface.onStick = { target, x, y, final -> client.stick(target, x, y, final, revision) }
            surface.onTrigger = { target, value, final -> client.trigger(target, value, final, revision) }
            surface.onPointer = { kind, x, y, button, down -> client.pointer(kind, x, y, button, down, revision) }
            surface.onReleaseAll = { client.releaseAll() }
            surface.show(current.get().snapshot.selected, revision, true, false)
            surface.measure(View.MeasureSpec.makeMeasureSpec(1600, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(700, View.MeasureSpec.EXACTLY))
            surface.layout(0, 0, 1600, 700)
        }
        fun point(index: Int, x: Float = .5f, y: Float = .5f): Pair<Float, Float> {
            var result = 0f to 0f
            instrumentation.runOnMainSync { val child = surface.getChildAt(index); result = child.left + child.width * x to child.top + child.height * y }
            return result
        }
        val began = SystemClock.uptimeMillis()
        fun touch(action: Int, vararg contacts: Pair<Int, Pair<Float, Float>>) = instrumentation.runOnMainSync {
            val properties = contacts.map { (id, _) -> MotionEvent.PointerProperties().apply { this.id = id; toolType = MotionEvent.TOOL_TYPE_FINGER } }.toTypedArray()
            val coordinates = contacts.map { (_, point) -> MotionEvent.PointerCoords().apply { x = point.first; y = point.second; pressure = 1f; size = 1f } }.toTypedArray()
            val event = MotionEvent.obtain(began, SystemClock.uptimeMillis(), action, contacts.size, properties, coordinates, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            surface.dispatchTouchEvent(event); event.recycle()
        }
        try {
            client.connect(PairingTarget.manual("ws://127.0.0.1:${server.port}", "123456"))
            await("paired") { current.get().paired }
            assertEquals("recording-only", current.get().virtualGamepadStatus?.optString("phase"))
            await("authenticated UDP hello") { messages(udp).any { it.optString("realtimeToken") == "advanced-fixture-token" } }
            bind()
            val joy = point(1, .92f, .5f); val button = point(0)
            touch(MotionEvent.ACTION_DOWN, 5 to joy)
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 5 to joy, 8 to button)
            await("joystick direction and independent button") { ws.count { it.size == 56 && it[21] == 1.toByte() } >= 2 }
            await("joystick hold refresh") { ws.count { it.size == 56 && it[3] == 6.toByte() && it[20] == 4.toByte() && it[21] == 1.toByte() } >= 2 }
            touch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 5 to joy, 8 to button)
            touch(MotionEvent.ACTION_UP, 5 to joy)
            await("direction release and analog neutral") { ws.any { it.size == 56 && it[20] == 4.toByte() && it[21] == 2.toByte() } &&
                messages(ws).any { it.optString("analogStick") == "left" && it.optDouble("analogX", -1.0) == 0.0 } }
            val trigger = point(2, .5f, .1f)
            touch(MotionEvent.ACTION_DOWN, 7 to trigger)
            await("trigger threshold down") { ws.any { it.size == 56 && it[20] == 5.toByte() && it[21] == 1.toByte() } }
            touch(MotionEvent.ACTION_CANCEL, 7 to trigger)
            await("trigger threshold up and final neutral") { ws.any { it.size == 56 && it[20] == 5.toByte() && it[21] == 2.toByte() } &&
                messages(ws).any { it.optString("analogTrigger") == "right" && it.optDouble("analogValue", -1.0) == 0.0 } }
            val pad1 = point(3, .3f, .3f); val pad2 = point(3, .7f, .7f)
            touch(MotionEvent.ACTION_DOWN, 10 to pad1)
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 10 to pad1, 11 to pad2)
            touch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), 10 to pad1, 11 to pad2)
            touch(MotionEvent.ACTION_UP, 10 to pad1)
            await("two finger tap right click pair") { messages(ws).count { it.optString("pointerButton") == "right" } == 2 }
            val mirrored = ws.filter { it.size == 56 || runCatching { JSONObject(it.toString(Charsets.UTF_8)).optString("type") in setOf("pointer", "gamepad_analog") }.getOrDefault(false) }
            await("all advanced frames match UDP and reliable mirrors") { mirrored.all { frame -> udp.any { it.contentEquals(frame) } } }
            client.setUDPEnabled(false)
            await("fallback enabled") { !current.get().udpEnabled }
            val before = messages(ws).count { it.optString("pointerEvent") == "move" }
            touch(MotionEvent.ACTION_DOWN, 12 to pad1)
            touch(MotionEvent.ACTION_MOVE, 12 to (pad1.first + 80f to pad1.second + 20f))
            touch(MotionEvent.ACTION_CANCEL, 12 to pad1)
            await("trackpad moves through reliable fallback") { messages(ws).count { it.optString("pointerEvent") == "move" } > before }
            client.setPracticeMode(true)
            await("practice") { current.get().practiceMode }
            bind()
            val count = inputCount(ws)
            touch(MotionEvent.ACTION_DOWN, 15 to point(1, .9f, .2f))
            touch(MotionEvent.ACTION_CANCEL, 15 to point(1))
            touch(MotionEvent.ACTION_DOWN, 16 to point(2, .5f, .1f))
            touch(MotionEvent.ACTION_CANCEL, 16 to point(2))
            touch(MotionEvent.ACTION_DOWN, 17 to point(3))
            touch(MotionEvent.ACTION_UP, 17 to point(3))
            SystemClock.sleep(550)
            assertEquals("practice suppresses all advanced paths and refreshes", count, inputCount(ws))
        } finally { client.disconnect(); client.dispose(); socket.close(); reader.join(1000); server.shutdown() }
    }

    @Test fun accessibleDirectionsTriggerProgressAndTrackpadClickUseCanonicalOutputCallbacks() {
        lateinit var surface: ControllerSurface
        val parts = mutableListOf<Pair<InputPart, Boolean>>()
        val analog = mutableListOf<Triple<String, Double, Boolean>>()
        val clicks = mutableListOf<Pair<String?, Boolean?>>()
        instrumentation.runOnMainSync {
            surface = ControllerSurface(instrumentation.targetContext)
            surface.onPartEdge = { _, part, down, _ -> parts.add(part to down) }
            surface.onTrigger = { target, value, final -> analog.add(Triple(target, value, final)) }
            surface.onPointer = { _, _, _, button, down -> clicks.add(button to down) }
            surface.show(ControllerProfile.parse(profile()), 1, true, false)
            surface.measure(View.MeasureSpec.makeMeasureSpec(1600, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(700, View.MeasureSpec.EXACTLY))
            surface.layout(0, 0, 1600, 700)
            assertTrue(surface.getChildAt(1).performAccessibilityAction(R.id.control_left, null))
            assertTrue(surface.getChildAt(2).performAccessibilityAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id,
                Bundle().apply { putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, .8f) }))
            assertTrue(surface.getChildAt(3).performAccessibilityAction(R.id.control_right_click, null))
            surface.cancelTouches()
        }
        assertEquals(listOf(InputPart.JOYSTICK_LEFT to true, InputPart.JOYSTICK_LEFT to false), parts.take(2))
        assertTrue(parts.contains(InputPart.TRIGGER_DIGITAL to true)); assertEquals(InputPart.TRIGGER_DIGITAL to false, parts.last())
        assertEquals("right", analog.first().first); assertEquals(0.0, analog.last().second, 0.0); assertTrue(analog.last().third)
        assertEquals(listOf("right" to true, "right" to false), clicks)
    }

    @Test fun trackpadAccessibilityActionsRetirePhysicalTouchesAndRefreshPressedState() {
        instrumentation.runOnMainSync {
            val surface = ControllerSurface(instrumentation.targetContext)
            val clicks = mutableListOf<Pair<String?, Boolean?>>()
            val edges = mutableListOf<Boolean>()
            surface.onPointer = { kind, _, _, button, down ->
                assertEquals("retired fingers must not emit movement", "button", kind)
                clicks.add(button to down)
            }
            surface.onEdge = { _, down, _ -> edges.add(down) }
            surface.show(ControllerProfile.parse(profile()),1,true,false)
            surface.measure(View.MeasureSpec.makeMeasureSpec(1600,View.MeasureSpec.EXACTLY),View.MeasureSpec.makeMeasureSpec(700,View.MeasureSpec.EXACTLY))
            surface.layout(0,0,1600,700)
            fun touch(action: Int, vararg indices: Int) {
                val props = indices.map { MotionEvent.PointerProperties().apply { id=it; toolType=MotionEvent.TOOL_TYPE_FINGER } }.toTypedArray()
                val coords = indices.map { index -> MotionEvent.PointerCoords().apply {
                    val child=surface.getChildAt(index)
                    x=child.left+child.width/2f; y=child.top+child.height/2f; pressure=1f; size=1f
                } }.toTypedArray()
                val event=MotionEvent.obtain(0,SystemClock.uptimeMillis(),action,indices.size,props,coords,0,0,1f,1f,0,0,InputDevice.SOURCE_TOUCHSCREEN,0)
                surface.dispatchTouchEvent(event);event.recycle()
            }
            val pad=surface.getChildAt(3); val button=surface.getChildAt(0)
            touch(MotionEvent.ACTION_DOWN,3)
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),3,0)
            assertTrue(pad.isPressed);assertTrue(button.isPressed)
            assertTrue(pad.performAccessibilityAction(R.id.control_right_click,null))
            assertFalse("right-click refreshes the retired face",pad.isPressed);assertTrue(button.isPressed)
            touch(MotionEvent.ACTION_MOVE,3,0)
            touch(MotionEvent.ACTION_POINTER_UP,3,0)
            assertEquals(listOf("right" to true,"right" to false),clicks)
            assertEquals(listOf(true),edges)
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),0,3)
            assertTrue(pad.isPressed)
            assertTrue(pad.performClick())
            assertFalse("standard click refreshes the retired face",pad.isPressed)
            touch(MotionEvent.ACTION_CANCEL,0,3)
            assertEquals(listOf("right" to true,"right" to false,"left" to true,"left" to false),clicks)
            assertEquals(listOf(true,false),edges)
        }
    }

    /** Invoked by verify-advanced.py against its private recorder or focused real-output probe. */
    @Test fun optionalRustAdvancedInterop() {
        val arguments = InstrumentationRegistry.getArguments()
        val qr = arguments.getString("advancedPairingQR")
        org.junit.Assume.assumeTrue("Provide private advanced receiver pairing data", qr != null)
        val current = AtomicReference(ClientState())
        val client = ControllerClient { current.set(it) }
        lateinit var surface: ControllerSurface
        try {
            client.connect(PairingTarget.parse(qr!!))
            await("Rust advanced fixture paired") { current.get().paired || current.get().error != null }
            assertTrue(current.get().error, current.get().paired)
            assertEquals("Android advanced acceptance", current.get().snapshot.selected?.name)
            assertTrue(current.get().udpAvailable)
            instrumentation.runOnMainSync {
                surface = ControllerSurface(instrumentation.targetContext)
                val revision = current.get().surfaceRevision
                surface.onPartEdge = { id, part, down, press -> client.elementEdge(id, part, down, press, revision) }
                surface.onStick = { target, x, y, final -> client.stick(target, x, y, final, revision) }
                surface.onTrigger = { target, value, final -> client.trigger(target, value, final, revision) }
                surface.onPointer = { kind, x, y, button, down -> client.pointer(kind, x, y, button, down, revision) }
                surface.show(current.get().snapshot.selected, revision, true, false)
                surface.measure(View.MeasureSpec.makeMeasureSpec(1600, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(700, View.MeasureSpec.EXACTLY))
                surface.layout(0, 0, 1600, 700)
            }
            val began = SystemClock.uptimeMillis()
            fun touch(action: Int, vararg points: Triple<Int, Int, Pair<Float, Float>>) = instrumentation.runOnMainSync {
                val props = points.map { (id, _, _) -> MotionEvent.PointerProperties().apply { this.id = id; toolType = MotionEvent.TOOL_TYPE_FINGER } }.toTypedArray()
                val coords = points.map { (_, index, point) -> MotionEvent.PointerCoords().apply {
                    val child = surface.getChildAt(index)
                    x = child.left + child.width * point.first; y = child.top + child.height * point.second; pressure = 1f; size = 1f
                } }.toTypedArray()
                val event = MotionEvent.obtain(began, SystemClock.uptimeMillis(), action, points.size, props, coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
                surface.dispatchTouchEvent(event); event.recycle()
            }
            val joy = Triple(1, 0, .95f to .5f)
            val trigger = Triple(2, 1, .5f to .05f)
            touch(MotionEvent.ACTION_DOWN, joy)
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), joy, trigger)
            SystemClock.sleep(350)
            touch(MotionEvent.ACTION_CANCEL, joy, trigger)
            SystemClock.sleep(150)
            val pad = Triple(3, 2, .3f to .3f)
            touch(MotionEvent.ACTION_DOWN, pad)
            touch(MotionEvent.ACTION_MOVE, Triple(3, 2, .7f to .6f))
            touch(MotionEvent.ACTION_CANCEL, pad)
            touch(MotionEvent.ACTION_DOWN, pad)
            touch(MotionEvent.ACTION_UP, pad)
            val second = Triple(4, 2, .6f to .6f)
            touch(MotionEvent.ACTION_DOWN, pad)
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pad, second)
            touch(MotionEvent.ACTION_MOVE, Triple(3, 2, .4f to .4f), Triple(4, 2, .7f to .7f))
            touch(MotionEvent.ACTION_CANCEL, pad, second)
            touch(MotionEvent.ACTION_DOWN, pad)
            touch(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pad, second)
            touch(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), pad, second)
            touch(MotionEvent.ACTION_UP, pad)
            SystemClock.sleep(150)
            client.setUDPEnabled(false)
            await("WebSocket fallback selected") { !current.get().udpEnabled }
            touch(MotionEvent.ACTION_DOWN, joy)
            SystemClock.sleep(80)
            touch(MotionEvent.ACTION_UP, joy)
            touch(MotionEvent.ACTION_DOWN, pad)
            touch(MotionEvent.ACTION_UP, pad)
            SystemClock.sleep(250)
            if (arguments.getString("pointerDrag") == "true") {
                // Receiver-level held-button coverage: iOS has no standalone
                // pointer-button profile binding. The movement itself is native
                // trackpad input; cancellation must neutralize the explicit hold.
                val revision = current.get().surfaceRevision
                instrumentation.runOnMainSync { surface.onReleaseAll = { client.releaseAll() } }
                client.pointer("button", 0.0, 0.0, "left", true, revision)
                SystemClock.sleep(150)
                touch(MotionEvent.ACTION_DOWN, pad)
                touch(MotionEvent.ACTION_MOVE, Triple(3, 2, .5f to .45f))
                SystemClock.sleep(150)
                touch(MotionEvent.ACTION_CANCEL, pad)
                SystemClock.sleep(250)
            }
        } finally { client.disconnect(); client.dispose() }
    }
}
