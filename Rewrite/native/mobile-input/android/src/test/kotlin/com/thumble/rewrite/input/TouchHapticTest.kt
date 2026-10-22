package com.thumble.rewrite.input

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class TouchHapticTest {
    @Test
    fun retainedSchedulesAndBounds() {
        val double =
            TouchHapticPolicy()
                .schedule(
                    TouchHapticFeedback(
                        pattern = TouchHapticFeedback.Pattern.double,
                        intensity = 1.0,
                        duration = .30,
                    ),
                    0.0,
                )
        assertEquals(listOf(0.0, 180.0), double.map { it.delayMilliseconds })
        assertEquals(listOf(1.0, .85), double.map { it.intensity })
        val buzz =
            TouchHapticPolicy()
                .schedule(
                    TouchHapticFeedback(pattern = TouchHapticFeedback.Pattern.buzz, duration = .30),
                    0.0,
                )
        assertEquals(6, buzz.size)
        assertEquals(225.0, buzz.last().delayMilliseconds, 0.0)
    }

    @Test
    fun optoutAndRateGateRejectRollback() {
        val p = TouchHapticPolicy()
        val f = TouchHapticFeedback()
        assertTrue(p.schedule(f, 0.0, 0.0).isEmpty())
        assertTrue(p.schedule(f, 0.0, enabled = false).isEmpty())
        assertTrue(
            p.schedule(TouchHapticFeedback(style = TouchHapticFeedback.Style.none), 0.0).isEmpty()
        )
        assertEquals(.225, p.schedule(f, 100.0, .5).first().intensity, 0.0)
        assertTrue(p.schedule(f, 149.0).isEmpty())
        assertTrue(p.schedule(f, 99.0).isEmpty())
        assertEquals(1, p.schedule(f, 150.0).size)
    }

    @Test
    fun strictCanonicalMetadata() {
        val source =
            """{"style":"light","pattern":"single","intensity":0.45,"sharpness":0.48,"duration":0.06}"""
        assertEquals(TouchHapticFeedback(), TouchHapticFeedback.decode(JSONObject(source)))
        for (text in
            listOf(
                source.replace("light", "invalid"),
                source.replace("0.06", "0.31"),
                source.replace("0.45", "true"),
                source.replace("}", ",\"extra\":true}"),
            )) {
            assertTrue(runCatching { TouchHapticFeedback.decode(JSONObject(text)) }.isFailure)
        }
        assertFalse(TouchHapticFeedback(intensity = Double.NaN).valid())
    }
}
