package com.thumble.rewrite.input

import kotlin.math.sqrt
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SavedAnalogInputTest {
    private fun fixture(): JSONObject =
        JSONObject(
            checkNotNull(javaClass.getResourceAsStream("/Fixtures/saved-controller-analog-control-v8.json"))
                .bufferedReader()
                .use { it.readText() }
        )

    private fun golden(): ControlMap {
        val f = fixture()
        val r = f.getJSONObject("request")
        return SavedControllerWire.decode(
                EnrollmentJSON.parse(f.getJSONObject("reply").toString().toByteArray()),
                SavedControllerRequest(
                    r.getString("expectedConfigurationRevision"),
                    r.getString("expectedSourceHash"),
                    r.getString("profileId"),
                    r.getString("generation"),
                    r.getString("revision"),
                    r.getString("viewportWidth"),
                    r.getString("viewportHeight"),
                ),
                "synthetic-authority",
                r.getString("connectionId"),
            )
            .map
    }

    private fun engine(map: ControlMap): InputEngine =
        InputEngine({ true }).also {
            it.activate(map)
            it.connect(map.generation)
        }

    private fun begin(e: InputEngine, c: ControlRegion, id: Long, x: Double, y: Double): Boolean =
        e.begin(id, e.generation, c.x + x * c.width, c.y + y * c.height)

    private fun move(e: InputEngine, c: ControlRegion, id: Long, x: Double, y: Double) =
        e.move(id, e.generation, c.x + x * c.width, c.y + y * c.height)

    private fun neutral(e: InputEngine) =
        assertEquals(GamepadReport.hex(GamepadReport.neutral()), GamepadReport.hex(e.state))

    @Test
    fun projectedGoldenGeometryUsesRetainedRadialStickMath() {
        val map = golden()
        assertEquals(
            listOf(
                "leftStandardStick",
                "rightStandardStick",
                "leftVerticalTrigger",
                "rightHorizontalTrigger",
                "south",
            ),
            map.controls.map { it.action },
        )
        val r = fixture().getJSONObject("reply")
        map.controls.forEachIndexed { index, c ->
            assertEquals(r.getString("control${index}X").toDouble(), c.x, 0.0)
            assertEquals(r.getString("control${index}Width").toDouble(), c.width, 0.0)
        }
        for (index in 0..1) {
            val e = engine(map)
            val c = map.controls[index]
            assertTrue(begin(e, c, 1, .5, .5))
            neutral(e)
            move(e, c, 1, .55, .5)
            neutral(e)
            move(e, c, 1, .78, .5)
            assertEquals(.5, if (index == 0) e.state.leftStickX else e.state.rightStickX, 1e-12)
            assertEquals(0.0, if (index == 0) e.state.leftStickY else e.state.rightStickY, 1e-12)
            move(e, c, 1, 1.0, 1.0)
            assertEquals(
                sqrt(.5),
                if (index == 0) e.state.leftStickX else e.state.rightStickX,
                1e-12,
            )
            assertEquals(
                sqrt(.5),
                if (index == 0) e.state.leftStickY else e.state.rightStickY,
                1e-12,
            )
            move(e, c, 1, -.5, .5)
            assertEquals(-1.0, if (index == 0) e.state.leftStickX else e.state.rightStickX, 1e-12)
            assertTrue(e.state.buttons.isEmpty())
            e.end(1, e.generation)
            neutral(e)
        }
    }

    @Test
    fun goldenBothSticksAndTriggersStayIndependentThroughHeldMovesAndCancel() {
        val map = golden()
        val e = engine(map)
        assertTrue(begin(e, map.controls[0], 1, .78, .5))
        assertTrue(begin(e, map.controls[1], 2, .5, .22))
        assertTrue(begin(e, map.controls[2], 3, .5, .485))
        assertTrue(begin(e, map.controls[3], 4, .515, .5))
        e.tick()
        assertEquals(.5, e.state.leftStickX, 1e-12)
        assertEquals(-.5, e.state.rightStickY, 1e-12)
        assertEquals(.5, e.state.leftTrigger, 1e-12)
        assertEquals(.5, e.state.rightTrigger, 1e-12)
        move(e, map.controls[2], 3, .5, -1.0)
        move(e, map.controls[3], 4, -1.0, .5)
        assertEquals(1.0, e.state.leftTrigger, 0.0)
        assertEquals(0.0, e.state.rightTrigger, 0.0)
        e.end(3, e.generation)
        assertEquals(.5, e.state.leftStickX, 1e-12)
        assertEquals(-.5, e.state.rightStickY, 1e-12)
        e.cancel(ReleaseReason.touchCancelled)
        neutral(e)
        e.move(1, e.generation, .5, .5)
        e.tick()
        neutral(e)
        assertFalse(e.connected)
    }

    @Test
    fun allFourContinuousTriggerNamesClampThenApplyPointZeroThreeDeadzone() {
        for (action in
            listOf(
                "leftVerticalTrigger",
                "rightVerticalTrigger",
                "leftHorizontalTrigger",
                "rightHorizontalTrigger",
            )) {
            val c = ControlRegion("trigger", action, 0.0, 0.0, 1.0, 1.0)
            val e = engine(ControlMap(generation = "7", revision = "2", controls = listOf(c)))
            val vertical = action.endsWith("VerticalTrigger")
            assertTrue(begin(e, c, 1, if (vertical) .5 else 0.0, if (vertical) .99 else .5))
            for ((raw, expected) in
                listOf(.0 to .0, .02 to .0, .515 to .5, 1.5 to 1.0, -1.0 to 0.0)) {
                move(e, c, 1, if (vertical) .5 else raw, if (vertical) 1 - raw else .5)
                assertEquals(
                    expected,
                    if (action.startsWith("left")) e.state.leftTrigger else e.state.rightTrigger,
                    1e-12,
                )
                assertTrue(e.state.buttons.isEmpty())
            }
            e.end(1, e.generation)
            neutral(e)
        }
    }

    @Test
    fun legacyLinearSticksAndBinaryTriggersKeepTheirMeaning() {
        for (action in listOf("leftStick", "rightStick", "leftTrigger", "rightTrigger")) {
            val c = ControlRegion("legacy", action, 0.0, 0.0, 1.0, 1.0)
            val e = engine(ControlMap(generation = "1", revision = "0", controls = listOf(c)))
            assertTrue(begin(e, c, 1, .55, .5))
            when (action) {
                "leftStick" -> assertEquals(.1, e.state.leftStickX, 1e-12)
                "rightStick" -> assertEquals(.1, e.state.rightStickX, 1e-12)
                "leftTrigger" -> assertEquals(1.0, e.state.leftTrigger, 0.0)
                "rightTrigger" -> assertEquals(1.0, e.state.rightTrigger, 0.0)
            }
            e.end(1, e.generation)
            neutral(e)
        }
    }

    @Test
    fun aliasesShareOneCaptureOwnerAndReleasedTargetsCanBeReacquired() {
        for (names in
            listOf(
                listOf("leftStick", "leftStandardStick"),
                listOf("rightStandardStick", "rightStick"),
                listOf("leftTrigger", "leftVerticalTrigger", "leftHorizontalTrigger"),
                listOf("rightVerticalTrigger", "rightHorizontalTrigger", "rightTrigger"),
            )) {
            val controls = names.mapIndexed { i, a ->
                ControlRegion("alias-$i", a, i.toDouble() / names.size, 0.0, 1.0 / names.size, 1.0)
            }
            val e = engine(ControlMap(generation = "1", revision = "0", controls = controls))
            assertTrue(begin(e, controls[0], 1, .5, .5))
            controls.drop(1).forEachIndexed { i, c -> assertFalse(begin(e, c, 2L + i, .5, .5)) }
            e.end(1, e.generation)
            assertTrue(begin(e, controls.last(), 9, .5, .5))
            e.end(9, e.generation)
            neutral(e)
        }
    }

    @Test
    fun replacementAndPracticeNeverResurrectCapturedAnalogState() {
        val map = golden()
        val samples = mutableListOf<InputSample>()
        val e =
            InputEngine({
                samples.add(it)
                true
            })
        e.activate(map)
        e.connect(map.generation)
        assertTrue(begin(e, map.controls[0], 1, .78, .5))
        e.activate(ControlMap(generation = "8", revision = "3", controls = map.controls))
        neutral(e)
        e.move(1, "7", 1.0, 1.0)
        e.connect("8")
        neutral(e)
        e.setPractice(true)
        val count = samples.size
        assertTrue(begin(e, map.controls[2], 2, .5, .485))
        assertEquals(.5, e.state.leftTrigger, 1e-12)
        assertEquals(count, samples.size)
        e.cancel(ReleaseReason.rotation)
        neutral(e)
        e.move(2, "8", .5, .5)
        neutral(e)
    }

    @Test
    fun analogNamesRemainStrictAndNoWireParameterCanRedefineTheirMath() {
        val f = fixture()
        for (action in
            listOf(
                "LeftStandardStick",
                "leftStandardStick ",
                "leftVerticalTrigger:0.03",
                "rightHorizontalTriggerDigital",
            )) {
            val fields =
                JSONObject(f.getJSONObject("reply").toString()).put("control0Action", action)
            val r = f.getJSONObject("request")
            try {
                SavedControllerWire.decode(
                    EnrollmentJSON.parse(fields.toString().toByteArray()),
                    SavedControllerRequest(
                        r.getString("expectedConfigurationRevision"),
                        r.getString("expectedSourceHash"),
                        r.getString("profileId"),
                        r.getString("generation"),
                        r.getString("revision"),
                        r.getString("viewportWidth"),
                        r.getString("viewportHeight"),
                    ),
                    "synthetic-authority",
                    r.getString("connectionId"),
                )
                fail("unknown analog action admitted")
            } catch (_: SavedControllerRejected) {}
        }
        val map = golden()
        val bad =
            map.controls.mapIndexed { i, c ->
                if (i == 0) c.copy(action = "leftStandardStickCustom") else c
            }
        try {
            ControlMap(generation = "7", revision = "2", controls = bad).validated()
            fail("custom action admitted")
        } catch (_: IllegalArgumentException) {}
    }
}
