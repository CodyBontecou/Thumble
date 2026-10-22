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
import com.facebook.react.ReactApplication
import com.thumble.rewrite.bridge.ThumbleInputView
import com.thumble.rewrite.input.GamepadReport
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TestRule
import org.junit.runner.RunWith
import org.junit.runners.model.Statement

@RunWith(AndroidJUnit4::class)
class PracticeInputTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val device = UiDevice.getInstance(instrumentation)
    private val target = instrumentation.targetContext
    private lateinit var controller: ThumbleInputView
    private val fixture by lazy {
        JSONObject(
            instrumentation.context.assets.open("controller-layout-v1.json").bufferedReader().use {
                it.readText()
            }
        )
    }

    private fun <T> ui(block: () -> T): T {
        var result: Result<T>? = null
        instrumentation.runOnMainSync { result = runCatching(block) }
        return checkNotNull(result).getOrThrow()
    }

    private var opened = false

    @get:Rule
    val preservePrimaryFailure = TestRule { base, _ ->
        object : Statement() {
            override fun evaluate() {
                val primary = runCatching { base.evaluate() }.exceptionOrNull()
                if (primary != null) {
                    runCatching {
                        val dump = ByteArrayOutputStream()
                        device.dumpWindowHierarchy(dump)
                        android.util.Log.e(
                            "ThumbleQa",
                            "screenOn=${device.isScreenOn}; package=${device.currentPackageName}; rotation=${device.displayRotation}; ${dump.toString("UTF-8").take(48_000)}",
                        )
                    }
                }
                val teardown = runCatching { cleanup() }.exceptionOrNull()
                if (primary != null) {
                    if (teardown != null) primary.addSuppressed(teardown)
                    throw primary
                }
                if (teardown != null) throw teardown
            }
        }
    }

    private fun wakeTestDevice() {
        device.wakeUp()
        device.executeShellCommand("wm dismiss-keyguard")
        assertTrue("Test emulator did not wake", device.isScreenOn)
    }

    private fun find(view: View): ThumbleInputView? {
        if (view is ThumbleInputView) return view
        if (view is ViewGroup)
            for (i in 0 until view.childCount) find(view.getChildAt(i))?.let {
                return it
            }
        return null
    }

    private fun awaitRotation(rotation: Int) {
        val until = SystemClock.uptimeMillis() + 10_000
        while (device.displayRotation != rotation && SystemClock.uptimeMillis() < until) SystemClock
            .sleep(50)
        assertEquals("Device orientation did not settle", rotation, device.displayRotation)
        device.waitForIdle()
    }

    private fun awaitText(text: String) {
        if (!device.wait(Until.hasObject(By.text(text)), 15_000)) {
            val dump = ByteArrayOutputStream()
            device.dumpWindowHierarchy(dump)
            fail("Missing $text; rotation=${device.displayRotation}; ${dump.toString("UTF-8")}")
        }
    }

    @Before
    fun openPractice() {
        wakeTestDevice()
        val launch =
            checkNotNull(target.packageManager.getLaunchIntentForPackage(target.packageName))
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        target.startActivity(launch)
        assertTrue(device.wait(Until.hasObject(By.pkg(target.packageName)), 15_000))
        device.waitForIdle()
        device.findObject(By.res("practice-done"))?.click()
        assertTrue(device.wait(Until.gone(By.res("practice-done")), 10_000))
        device.setOrientationNatural()
        awaitRotation(0)
        checkNotNull(device.wait(Until.findObject(By.res("home-practice")), 15_000)).click()
        awaitText("Turn your phone sideways")
        device.setOrientationLeft()
        awaitRotation(1)
        awaitText("Practice ready")
        device.waitForIdle()
        controller = ui {
            val activity =
                ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED)
                    .single()
            checkNotNull(find(activity.window.decorView))
        }
        assertEquals("1", ui { controller.engine.generation })
        assertTrue(ui { controller.engine.practice })
        assertFalse(ui { controller.engine.connected })
        opened = true
    }

    private fun cleanup() {
        if (!opened) {
            device.setOrientationNatural()
            device.unfreezeRotation()
            return
        }
        wakeTestDevice()
        val launch =
            checkNotNull(target.packageManager.getLaunchIntentForPackage(target.packageName))
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        target.startActivity(launch)
        assertTrue(device.wait(Until.hasObject(By.pkg(target.packageName)), 15_000))
        device.waitForIdle()
        checkNotNull(device.wait(Until.findObject(By.res("practice-done")), 15_000)).click()
        assertTrue(
            "Done did not return home",
            device.wait(Until.gone(By.res("practice-done")), 10_000),
        )
        assertNotNull(device.wait(Until.findObject(By.res("home-practice")), 10_000))
        device.setOrientationNatural()
        device.unfreezeRotation()
    }

    private data class Point(val x: Float, val y: Float)

    private fun point(probe: JSONObject): Point = ui {
        val origin = IntArray(2)
        controller.surface.getLocationOnScreen(origin)
        Point(
            origin[0] + (probe.getDouble("x") * controller.surface.width).toFloat(),
            origin[1] + (probe.getDouble("y") * controller.surface.height).toFloat(),
        )
    }

    private fun send(down: Long, action: Int, points: List<Point>) {
        val props =
            Array(points.size) { i ->
                MotionEvent.PointerProperties().apply {
                    id = i
                    toolType = MotionEvent.TOOL_TYPE_FINGER
                }
            }
        val coords =
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
                props,
                coords,
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
            assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true))
        } finally {
            event.recycle()
        }
    }

    private fun report() = ui { GamepadReport.hex(controller.engine.state) }

    // System MotionEvents carry Float screen coordinates. Across display sizes
    // their round trip may land one signed-16-bit stick unit from the ideal
    // normalized fixture. Buttons, triggers, header and reserved bytes stay exact;
    // neutralization below is always an exact whole-report comparison.
    private fun assertPhysicalReport(label: String, expected: String, actual: String) {
        assertEquals(label, expected.length, actual.length)
        assertEquals(label, expected.substring(0, 12), actual.substring(0, 12))
        assertEquals(label, expected.substring(28), actual.substring(28))
        fun axis(hex: String, offset: Int): Int {
            val low = hex.substring(offset * 2, offset * 2 + 2).toInt(16)
            val high = hex.substring(offset * 2 + 2, offset * 2 + 4).toInt(16)
            return (low or (high shl 8)).toShort().toInt()
        }
        for (offset in listOf(6, 8, 10, 12)) {
            val want = axis(expected, offset)
            val got = axis(actual, offset)
            assertTrue(
                "$label stick@$offset expected=$want actual=$got",
                kotlin.math.abs(want - got) <= 1,
            )
        }
    }

    private fun neutral() = GamepadReport.hex(GamepadReport.neutral())

    @Test
    fun touchSurfaceHasNoReactRootAncestor() {
        val captures = ui { controller.nativeCaptureViews }
        assertEquals(19, captures.size)
        assertTrue(ui { controller.surface.isAttachedToWindow })
        for (capture in captures + controller.surface) {
            val ancestry = ui {
                val names = mutableListOf<String>()
                var parent = capture.parent
                while (parent is View) {
                    names.add(parent.javaClass.name)
                    parent = parent.parent
                }
                names
            }
            assertFalse(
                "Native touches would enter React's root dispatcher: $ancestry",
                ancestry.any { it.endsWith(".ReactRootView") || it.endsWith(".ReactSurfaceView") },
            )
        }
    }

    @Test
    fun everyActualSurfaceHitMatchesTheSharedReportAndReleases() {
        val probes = fixture.getJSONArray("probes")
        assertEquals(19, probes.length())
        for (i in 0 until probes.length()) {
            val probe = probes.getJSONObject(i)
            val points = listOf(point(probe))
            val down = SystemClock.uptimeMillis()
            send(down, MotionEvent.ACTION_DOWN, points)
            try {
                assertPhysicalReport(probe.getString("id"), probe.getString("reportHex"), report())
            } finally {
                send(down, MotionEvent.ACTION_CANCEL, points)
            }
            assertEquals(neutral(), report())
        }
    }

    @Test
    fun sixNativeTouchesAndCancellationWorkWhileActualJsQueueIsBlocked() {
        val context = ui {
            checkNotNull(
                (target.applicationContext as ReactApplication).reactHost?.currentReactContext
            )
        }
        val blocked = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val finished = CountDownLatch(1)
        var jsThread = ""
        assertTrue(
            context.runOnJSQueueThread {
                jsThread = Thread.currentThread().name
                blocked.countDown()
                try {
                    resume.await(20, TimeUnit.SECONDS)
                } finally {
                    finished.countDown()
                }
            }
        )
        assertTrue(blocked.await(5, TimeUnit.SECONDS))
        assertNotEquals("main", jsThread)
        val chord = fixture.getJSONObject("chord")
        val ids = chord.getJSONArray("ids")
        val probes = fixture.getJSONArray("probes")
        val points = mutableListOf<Point>()
        val down = SystemClock.uptimeMillis()
        try {
            for (i in 0 until ids.length()) {
                val probe =
                    (0 until probes.length())
                        .map { probes.getJSONObject(it) }
                        .single { it.getString("id") == ids.getString(i) }
                points.add(point(probe))
                send(
                    down,
                    if (i == 0) MotionEvent.ACTION_DOWN
                    else
                        MotionEvent.ACTION_POINTER_DOWN or
                            (i shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    points,
                )
            }
            val publications = ui { controller.nativeFeedbackPublications }
            val until = SystemClock.uptimeMillis() + 2_500
            while (SystemClock.uptimeMillis() < until) {
                assertPhysicalReport("six-finger chord", chord.getString("reportHex"), report())
                SystemClock.sleep(20)
            }
            assertTrue(
                "Native frame feedback stopped with JS",
                ui { controller.nativeFeedbackPublications } > publications,
            )
            assertEquals("JS queue resumed before native input finished", 1L, finished.count)
            send(down, MotionEvent.ACTION_CANCEL, points)
            points.clear()
            assertEquals(neutral(), report())
            assertEquals("JS queue resumed before cancellation", 1L, finished.count)
        } finally {
            try {
                if (points.isNotEmpty()) send(down, MotionEvent.ACTION_CANCEL, points)
            } finally {
                resume.countDown()
            }
        }
    }

    @Test
    fun doneWithASecondFingerReleasesTheHeldController() {
        val probe = fixture.getJSONArray("probes").getJSONObject(0)
        val control = point(probe)
        val down = SystemClock.uptimeMillis()
        send(down, MotionEvent.ACTION_DOWN, listOf(control))
        assertEquals(probe.getString("reportHex"), report())
        val bounds = checkNotNull(device.findObject(By.res("practice-done"))).visibleBounds
        val done = Point(bounds.exactCenterX(), bounds.exactCenterY())
        val both = listOf(control, done)
        try {
            send(
                down,
                MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                both,
            )
            send(
                down,
                MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                both,
            )
            assertTrue(
                "A held control swallowed the second finger's Done tap",
                device.wait(Until.gone(By.res("practice-done")), 5_000),
            )
            assertNotNull(device.wait(Until.findObject(By.res("home-practice")), 5_000))
            assertEquals(neutral(), report())
            opened = false
        } finally {
            // Navigation may already have caused the system to cancel this target.
            runCatching { send(down, MotionEvent.ACTION_CANCEL, listOf(control)) }
        }
    }

    @Test
    fun sleepingReleasesNativeTouchesAndWakingStartsNeutral() {
        val probe = fixture.getJSONArray("probes").getJSONObject(0)
        val points = listOf(point(probe))
        send(SystemClock.uptimeMillis(), MotionEvent.ACTION_DOWN, points)
        assertEquals(probe.getString("reportHex"), report())
        try {
            device.sleep()
            val until = SystemClock.uptimeMillis() + 2_000
            while (report() != neutral() && SystemClock.uptimeMillis() < until) SystemClock.sleep(
                10
            )
            assertEquals(neutral(), report())
        } finally {
            wakeTestDevice()
        }
        awaitText("Practice ready")
        assertEquals(neutral(), report())
        val fresh = listOf(point(probe))
        val down = SystemClock.uptimeMillis()
        send(down, MotionEvent.ACTION_DOWN, fresh)
        try {
            assertEquals(probe.getString("reportHex"), report())
        } finally {
            send(down, MotionEvent.ACTION_CANCEL, fresh)
        }
        assertEquals(neutral(), report())
    }

    @Test
    fun rotationReleasesOldSurfaceAndReopensNeutral() {
        val old = controller
        val probe = fixture.getJSONArray("probes").getJSONObject(0)
        val points = listOf(point(probe))
        val down = SystemClock.uptimeMillis()
        send(down, MotionEvent.ACTION_DOWN, points)
        assertEquals(probe.getString("reportHex"), report())
        device.setOrientationNatural()
        awaitRotation(0)
        awaitText("Turn your phone sideways")
        assertEquals(neutral(), report())
        assertNull(ui { old.surface.parent })
        device.setOrientationLeft()
        awaitRotation(1)
        awaitText("Practice ready")
        controller = ui {
            val activity =
                ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED)
                    .single()
            checkNotNull(find(activity.window.decorView))
        }
        assertNotSame(old, controller)
        assertEquals(neutral(), report())
        val fresh = listOf(point(probe))
        val freshDown = SystemClock.uptimeMillis()
        send(freshDown, MotionEvent.ACTION_DOWN, fresh)
        try {
            assertEquals(probe.getString("reportHex"), report())
        } finally {
            send(freshDown, MotionEvent.ACTION_CANCEL, fresh)
        }
        assertEquals(neutral(), report())
    }

    @Test
    fun backgroundingReleasesCapturedNativeTouches() {
        val probe = fixture.getJSONArray("probes").getJSONObject(0)
        val points = listOf(point(probe))
        val down = SystemClock.uptimeMillis()
        send(down, MotionEvent.ACTION_DOWN, points)
        assertEquals(probe.getString("reportHex"), report())
        try {
            device.pressHome()
            device.waitForIdle()
            assertEquals(neutral(), report())
        } finally {
            send(down, MotionEvent.ACTION_CANCEL, points)
        }
    }
}
