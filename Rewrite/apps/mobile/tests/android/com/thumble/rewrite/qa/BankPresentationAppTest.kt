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
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Actual React route and native map, never a manually supplied controller map. */
@RunWith(AndroidJUnit4::class)
class BankPresentationAppTest {
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
                setOf("/begin", "/bank-hold-start", "/refresh", "/bank-held", "/neutral", "/finish")
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

    private data class Point(val id: Int, val x: Float, val y: Float)

    private fun send(down: Long, action: Int, points: List<Point>) {
        val properties =
            Array(points.size) { i ->
                MotionEvent.PointerProperties().apply {
                    id = points[i].id
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

    private fun tagged(view: View, name: String): View? {
        if (view.getTag(com.facebook.react.R.id.react_test_id) == name) return view
        if (view is ViewGroup)
            for (index in 0 until view.childCount) {
                tagged(view.getChildAt(index), name)?.let {
                    return it
                }
            }
        return null
    }

    private fun iconColor(red: Int, blue: Int) {
        var observed = "absent_or_hidden"
        val deadline = SystemClock.uptimeMillis() + 12000
        while (SystemClock.uptimeMillis() < deadline) {
            val matches = ui {
                val activity =
                    ActivityLifecycleMonitorRegistry.getInstance()
                        .getActivitiesInStage(Stage.RESUMED)
                        .single()
                val icon =
                    tagged(
                        activity.window.decorView,
                        "presentation-icon-ce000000-0000-0000-0000-00000000000a",
                    )
                val visibleBounds = android.graphics.Rect()
                var ancestor = icon as View?
                var visibleAlpha = true
                while (ancestor != null) {
                    if (ancestor.alpha < 0.999f) visibleAlpha = false
                    ancestor = ancestor.parent as? View
                }
                if (
                    icon == null ||
                        icon.width <= 0 ||
                        icon.height <= 0 ||
                        !icon.isShown ||
                        !icon.isAttachedToWindow ||
                        !visibleAlpha ||
                        icon.windowVisibility != View.VISIBLE ||
                        !icon.getGlobalVisibleRect(visibleBounds) ||
                        visibleBounds.width() < icon.width ||
                        visibleBounds.height() < icon.height
                )
                    false
                else {
                    val bitmap =
                        android.graphics.Bitmap.createBitmap(
                            icon.width,
                            icon.height,
                            android.graphics.Bitmap.Config.ARGB_8888,
                        )
                    try {
                        icon.draw(android.graphics.Canvas(bitmap))
                        val color = bitmap.getPixel(icon.width / 2, icon.height / 2)
                        observed =
                            "${android.graphics.Color.red(color)},${android.graphics.Color.green(color)},${android.graphics.Color.blue(color)}"
                        kotlin.math.abs(android.graphics.Color.red(color) - red) <= 2 &&
                            kotlin.math.abs(android.graphics.Color.green(color) - 64) <= 2 &&
                            kotlin.math.abs(android.graphics.Color.blue(color) - blue) <= 2
                    } finally {
                        bitmap.recycle()
                    }
                }
            }
            if (matches) return
            SystemClock.sleep(50)
        }
        val state = runCatching {
            val view = controller()
            ui {
                "left=${view.engine.state.leftTrigger},right=${view.engine.state.rightTrigger},connected=${view.engine.connected}"
            }
        }
            .getOrDefault("state_unavailable")
        fail(
            "presentation_actual_rendered_icon_mismatch expected=$red,64,$blue observed=$observed $state"
        )
    }

    private fun point(view: ThumbleInputView, action: String, id: Int, full: Boolean = false) = ui {
        val region =
            checkNotNull(view.surface.configuration).controls.single { it.action == action }
        val origin = IntArray(2)
        view.surface.getLocationOnScreen(origin)
        Point(
            id,
            origin[0] + ((region.x + region.width / 2) * view.surface.width).toFloat(),
            origin[1] +
                (if (full) region.y * view.surface.height - 10
                    else (region.y + region.height / 2) * view.surface.height)
                    .toFloat(),
        )
    }

    private fun screenshot() {
        val image = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val bytes = java.io.ByteArrayOutputStream()
        try {
            assertTrue(image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bytes))
        } finally {
            image.recycle()
        }
        val data = bytes.toByteArray()
        require(data.size in 9..2097152)
        val port =
            checkNotNull(InstrumentationRegistry.getArguments().getString("thumbleProbePort"))
                .toInt()
        java.net.Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 6000
            socket
                .getOutputStream()
                .write(
                    "POST /screenshot HTTP/1.0\r\nHost: localhost\r\nContent-Length: ${data.size}\r\n\r\n"
                        .toByteArray(Charsets.US_ASCII)
                )
            socket.getOutputStream().write(data)
            assertTrue(
                socket.getInputStream().bufferedReader().readText().startsWith("HTTP/1.0 200")
            )
        }
    }

    @Test
    fun actualModifierBanksTrackNativeHeldStateAndRefresh() {
        clearTestProvider()
        val originalNight = device.executeShellCommand("cmd uimode night").trim()
        var down = 0L
        var held = emptyList<Point>()
        var primaryFailure: Throwable? = null
        try {
            device.executeShellCommand("cmd uimode night no")
            device.wakeUp()
            device.executeShellCommand("wm dismiss-keyguard")
            val launch =
                checkNotNull(target.packageManager.getLaunchIntentForPackage(target.packageName))
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            target.startActivity(launch)
            assertTrue(device.wait(Until.hasObject(By.pkg(target.packageName)), 15000))
            device.waitForIdle()
            (device.findObject(By.res("practice-done"))
                    ?: device.findObject(By.res("connection-done")))
                ?.click()
            device.setOrientationLeft()
            val invitation = probe("/begin").toString()
            checkNotNull(device.wait(Until.findObject(By.res("home-connect")), 15000)).click()
            assertTrue(device.wait(Until.hasObject(By.text("Test your connection")), 10000))
            checkNotNull(device.findObject(By.desc("Pairing invitation"))).text = invitation
            if (
                instrumentation.uiAutomation.windows.any {
                    it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD
                }
            )
                device.pressBack()
            checkNotNull(device.findObject(By.res("android:id/button1"))).click()
            assertTrue(device.wait(Until.hasObject(By.text("Connected to receiver")), 15000))
            iconColor(16, 176)
            val view = controller()
            val south = point(view, "south", 0)
            val left = point(view, "leftVerticalTrigger", 1)
            val right = point(view, "rightVerticalTrigger", 2)
            val leftFull = point(view, "leftVerticalTrigger", 1, true)
            val rightFull = point(view, "rightVerticalTrigger", 2, true)
            down = SystemClock.uptimeMillis()
            held = listOf(south)
            send(down, MotionEvent.ACTION_DOWN, held)
            held = listOf(south, left)
            send(
                down,
                MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south, leftFull)
            send(down, MotionEvent.ACTION_MOVE, held)
            iconColor(24, 168)
            held = listOf(south, leftFull, right)
            send(
                down,
                MotionEvent.ACTION_POINTER_DOWN or (2 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south, leftFull, rightFull)
            send(down, MotionEvent.ACTION_MOVE, held)
            iconColor(40, 152)
            send(
                down,
                MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south, rightFull)
            iconColor(32, 160)
            send(
                down,
                MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south)
            iconColor(16, 176)
            held = listOf(south, left)
            send(
                down,
                MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south, leftFull)
            send(down, MotionEvent.ACTION_MOVE, held)
            iconColor(24, 168)
            held = listOf(south, leftFull, right)
            send(
                down,
                MotionEvent.ACTION_POINTER_DOWN or (2 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south, leftFull, rightFull)
            send(down, MotionEvent.ACTION_MOVE, held)
            iconColor(40, 152)
            assertTrue(probe("/bank-hold-start").getBoolean("watching"))
            device.executeShellCommand("cmd uimode night yes")
            iconColor(72, 120)
            assertTrue(probe("/refresh").getBoolean("refreshed"))
            iconColor(168, 24)
            SystemClock.sleep(1600)
            assertTrue(probe("/bank-held").getBoolean("bankHeld"))
            ui {
                assertTrue(view.engine.connected)
                assertEquals(1.0, view.engine.state.leftTrigger, 0.0)
                assertEquals(1.0, view.engine.state.rightTrigger, 0.0)
                assertEquals(setOf("south"), view.engine.state.buttons.map { it.name }.toSet())
            }
            assertSame(view, controller())
            screenshot()
            send(
                down,
                MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south, rightFull)
            iconColor(160, 32)
            send(
                down,
                MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south)
            iconColor(144, 48)
            held = listOf(south, left)
            send(
                down,
                MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south, leftFull)
            send(down, MotionEvent.ACTION_MOVE, held)
            iconColor(152, 40)
            send(
                down,
                MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                held,
            )
            held = listOf(south)
            iconColor(144, 48)
            send(down, MotionEvent.ACTION_UP, held)
            held = emptyList()
            checkNotNull(device.findObject(By.res("connection-done"))).click()
            assertNotNull(device.wait(Until.findObject(By.res("home-connect")), 10000))
            probe("/neutral")
            probe("/finish")
        } catch (error: Throwable) {
            primaryFailure = error
            throw error
        } finally {
            var cleanupFailure: Throwable? = null
            fun cleanup(action: () -> Unit) {
                runCatching(action).exceptionOrNull()?.let { error ->
                    val first = cleanupFailure
                    if (first == null) cleanupFailure = error else first.addSuppressed(error)
                }
            }
            cleanup { if (held.isNotEmpty()) send(down, MotionEvent.ACTION_CANCEL, held) }
            cleanup { clearTestProvider() }
            cleanup {
                val restore =
                    when {
                        originalNight.endsWith("yes") -> "yes"
                        originalNight.endsWith("no") -> "no"
                        originalNight.endsWith("auto") -> "auto"
                        else -> error("presentation_original_theme_unknown")
                    }
                device.executeShellCommand("cmd uimode night $restore")
            }
            cleanup { device.setOrientationNatural() }
            cleanup { device.unfreezeRotation() }
            val cleanupError = cleanupFailure
            if (cleanupError != null) {
                val primary = primaryFailure
                if (primary == null) throw cleanupError else primary.addSuppressed(cleanupError)
            }
        }
    }
}
