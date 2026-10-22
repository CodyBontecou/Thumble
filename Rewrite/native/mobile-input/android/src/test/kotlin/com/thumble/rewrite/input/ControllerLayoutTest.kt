package com.thumble.rewrite.input

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ControllerLayoutTest {
    @Test
    fun sharedControllerHitTestingAndPracticeFeedback() {
        val root =
            JSONObject(
                requireNotNull(
                        javaClass.classLoader?.getResourceAsStream("controller-layout-v1.json")
                    )
                    .bufferedReader()
                    .use { it.readText() }
            )
        val raw = root.getJSONObject("map")
        val controls = raw.getJSONArray("controls")
        val map =
            ControlMap(
                generation = raw.getString("generation"),
                revision = raw.getString("revision"),
                controls =
                    (0 until controls.length()).map { i ->
                        val c = controls.getJSONObject(i)
                        ControlRegion(
                            c.getString("id"),
                            c.getString("action"),
                            c.getDouble("x"),
                            c.getDouble("y"),
                            c.getDouble("width"),
                            c.getDouble("height"),
                        )
                    },
            )
        val probes = root.getJSONArray("probes")
        assertEquals(19, probes.length())
        for (practice in listOf(false, true)) for (i in 0 until probes.length()) {
            val probe = probes.getJSONObject(i)
            val expected = probe.getString("reportHex")
            val samples = mutableListOf<InputSample>()
            val feedback = mutableListOf<String>()
            val engine =
                InputEngine(
                    {
                        samples.add(it)
                        true
                    },
                    { feedback.add(GamepadReport.hex(it)) },
                )
            engine.activate(map)
            if (practice) engine.setPractice(true) else engine.connect(map.generation)
            engine.begin(1, map.generation, probe.getDouble("x"), probe.getDouble("y"))
            engine.tick()
            assertEquals(probe.getString("id"), expected, GamepadReport.hex(engine.state))
            assertEquals(expected, feedback.last())
            if (practice) assertTrue(samples.isEmpty())
            else assertEquals(expected, GamepadReport.hex(samples.last().state))
            engine.cancel(ReleaseReason.background)
            engine.move(1, map.generation, probe.getDouble("x"), probe.getDouble("y"))
            assertEquals(
                GamepadReport.hex(GamepadReport.neutral()),
                GamepadReport.hex(engine.state),
            )
            assertEquals(GamepadReport.hex(GamepadReport.neutral()), feedback.last())
            assertFalse(engine.connected)
        }
        val chord = root.getJSONObject("chord")
        val ids = chord.getJSONArray("ids")
        for (practice in listOf(false, true)) {
            val sent = mutableListOf<String>()
            val engine =
                InputEngine({
                    sent.add(GamepadReport.hex(it.state))
                    true
                })
            engine.activate(map)
            if (practice) engine.setPractice(true) else engine.connect(map.generation)
            for (i in 0 until ids.length()) {
                val probe =
                    (0 until probes.length())
                        .map { probes.getJSONObject(it) }
                        .single { it.getString("id") == ids.getString(i) }
                engine.begin(
                    i.toLong() + 1,
                    map.generation,
                    probe.getDouble("x"),
                    probe.getDouble("y"),
                )
            }
            repeat(100) {
                engine.tick()
                assertEquals(chord.getString("reportHex"), GamepadReport.hex(engine.state))
            }
            if (practice) assertTrue(sent.isEmpty())
            else assertEquals(chord.getString("reportHex"), sent.last())
            engine.cancel(ReleaseReason.rotation)
            assertEquals(
                GamepadReport.hex(GamepadReport.neutral()),
                GamepadReport.hex(engine.state),
            )
            if (!practice) assertEquals(GamepadReport.hex(GamepadReport.neutral()), sent.last())
        }
    }
}
