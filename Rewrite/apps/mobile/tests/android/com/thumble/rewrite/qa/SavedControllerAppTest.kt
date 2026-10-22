package com.thumble.rewrite.qa

import android.content.Intent
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.thumble.rewrite.bridge.ThumbleInputView
import com.thumble.rewrite.input.GamepadReport
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual React route and native map, never a manually supplied controller map. */
@RunWith(AndroidJUnit4::class)
class SavedControllerAppTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val target = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)

    private fun <T> ui(block: () -> T): T {
        var result: Result<T>? = null
        instrumentation.runOnMainSync { result = runCatching(block) }
        return checkNotNull(result).getOrThrow()
    }

    private fun clearTestProvider() {
        Class.forName("com.thumble.rewrite.bridge.NativeInputTestHost")
            .getMethod(
                "install",
                android.app.Instrumentation::class.java,
                Class.forName("kotlin.jvm.functions.Function3"),
            )
            .invoke(null, instrumentation, null)
    }

    private fun find(view: View): ThumbleInputView? {
        if (view is ThumbleInputView) return view
        if (view is ViewGroup)
            for (i in 0 until view.childCount) find(view.getChildAt(i))?.let {
                return it
            }
        return null
    }

    private fun controller() = ui {
        val activity =
            ActivityLifecycleMonitorRegistry.getInstance()
                .getActivitiesInStage(Stage.RESUMED)
                .single()
        checkNotNull(find(activity.window.decorView)) { "saved_controller_view_missing" }
    }

    private fun probe(path: String): JSONObject {
        require(
            path in
                setOf(
                    "/begin",
                    "/fresh",
                    "/saved-start",
                    "/saved-held",
                    "/held",
                    "/neutral",
                    "/finish",
                )
        )
        val port =
            checkNotNull(InstrumentationRegistry.getArguments().getString("thumbleProbePort"))
                .toInt()
        require(port in 1..65535)
        return java.net.Socket().use { socket ->
            socket.connect(java.net.InetSocketAddress("127.0.0.1", port), 3000)
            socket.soTimeout = 6000
            socket
                .getOutputStream()
                .write(
                    "GET $path HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                        .toByteArray(Charsets.US_ASCII)
                )
            val response = socket.getInputStream().bufferedReader().readText()
            check(response.length <= 65536 && response.startsWith("HTTP/1.0 200")) {
                "saved_controller_probe_failed"
            }
            JSONObject(response.substringAfter("\r\n\r\n"))
        }
    }

    private data class Point(val x: Float, val y: Float)

    private fun send(down: Long, action: Int, points: List<Point>) {
        val properties =
            Array(points.size) { i ->
                MotionEvent.PointerProperties().apply {
                    id = i
                    toolType = MotionEvent.TOOL_TYPE_FINGER
                }
            }
        val coordinates =
            Array(points.size) { i ->
                MotionEvent.PointerCoords().apply {
                    x = points[i].x
                    y = points[i].y
                    pressure = 1f
                    size = .1f
                }
            }
        val event =
            MotionEvent.obtain(
                down,
                SystemClock.uptimeMillis(),
                action,
                points.size,
                properties,
                coordinates,
                0,
                0,
                1f,
                1f,
                0,
                0,
                InputDevice.SOURCE_TOUCHSCREEN,
                0,
            )
        try {
            assertTrue(
                "saved_controller_touch_injection_failed",
                instrumentation.uiAutomation.injectInputEvent(event, true),
            )
        } finally {
            event.recycle()
        }
    }

    @Test
    fun actualSavedMapSummaryCornerAndDismissal() {
        val mode = InstrumentationRegistry.getArguments().getString("thumbleSavedControllerMode")
        require(mode in setOf("corner", "unsupported")) { "saved_controller_mode_invalid" }
        clearTestProvider()
        try {
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            assertTrue("saved_controller_device_asleep", device.isScreenOn)
            val launch =
                checkNotNull(target.packageManager.getLaunchIntentForPackage(target.packageName))
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            target.startActivity(launch)
            assertTrue(
                "saved_controller_app_not_visible",
                device.wait(Until.hasObject(By.pkg(target.packageName)), 15000),
            )
            device.waitForIdle()
            (device.findObject(By.res("practice-done"))
                    ?: device.findObject(By.res("connection-done")))
                ?.click()
            device.setOrientationLeft()
            val rotationDeadline = SystemClock.uptimeMillis() + 10000
            while (
                device.displayRotation != 1 && SystemClock.uptimeMillis() < rotationDeadline
            ) SystemClock.sleep(50)
            assertEquals("saved_controller_rotation_unsettled", 1, device.displayRotation)
            val invitation = probe("/begin").toString()
            checkNotNull(device.wait(Until.findObject(By.res("home-connect")), 15000)).click()
            assertTrue(
                "saved_controller_pairing_dialog_missing",
                device.wait(Until.hasObject(By.text("Test your connection")), 10000),
            )
            val field = checkNotNull(device.findObject(By.desc("Pairing invitation")))
            field.text = invitation
            // Dismiss only a visible IME; Back must never dismiss the pairing dialog.
            if (
                instrumentation.uiAutomation.windows.any {
                    it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD
                }
            )
                device.pressBack()
            checkNotNull(device.findObject(By.res("android:id/button1"))).click()
            if (mode == "unsupported") {
                assertTrue(
                    "saved_controller_unsupported_not_reported",
                    device.wait(
                        Until.hasObject(
                            By.text(
                                "Ask your agent to start the receiver and open pairing, then try again."
                            )
                        ),
                        15000,
                    ),
                )
                val view = controller()
                ui {
                    assertFalse(view.engine.connected)
                    assertFalse(view.engine.practice)
                    assertEquals("0", view.engine.generation)
                    assertNull(view.surface.configuration)
                    assertEquals(GamepadReport.neutral(), view.engine.state)
                }
                assertFalse(device.hasObject(By.text("A")))
                checkNotNull(device.findObject(By.res("connection-done"))).click()
                assertNotNull(device.wait(Until.findObject(By.res("home-connect")), 10000))
                probe("/finish")
                return
            }
            assertTrue(
                "saved_controller_connection_not_ready",
                device.wait(Until.hasObject(By.text("Connected to receiver")), 15000),
            )
            val summary =
                checkNotNull(device.wait(Until.findObject(By.res("saved-profile-summary")), 10000))
            assertEquals("2 saved profiles", summary.text)
            assertNotNull(device.wait(Until.findObject(By.text("A")), 10000))
            assertFalse(device.hasObject(By.text("B")))
            val view = controller()
            val header = checkNotNull(device.findObject(By.res("connection-header"))).visibleBounds
            val control = ui {
                assertTrue(view.engine.connected)
                assertFalse(view.engine.practice)
                val map = checkNotNull(view.surface.configuration)
                assertEquals("1", map.generation)
                assertEquals(view.engine.generation, map.generation)
                val region = map.controls.single()
                assertEquals("db000000-0000-0000-0000-000000000002", region.id)
                assertEquals("south", region.action)
                assertEquals(1.0, region.x + region.width, 0.00001)
                assertEquals(0.0, region.y, 0.0)
                val origin = IntArray(2)
                view.surface.getLocationOnScreen(origin)
                assertTrue("saved_controller_overlaps_header", origin[1] >= header.bottom - 1)
                Point(
                    origin[0] + ((region.x + region.width / 2) * view.surface.width).toFloat(),
                    origin[1] + ((region.y + region.height / 2) * view.surface.height).toFloat(),
                )
            }
            probe("/fresh")
            val down = SystemClock.uptimeMillis()
            send(down, MotionEvent.ACTION_DOWN, listOf(control))
            try {
                probe("/saved-start")
                val until = SystemClock.uptimeMillis() + 1600
                while (SystemClock.uptimeMillis() < until) {
                    ui {
                        assertTrue(view.engine.connected)
                        assertEquals(
                            setOf("south"),
                            view.engine.state.buttons.map { it.name }.toSet(),
                        )
                    }
                    SystemClock.sleep(20)
                }
                probe("/saved-held")
                probe("/held")
                val doneBounds =
                    checkNotNull(device.findObject(By.res("connection-done"))).visibleBounds
                val done = Point(doneBounds.exactCenterX(), doneBounds.exactCenterY())
                assertTrue("saved_controller_control_overlaps_done", control.y > doneBounds.bottom)
                val both = listOf(control, done)
                send(
                    down,
                    MotionEvent.ACTION_POINTER_DOWN or
                        (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    both,
                )
                send(
                    down,
                    MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    both,
                )
                send(down, MotionEvent.ACTION_UP, listOf(control))
                assertNotNull(device.wait(Until.findObject(By.res("home-connect")), 10000))
                probe("/neutral")
                ui {
                    assertFalse(view.engine.connected)
                    assertEquals(GamepadReport.neutral(), view.engine.state)
                }
                probe("/finish")
            } finally {
                runCatching { send(down, MotionEvent.ACTION_CANCEL, listOf(control)) }
            }
        } catch (failure: Throwable) {
            val phase =
                when {
                    device.hasObject(By.text("Test your connection")) -> "pairing-dialog"
                    device.hasObject(By.text("Connected to receiver")) -> "connected"
                    device.hasObject(
                        By.text(
                            "Ask your agent to start the receiver and open pairing, then try again."
                        )
                    ) -> "unavailable"
                    device.hasObject(By.text("Turn your phone sideways")) -> "portrait"
                    device.hasObject(By.text("Connecting…")) -> "connecting"
                    device.hasObject(By.text("Saving phone trust…")) -> "pairing"
                    device.hasObject(By.text("Waiting for invitation")) -> "waiting"
                    else -> "other"
                }
            val native = runCatching {
                val view = controller()
                ui {
                    "connected=${view.engine.connected} generation=${view.engine.generation} controls=${view.surface.configuration?.controls?.size ?: 0}"
                }
            }
                .getOrDefault("native=unavailable")
            android.util.Log.e(
                "ThumbleSavedQa",
                "phase=$phase targetVisible=${device.hasObject(By.pkg(target.packageName))} $native",
            )
            throw failure
        } finally {
            clearTestProvider()
            device.setOrientationNatural()
            device.unfreezeRotation()
        }
    }
}
