package com.thumble.rewrite.input

import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.*
import org.junit.Test

class SurfaceClaimTest {
    private fun map(generation: String = "7") =
        ControlMap(
            generation = generation,
            revision = "4",
            controls = listOf(ControlRegion("face", "south", 0.0, 0.0, 1.0, 1.0)),
        )

    private fun rejects(action: () -> Unit) {
        try {
            action()
            fail("surface claim accepted")
        } catch (_: IllegalStateException) {}
    }

    @Test
    fun boundGenerationAndPacketSequenceSurviveOneSurfaceClaim() {
        val samples = mutableListOf<InputSample>()
        val engine =
            InputEngine({
                samples.add(it)
                true
            })
        engine.activate(map())
        engine.connect("7")
        val admitted = engine.claimTouchSurface()
        assertEquals("7", admitted.generation)
        assertEquals("4", admitted.revision)
        assertEquals("face", admitted.controls.single().id)
        assertTrue(engine.connected)
        assertEquals(listOf("0"), samples.map { it.sequence })
        assertTrue(engine.begin(1, "7", 0.5, 0.5))
        assertEquals(listOf("0", "1"), samples.map { it.sequence })
        rejects { engine.claimTouchSurface() }
        assertTrue(engine.connected)
        assertEquals(1, engine.state.buttons.size)
        engine.cancel(ReleaseReason.disconnected)
        engine.activate(map("8"))
        engine.connect("8")
        rejects { engine.claimTouchSurface() }
    }

    @Test
    fun inactivePracticeFailedAndPreviouslySampledEnginesCannotBeClaimed() {
        val engine = InputEngine({ true })
        rejects { engine.claimTouchSurface() }
        engine.activate(map())
        engine.setPractice(true)
        rejects { engine.claimTouchSurface() }
        engine.setPractice(false)
        engine.connect("7")
        engine.tick()
        rejects { engine.claimTouchSurface() }
        assertTrue(engine.connected)
        val failed = InputEngine({ false })
        failed.activate(map())
        failed.connect("7")
        assertFalse(failed.connected)
        rejects { failed.claimTouchSurface() }
    }

    @Test
    fun wrongThreadCannotConsumeAnOtherwiseFreshHandoff() {
        val engine = InputEngine({ true })
        engine.activate(map())
        engine.connect("7")
        val failure = AtomicReference<Throwable?>()
        val worker = Thread {
            try {
                engine.claimTouchSurface()
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        worker.start()
        worker.join(1000)
        assertFalse(worker.isAlive)
        assertTrue(failure.get() is IllegalStateException)
        assertEquals("7", engine.claimTouchSurface().generation)
    }
}
