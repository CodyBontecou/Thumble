package com.thumble.rewrite.input

import java.util.concurrent.CompletableFuture
import org.junit.Assert.*
import org.junit.Test

class NativeProbeWaitTest {
    @Test
    fun stalledReplyKeepsHeldSamplingOnOwnerAndReleasedStateNeutral() {
        val owner = Thread.currentThread()
        val reports = mutableListOf<InputSample>()
        val engine =
            InputEngine({
                reports.add(it)
                true
            })
        engine.activate(
            ControlMap(
                generation = "1",
                revision = "1",
                controls = listOf(ControlRegion("south", "south", 0.0, 0.0, 1.0, 1.0)),
            )
        )
        engine.connect("1")
        assertTrue(engine.begin(1, "1", 0.2, 0.2))
        val reply = CompletableFuture<String>()
        var samples = 0
        assertEquals(
            "held",
            awaitNativeProbeReply(reply) {
                assertSame(owner, Thread.currentThread())
                engine.tick()
                assertTrue(engine.connected)
                assertNotEquals(GamepadReport.neutral(), engine.state)
                // Twenty-four waits keep the reply pending beyond the 350 ms renewal TTL.
                // Completion depends on owner-thread sampling, not an independent timer.
                if (++samples == 24) reply.complete("held")
            },
        )
        assertEquals(24, samples)
        engine.cancel(ReleaseReason.background)
        val released = CompletableFuture<String>()
        assertEquals(
            "neutral",
            awaitNativeProbeReply(released) {
                assertSame(owner, Thread.currentThread())
                engine.tick()
                assertFalse(engine.connected)
                assertEquals(GamepadReport.neutral(), engine.state)
                released.complete("neutral")
            },
        )
        assertTrue(reports.isNotEmpty())
    }
}
