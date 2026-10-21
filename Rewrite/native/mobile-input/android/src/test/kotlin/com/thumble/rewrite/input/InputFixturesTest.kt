package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadButtonV1
import com.thumble.rewrite.contracts.GamepadStateV1
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

private fun fixture(name: String): JSONObject =
    JSONObject(
        requireNotNull(InputEngine::class.java.classLoader?.getResourceAsStream(name)) {
                "missing_fixture_$name"
            }
            .bufferedReader()
            .use { it.readText() }
    )

private fun controls(array: JSONArray): List<ControlRegion> =
    (0 until array.length()).map { i ->
        val r = array.getJSONObject(i)
        ControlRegion(
            r.getString("id"),
            r.getString("action"),
            r.getDouble("x"),
            r.getDouble("y"),
            r.getDouble("width"),
            r.getDouble("height"),
        )
    }

private fun state(o: JSONObject) =
    GamepadStateV1(
        o.optJSONArray("buttons")?.let { a ->
            (0 until a.length()).map { GamepadButtonV1.valueOf(a.getString(it)) }
        } ?: emptyList(),
        o.optDouble("leftStickX", 0.0),
        o.optDouble("leftStickY", 0.0),
        o.optDouble("rightStickX", 0.0),
        o.optDouble("rightStickY", 0.0),
        o.optDouble("leftTrigger", 0.0),
        o.optDouble("rightTrigger", 0.0),
    )

@RunWith(Parameterized::class)
class InputFixturesTest(private val name: String, private val scenario: JSONObject) {
    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun scenarios(): List<Array<Any>> {
            val scenarios = fixture("mobile-input-v1.json").getJSONArray("scenarios")
            assertEquals(15, scenarios.length())
            return (0 until scenarios.length()).map { i ->
                val s = scenarios.getJSONObject(i)
                arrayOf(s.getString("name"), s)
            }
        }
    }

    @Test
    fun nativeTouchLifecycle() {
        val base = fixture("mobile-input-v1.json").getJSONObject("map")
        val regions = controls(scenario.optJSONArray("controls") ?: base.getJSONArray("controls"))
        val samples = mutableListOf<InputSample>()
        val engine =
            InputEngine({
                samples.add(it)
                true
            })
        engine.activate(ControlMap(generation = "1", revision = "1", controls = regions))
        val events = scenario.getJSONArray("events")
        for (i in 0 until events.length()) {
            val e = events.getJSONObject(i)
            val expected = e.getJSONObject("expected")
            val generation = e.optString("generation", engine.generation)
            var failure: String? = null
            try {
                when (e.getString("type")) {
                    "connect" -> engine.connect(generation)
                    "activate" ->
                        engine.activate(
                            ControlMap(generation = generation, revision = "1", controls = regions)
                        )
                    "begin" ->
                        engine.begin(
                            e.getLong("id"),
                            generation,
                            e.getDouble("x"),
                            e.getDouble("y"),
                        )
                    "move" ->
                        engine.move(e.getLong("id"), generation, e.getDouble("x"), e.getDouble("y"))
                    "end" -> engine.end(e.getLong("id"), generation)
                    "cancel" -> engine.cancel(ReleaseReason.valueOf(e.getString("reason")))
                    "practice" -> engine.setPractice(e.getBoolean("enabled"))
                    "tick" -> engine.tick()
                    else -> fail("unknown_fixture_event")
                }
            } catch (error: RuntimeException) {
                failure = error.message
            }
            assertEquals(
                "$name step $i failure",
                if (e.has("error")) e.getString("error") else null,
                failure,
            )
            val s = state(expected.getJSONObject("state"))
            val actual = engine.state
            assertTrue(GamepadReport.valid(actual))
            assertEquals(s.buttons, actual.buttons)
            val a =
                listOf(
                    actual.leftStickX,
                    actual.leftStickY,
                    actual.rightStickX,
                    actual.rightStickY,
                    actual.leftTrigger,
                    actual.rightTrigger,
                )
            val b =
                listOf(
                    s.leftStickX,
                    s.leftStickY,
                    s.rightStickX,
                    s.rightStickY,
                    s.leftTrigger,
                    s.rightTrigger,
                )
            a.zip(b).forEach { (x, y) -> assertEquals(x, y, 1e-9) }
            assertEquals(expected.getString("reportHex"), GamepadReport.hex(actual))
            assertEquals(expected.getBoolean("connected"), engine.connected)
            assertEquals(expected.getBoolean("practice"), engine.practice)
            assertEquals(expected.getInt("hostSamples"), samples.size)
            assertTrue(samples.all { GamepadReport.valid(it.state) })
        }
        samples.zipWithNext().forEach { (a, b) ->
            if (a.generation == b.generation)
                assertTrue(b.sequence.toULong() > a.sequence.toULong())
        }
    }
}

class InputEngineSafetyTest {
    private fun map(
        generation: String = "1",
        controls: List<ControlRegion> =
            controls(fixture("mobile-input-v1.json").getJSONObject("map").getJSONArray("controls")),
    ) = ControlMap(generation = generation, revision = "1", controls = controls)

    @Test
    fun allRetainedNativeVectors() {
        val vectors = fixture("v2.json").getJSONArray("vectors")
        assertEquals(34, vectors.length())
        for (i in 0 until vectors.length()) {
            val v = vectors.getJSONObject(i)
            assertEquals(v.getString("name"), v.getString("hex"), GamepadReport.hex(state(v)))
        }
        val bad =
            GamepadStateV1(
                emptyList(),
                Double.NaN,
                Double.POSITIVE_INFINITY,
                0.0,
                0.0,
                Double.NaN,
                Double.NEGATIVE_INFINITY,
            )
        assertFalse(GamepadReport.valid(bad))
        assertEquals(GamepadReport.hex(GamepadReport.neutral()), GamepadReport.hex(bad))
    }

    @Test
    fun invalidConfigurationPreservesHeldInputAndOwnsItsControlList() {
        val list = map().controls.toMutableList()
        val immutable = map(controls = list)
        list.clear()
        val engine = InputEngine({ true })
        engine.activate(immutable)
        engine.connect("1")
        engine.begin(1, "1", .67, .1)
        assertThrows(IllegalArgumentException::class.java) {
            engine.activate(
                map("2", listOf(ControlRegion("bad", "south", 0.0, 0.0, Double.NaN, 1.0)))
            )
        }
        assertTrue(engine.connected)
        assertEquals(listOf(GamepadButtonV1.south), engine.state.buttons)
        assertThrows(IllegalArgumentException::class.java) {
            engine.activate(map("18446744073709551616"))
        }
        assertEquals("1", engine.generation)
    }

    @Test
    fun touchBoundsAndNonfiniteEventsFailClosed() {
        val engine = InputEngine({ true })
        engine.activate(map())
        engine.connect("1")
        for (id in 0L until 16L) assertTrue(engine.begin(id, "1", .67, .1))
        assertFalse(engine.begin(16, "1", .67, .1))
        assertFalse(engine.connected)
        assertTrue(engine.state.buttons.isEmpty())
        engine.activate(map("2"))
        engine.connect("2")
        assertFalse(engine.begin(1, "2", Double.NaN, .1))
        assertFalse(engine.connected)
    }

    @Test
    fun transportFailureCannotReplayHeldTouches() {
        var available = true
        val engine = InputEngine({ available })
        engine.activate(map())
        engine.connect("1")
        engine.begin(1, "1", .67, .1)
        available = false
        engine.tick()
        assertFalse(engine.connected)
        assertTrue(engine.state.buttons.isEmpty())
        assertEquals(ReleaseReason.transportFailure, engine.lastRelease)
        assertThrows(IllegalStateException::class.java) { engine.connect("1") }
    }

    @Test
    fun crossThreadMutationIsRejected() {
        val engine = InputEngine({ true })
        engine.activate(map())
        val failure = java.util.concurrent.atomic.AtomicReference<Throwable?>()
        val thread = Thread {
            try {
                engine.connect("1")
            } catch (t: Throwable) {
                failure.set(t)
            }
        }
        thread.start()
        thread.join()
        assertEquals("wrong_input_thread", failure.get()?.message)
        assertFalse(engine.connected)
    }
}

class NativeDisposalTest {
    @Test
    fun disposalStopsCallbacksAndTransportExceptionsFailClosed() {
        val regions =
            controls(fixture("mobile-input-v1.json").getJSONObject("map").getJSONArray("controls"))
        var count = 0
        var fail = false
        val engine =
            InputEngine({
                count++
                if (fail) throw IllegalStateException("native_transport_failure")
                true
            })
        engine.activate(ControlMap(generation = "1", revision = "1", controls = regions))
        engine.connect("1")
        engine.setPractice(false)
        engine.begin(1, "1", .67, .1)
        assertEquals(listOf(GamepadButtonV1.south), engine.state.buttons)
        fail = true
        engine.tick()
        assertFalse(engine.connected)
        assertTrue(engine.state.buttons.isEmpty())
        assertEquals(ReleaseReason.transportFailure, engine.lastRelease)
        engine.cancel(ReleaseReason.disposed)
        val finalCount = count
        engine.tick()
        engine.cancel(ReleaseReason.background)
        assertEquals(finalCount, count)
        assertEquals(ReleaseReason.disposed, engine.lastRelease)
    }
}
