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

    private fun installExplicitMapProvider(enabled: Boolean) {
        val provider:
            ((
                com.thumble.rewrite.input.PhoneInputConfiguration, Double, Double,
            ) -> com.thumble.rewrite.input.ControlMap)? =
            if (!enabled) null
            else
                { metadata, _, _ ->
                    val controls = fixture.getJSONObject("map").getJSONArray("controls")
                    com.thumble.rewrite.input.ControlMap(
                        generation = metadata.generation,
                        revision = metadata.revision,
                        controls =
                            (0 until controls.length()).map { index ->
                                val control = controls.getJSONObject(index)
                                com.thumble.rewrite.input.ControlRegion(
                                    control.getString("id"),
                                    control.getString("action"),
                                    control.getDouble("x"),
                                    control.getDouble("y"),
                                    control.getDouble("width"),
                                    control.getDouble("height"),
                                    control
                                        .optJSONObject("hapticFeedback")
                                        ?.let(
                                            com.thumble.rewrite.input.TouchHapticFeedback::decode
                                        ),
                                )
                            },
                    )
                }
        // Test APK owns registration; the production route has no setter.
        Class.forName("com.thumble.rewrite.bridge.NativeInputTestHost")
            .getMethod(
                "install",
                android.app.Instrumentation::class.java,
                Class.forName("kotlin.jvm.functions.Function3"),
            )
            .invoke(null, instrumentation, provider)
    }

    @Before
    fun openPractice() {
        installExplicitMapProvider(true)
        wakeTestDevice()
        val launch =
            checkNotNull(target.packageManager.getLaunchIntentForPackage(target.packageName))
        launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        target.startActivity(launch)
        waitForTargetApp()
        device.waitForIdle()
        (device.findObject(By.res("practice-done")) ?: device.findObject(By.res("connection-done")))
            ?.click()
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
        installExplicitMapProvider(false)
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
        waitForTargetApp()
        device.waitForIdle()
        (device.findObject(By.res("practice-done")) ?: device.findObject(By.res("connection-done")))
            ?.click()
        assertTrue(
            "Done did not return home",
            device.wait(Until.gone(By.res("practice-done")), 10_000),
        )
        assertNotNull(device.wait(Until.findObject(By.res("home-practice")), 10_000))
        device.setOrientationNatural()
        device.unfreezeRotation()
    }

    @Test
    fun connectedEngineSurvivesInstallationCapturesTouchesAndReleasesOnRemoval() {
        var impacts = 0
        var feedbackEnded = 0
        val feedback =
            object : com.thumble.rewrite.input.TouchHapticSink {
                override fun accepted(
                    id: Long,
                    feedback: com.thumble.rewrite.input.TouchHapticFeedback,
                ) {
                    impacts++
                }

                override fun ended(id: Long) {
                    feedbackEnded++
                }

                override fun cancel() {}
            }
        val surface = ui {
            val activity =
                ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(Stage.RESUMED)
                    .single()
            val engine = com.thumble.rewrite.input.InputEngine({ true })
            val map =
                com.thumble.rewrite.input.ControlMap(
                    generation = "7",
                    revision = "4",
                    controls =
                        listOf(
                            com.thumble.rewrite.input.ControlRegion(
                                "face",
                                "south",
                                0.0,
                                0.0,
                                1.0,
                                1.0,
                            )
                        ),
                )
            engine.activate(map)
            engine.connect("7")
            val view = com.thumble.rewrite.input.InputSurface.connected(activity, engine, feedback)
            assertEquals(map, view.configuration)
            assertTrue(engine.connected)
            try {
                com.thumble.rewrite.input.InputSurface.connected(activity, engine)
                fail("duplicate surface accepted")
            } catch (_: IllegalStateException) {}
            assertTrue(engine.connected)
            activity.addContentView(
                view,
                android.widget.FrameLayout.LayoutParams(240, 160).apply {
                    leftMargin = 30
                    topMargin = 50
                },
            )
            view
        }
        try {
            device.waitForIdle()
            SystemClock.sleep(30)
            val center = ui {
                assertTrue(surface.engine.connected)
                val origin = IntArray(2)
                surface.getLocationOnScreen(origin)
                Point(origin[0] + surface.width / 2f, origin[1] + surface.height / 2f)
            }
            val down = SystemClock.uptimeMillis()
            send(down, MotionEvent.ACTION_DOWN, listOf(center))
            ui {
                assertEquals(setOf("south"), surface.engine.state.buttons.map { it.name }.toSet())
                assertEquals(1, impacts)
                surface.engine.tick()
                assertEquals(1, impacts)
            }
            send(down, MotionEvent.ACTION_MOVE, listOf(center))
            ui { assertEquals(1, impacts) }
            send(down, MotionEvent.ACTION_UP, listOf(center))
            ui {
                assertEquals(GamepadReport.neutral(), surface.engine.state)
                assertEquals(1, impacts)
                assertEquals(1, feedbackEnded)
            }
            ui {
                (surface.parent as ViewGroup).removeView(surface)
                assertFalse(surface.engine.connected)
                assertEquals(GamepadReport.neutral(), surface.engine.state)
            }
        } finally {
            ui {
                (surface.parent as? ViewGroup)?.removeView(surface)
                surface.dispose()
            }
        }
    }

    @Test
    fun appCaptureAdoptsExactNativeReceiptWithoutFirstLayoutRelease() {
        ui {
            val old = controller.engine
            val map =
                com.thumble.rewrite.input.ControlMap(
                    generation = "7",
                    revision = "4",
                    controls =
                        listOf(
                            com.thumble.rewrite.input.ControlRegion(
                                "face",
                                "south",
                                0.0,
                                0.0,
                                1.0,
                                1.0,
                            )
                        ),
                )
            val engine = com.thumble.rewrite.input.InputEngine({ true })
            engine.activate(map)
            engine.connect("7")
            controller.adoptConnectedEngine(engine)
            assertFalse(old.connected)
            assertEquals(GamepadReport.neutral(), old.state)
            assertTrue(engine === controller.engine)
            assertTrue(engine.connected)
            assertEquals("7", controller.surface.configuration?.generation)
            assertEquals("4", controller.surface.configuration?.revision)
            try {
                controller.practice(true)
                fail("React practice replaced live owner")
            } catch (_: IllegalStateException) {}
            assertTrue(engine.connected)
        }
        device.waitForIdle()
        val center = ui {
            assertTrue(controller.engine.connected)
            val origin = IntArray(2)
            controller.surface.getLocationOnScreen(origin)
            Point(
                origin[0] + controller.surface.width / 2f,
                origin[1] + controller.surface.height / 2f,
            )
        }
        SystemClock.sleep(30)
        val down = SystemClock.uptimeMillis()
        send(down, MotionEvent.ACTION_DOWN, listOf(center))
        ui { assertEquals(setOf("south"), controller.engine.state.buttons.map { it.name }.toSet()) }
        send(down, MotionEvent.ACTION_UP, listOf(center))
        ui {
            assertEquals(GamepadReport.neutral(), controller.engine.state)
            controller.release(com.thumble.rewrite.input.ReleaseReason.disposed)
            assertFalse(controller.engine.connected)
        }
    }

    private fun probe(path: String): JSONObject {
        val port =
            checkNotNull(InstrumentationRegistry.getArguments().getString("thumbleProbePort"))
                .toInt()
        require(port in 1..65535)
        return java.net.Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 6000
            socket
                .getOutputStream()
                .write(
                    "GET $path HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                        .toByteArray(Charsets.US_ASCII)
                )
            val response = socket.getInputStream().bufferedReader().readText()
            check(response.startsWith("HTTP/1.0 200")) { "recording_only_host_witness_failed" }
            JSONObject(response.substringAfter("\r\n\r\n"))
        }
    }

    @Test
    fun nativePairingVaultBindingAndReconnectReachRecordingReceiver() {
        val invitation = probe("/begin").toString()
        checkNotNull(device.findObject(By.res("practice-done"))).click()
        for (generation in listOf("1", "2")) {
            if (generation == "2") probe("/next")
            checkNotNull(device.wait(Until.findObject(By.res("home-connect")), 10_000)).click()
            assertNotNull(
                device.wait(Until.findObject(By.text("Test your connection")), 10_000)
            )
            if (generation == "1") {
                val field = checkNotNull(device.findObject(By.desc("Pairing invitation")))
                field.text = invitation
                checkNotNull(device.findObject(By.res("android:id/button1"))).click()
            } else checkNotNull(device.findObject(By.res("android:id/button3"))).click()
            awaitText("Connected to receiver")
            controller = ui {
                val activity =
                    ActivityLifecycleMonitorRegistry.getInstance()
                        .getActivitiesInStage(Stage.RESUMED)
                        .single()
                checkNotNull(find(activity.window.decorView))
            }
            ui {
                assertTrue(controller.engine.connected)
                assertEquals(generation, controller.engine.generation)
                assertEquals(GamepadReport.neutral(), controller.engine.state)
            }
            probe("/fresh")
            val south =
                fixture.getJSONArray("probes").let { probes ->
                    (0 until probes.length())
                        .map { probes.getJSONObject(it) }
                        .first { it.getString("id") == "standard-south" }
                }
            SystemClock.sleep(30)
            val down = SystemClock.uptimeMillis()
            val held = point(south)
            send(down, MotionEvent.ACTION_DOWN, listOf(held))
            if (generation == "1") {
                val trigger =
                    fixture.getJSONArray("probes").let { probes ->
                        (0 until probes.length())
                            .map { probes.getJSONObject(it) }
                            .single { it.getString("id") == "standard-leftTrigger" }
                    }
                val heldBoth = listOf(held, point(trigger))
                send(
                    down,
                    MotionEvent.ACTION_POINTER_DOWN or
                        (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                    heldBoth,
                )
                val context = ui {
                    checkNotNull(
                        (target.applicationContext as ReactApplication)
                            .reactHost
                            ?.currentReactContext
                    )
                }
                val blocked = CountDownLatch(1)
                val resume = CountDownLatch(1)
                val finished = CountDownLatch(1)
                assertTrue(
                    context.runOnJSQueueThread {
                        blocked.countDown()
                        try {
                            resume.await(100, TimeUnit.SECONDS)
                        } finally {
                            finished.countDown()
                        }
                    }
                )
                assertTrue(blocked.await(5, TimeUnit.SECONDS))
                try {
                    probe("/renewal-start")
                    val publications = ui { controller.nativeFeedbackPublications }
                    val until = SystemClock.uptimeMillis() + 75_000
                    while (SystemClock.uptimeMillis() < until) {
                        SystemClock.sleep(250)
                        ui {
                            assertTrue(controller.engine.connected)
                            assertTrue(controller.engine.state.buttons.any { it.name == "south" })
                            assertEquals(1.0, controller.engine.state.leftTrigger, 0.0)
                        }
                    }
                    probe("/renewal-verified")
                    assertTrue(ui { controller.nativeFeedbackPublications } > publications)
                    assertEquals("JS resumed during native renewal", 1L, finished.count)
                    send(
                        down,
                        MotionEvent.ACTION_POINTER_UP or
                            (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                        heldBoth,
                    )
                } finally {
                    resume.countDown()
                    assertTrue(finished.await(5, TimeUnit.SECONDS))
                }
            }
            probe("/held")
            val done = checkNotNull(device.findObject(By.res("connection-done"))).visibleCenter
            val points = listOf(held, Point(done.x.toFloat(), done.y.toFloat()))
            send(
                down,
                MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                points,
            )
            send(
                down,
                MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),
                points,
            )
            send(down, MotionEvent.ACTION_UP, listOf(held))
            assertNotNull(device.wait(Until.findObject(By.res("home-connect")), 10_000))
            probe("/neutral")
            ui { assertFalse(controller.engine.connected) }
        }
        probe("/finish")
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

    private fun waitForTargetApp() {
        val deadline = SystemClock.uptimeMillis() + 15_000
        var recoveredLauncher = false
        while (SystemClock.uptimeMillis() < deadline) {
            // Fresh Google-APIs CI images can show the launcher's boot ANR over
            // the running test Activity. Never dismiss a Thumble app failure.
            val launcher =
                device.findObject(
                    By.pkg("android")
                        .res("android:id/alertTitle")
                        .text("Pixel Launcher isn't responding")
                )
            if (launcher != null && android.os.Build.HARDWARE in setOf("ranchu", "goldfish")) {
                check(!recoveredLauncher) { "emulator_launcher_repeated_anr" }
                recoveredLauncher = true
                android.util.Log.w("ThumbleQa", "closing_emulator_launcher_anr")
                checkNotNull(device.findObject(By.pkg("android").res("android:id/aerr_close")))
                    .click()
                device.waitForIdle()
            }
            if (device.hasObject(By.pkg(target.packageName))) return
            SystemClock.sleep(100)
        }
        assertTrue("Target Activity was not visible", device.hasObject(By.pkg(target.packageName)))
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
