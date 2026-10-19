package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

class AdvancedControlTest {
    private fun control(kind: String, settings: JSONObject = JSONObject()) = Control(UUID.randomUUID(), kind, kind, JSONObject(), "standard", settings)
    private class Harness(val elements: List<Control>) {
        data class Edge(val id: UUID, val part: InputPart?, val down: Boolean, val press: Long)
        data class Analog(val target: String, val vector: Vector, val final: Boolean)
        data class Pointer(val kind: String, val delta: Vector, val button: String?, val down: Boolean?)
        val edges = mutableListOf<Edge>()
        val sticks = mutableListOf<Analog>()
        val triggers = mutableListOf<Analog>()
        val pointers = mutableListOf<Pointer>()
        val router = ControlGestures(
            { point, previous -> elements.firstOrNull { it.id == previous && inside(it, point, 18.0) }
                ?: elements.firstOrNull { inside(it, point) } },
            { control, point -> LocalContact(point.x - elements.indexOf(control) * 200, point.y, 100.0, 100.0) },
            { id, down, press -> edges.add(Edge(id, null, down, press)) },
            { id, part, down, press -> edges.add(Edge(id, part, down, press)) },
            { target, x, y, final -> sticks.add(Analog(target, Vector(x, y), final)) },
            { target, value, final -> triggers.add(Analog(target, Vector(value, 0.0), final)) },
            { kind, x, y, button, down -> pointers.add(Pointer(kind, Vector(x, y), button, down)) })
        private fun inside(control: Control, point: Vector, outset: Double = 0.0): Boolean {
            val x = point.x - elements.indexOf(control) * 200
            return x in -outset..(100 + outset) && point.y in -outset..(100 + outset)
        }
        fun event(phase: TouchPhase, changed: Int, time: Long, vararg points: Triple<Int, Double, Double>) =
            router.handle(phase, changed, points.map { Contact(it.first, Vector(it.second, it.third)) }, time)
    }

    @Test fun `canonical output settings match Swift normalization and transformations`() {
        val joystick = JoystickSettings.parse(JSONObject("""{"analogTarget":"leftStick","sendsDigitalDirections":false,"sensitivity":2,"invertX":true,"snapToCardinal":true}"""))
        assertEquals("left", joystick.target); assertFalse(joystick.digital)
        assertEquals(Vector(-1.0, 0.0), joystick.transform(Vector(.5, .25)))
        assertTrue(JoystickSettings.parse(JSONObject("""{"sendsDigitalDirections":false}""")).digital)
        assertEquals(Vector(), JoystickSettings().transform(Vector(.1, 0.0)))
        assertEquals((.5 - .12) / .88, JoystickSettings().transform(Vector(.5, 0.0)).x, .000001)
        assertEquals((.6 - .03) / .97, TriggerSettings().transform(.6), .000001)
        assertEquals(0.0, TriggerSettings().transform(.02), 0.0)
        assertEquals(1.0, TriggerSettings(sensitivity = 3.0).transform(1.0), 0.0)
        assertEquals(4.0, TrackpadSettings.parse(JSONObject().put("sensitivity", 99)).sensitivity, 0.0)
    }

    @Test fun `joystick directions retain physical IDs and capture outside while buttons remain independent`() {
        val joystick = control("joystick", JSONObject("""{"joystickOutputSettings":{"analogTarget":"leftStick"}}"""))
        val button = control("button")
        val h = Harness(listOf(joystick, button))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 95.0, 50.0))
        h.event(TouchPhase.DOWN, 2, 10, Triple(1, 95.0, 50.0), Triple(2, 250.0, 50.0))
        h.event(TouchPhase.MOVE, 1, 20, Triple(1, -30.0, 50.0), Triple(2, 250.0, 50.0))
        assertEquals(setOf(joystick.id, button.id), h.router.pressedIDs())
        val directionEdges = h.edges.filter { it.part != null }
        assertEquals(listOf(InputPart.JOYSTICK_RIGHT, InputPart.JOYSTICK_RIGHT, InputPart.JOYSTICK_LEFT), directionEdges.map { it.part })
        assertEquals(listOf(true, false, true), directionEdges.map { it.down })
        assertEquals(directionEdges[0].press, directionEdges[1].press)
        assertNotEquals(directionEdges[0].press, directionEdges[2].press)
        h.event(TouchPhase.UP, 2, 30, Triple(1, -30.0, 50.0), Triple(2, 250.0, 50.0))
        h.event(TouchPhase.CANCEL, 1, 40, Triple(1, -30.0, 50.0))
        assertEquals(Vector(), h.sticks.last().vector); assertTrue(h.sticks.last().final)
        assertTrue(h.router.pressedIDs().isEmpty())
        assertEquals(1, h.edges.count { it.id == button.id && it.down })
        assertEquals(1, h.edges.count { it.id == button.id && !it.down })
        assertEquals(directionEdges.last().press, h.edges.last().press)
    }

    @Test fun `digital joystick direction threshold uses raw capture vector while analog transforms separately`() {
        val h = Harness(listOf(control("joystick", JSONObject("""{"joystickOutputSettings":{"analogTarget":"rightStick","invertX":true,"deadZone":0.8}}"""))))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 75.0, 50.0))
        assertEquals(InputPart.JOYSTICK_RIGHT, h.edges.single().part)
        assertEquals(Vector(), h.sticks.single().vector)
        h.event(TouchPhase.MOVE, 1, 5, Triple(1, 100.0, 0.0))
        assertEquals(setOf(InputPart.JOYSTICK_RIGHT, InputPart.JOYSTICK_UP), h.edges.filter { it.down }.map { it.part }.toSet())
    }

    @Test fun `trigger threshold crossings release their exact press and final neutral cancels capture`() {
        val h = Harness(listOf(control("trigger", JSONObject("""{"triggerSettings":{"target":"left","orientation":"horizontal","sendsDigitalButton":true,"digitalThreshold":0.5}}"""))))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 80.0, 50.0))
        h.event(TouchPhase.MOVE, 1, 10, Triple(1, 60.0, 50.0))
        assertEquals(1, h.edges.count { it.down })
        h.event(TouchPhase.MOVE, 1, 20, Triple(1, -100.0, 50.0))
        assertEquals(2, h.edges.size)
        assertEquals(InputPart.TRIGGER_DIGITAL, h.edges.first().part)
        assertEquals(h.edges.first().press, h.edges.last().press)
        h.event(TouchPhase.UP, 1, 30, Triple(1, -100.0, 50.0))
        assertEquals(0.0, h.triggers.last().vector.x, 0.0)
        assertTrue(h.triggers.last().final)
    }

    @Test fun `trackpad moves in points and does not click after movement or cancellation`() {
        val h = Harness(listOf(control("trackpad")))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 20.0, 20.0))
        h.event(TouchPhase.MOVE, 1, 20, Triple(1, 60.0, 25.0))
        h.event(TouchPhase.UP, 1, 30, Triple(1, 60.0, 25.0))
        assertEquals(listOf("move"), h.pointers.map { it.kind })
        assertEquals(Vector(48.0, 6.0), h.pointers.single().delta)
        h.event(TouchPhase.DOWN, 2, 100, Triple(2, 20.0, 20.0))
        h.event(TouchPhase.CANCEL, 2, 110, Triple(2, 20.0, 20.0))
        assertEquals(1, h.pointers.size)
    }

    @Test fun `two finger scroll resets centroid after a finger lifts and retains natural scrolling preference`() {
        val h = Harness(listOf(control("trackpad", JSONObject("""{"trackpadSettings":{"naturalScrolling":false}}"""))))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 20.0, 20.0))
        h.event(TouchPhase.DOWN, 2, 10, Triple(1, 20.0, 20.0), Triple(2, 60.0, 60.0))
        h.event(TouchPhase.MOVE, 1, 20, Triple(1, 30.0, 30.0), Triple(2, 70.0, 70.0))
        assertEquals("scroll", h.pointers.single().kind)
        assertEquals(Vector(-8.5, -8.5), h.pointers.single().delta)
        h.event(TouchPhase.UP, 1, 30, Triple(1, 30.0, 30.0), Triple(2, 70.0, 70.0))
        h.event(TouchPhase.MOVE, 2, 40, Triple(2, 75.0, 70.0))
        assertEquals("move", h.pointers.last().kind)
        assertEquals(Vector(6.0, 0.0), h.pointers.last().delta)
        h.router.cancel()
        assertEquals(2, h.pointers.size)
    }

    @Test fun `one and two finger taps produce reliable left and right down up pairs`() {
        val h = Harness(listOf(control("trackpad")))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 20.0, 20.0))
        h.event(TouchPhase.UP, 1, 100, Triple(1, 20.0, 20.0))
        h.event(TouchPhase.DOWN, 2, 200, Triple(2, 20.0, 20.0))
        h.event(TouchPhase.DOWN, 3, 210, Triple(2, 20.0, 20.0), Triple(3, 70.0, 70.0))
        h.event(TouchPhase.UP, 2, 250, Triple(2, 20.0, 20.0), Triple(3, 70.0, 70.0))
        h.event(TouchPhase.UP, 3, 260, Triple(3, 70.0, 70.0))
        assertEquals(listOf("left", "left", "right", "right"), h.pointers.map { it.button })
        assertEquals(listOf(true, false, true, false), h.pointers.map { it.down })
    }

    @Test fun `input session encodes canonical parts and independently sequences analog and pointer streams`() {
        val frames = mutableListOf<ByteArray>()
        val session = InputSession({ frames.add(it) }, 71)
        val id = UUID.fromString("8f92f805-2d12-4d59-9a4d-d0086cdfc6c2")
        session.element(id, InputPart.JOYSTICK_LEFT, true, 91)
        val frame = frames.single()
        assertEquals(6, frame[3].toInt()); assertEquals(3, frame[20].toInt())
        assertEquals(71L, ByteBuffer.wrap(frame, 24, 8).order(ByteOrder.LITTLE_ENDIAN).long)
        assertEquals(91L, ByteBuffer.wrap(frame, 40, 8).order(ByteOrder.LITTLE_ENDIAN).long)
        session.stick("left", .5, -.3); session.trigger("right", .7)
        session.pointer("move", 5.0, -2.0); session.pointer("button", button = "left", down = true)
        session.heartbeat()
        val json = frames.filter { it.size != 56 }.map { JSONObject(it.toString(Charsets.UTF_8)) }
        val analog = json.filter { it.optString("type") == "gamepad_analog" }
        assertEquals(listOf(1L, 2L, 3L, 4L), analog.map { it.getLong("analogSequence") })
        val pointer = json.filter { it.optString("type") == "pointer" }
        assertEquals(listOf(1L, 2L), pointer.map { it.getLong("inputSequence") })
        assertTrue(json.all { it.getLong("inputGeneration") == 71L })
        session.releaseAll()
        val count = frames.size
        session.heartbeat()
        assertEquals("release clears all refreshes", count + 1, frames.size)
        assertEquals("heartbeat", JSONObject(frames.last().toString(Charsets.UTF_8)).getString("type"))
    }

    @Test fun `trackpad accessibility click retires both fingers until lift without releasing another hold`() {
        val pad = control("trackpad")
        val button = control("button")
        val h = Harness(listOf(pad, button))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 20.0, 20.0))
        h.event(TouchPhase.DOWN, 2, 10, Triple(1, 20.0, 20.0), Triple(2, 70.0, 70.0))
        h.event(TouchPhase.DOWN, 3, 20, Triple(1, 20.0, 20.0), Triple(2, 70.0, 70.0), Triple(3, 250.0, 50.0))
        h.router.accessibilityClick(pad, "right")
        assertEquals(listOf("right", "right"), h.pointers.map { it.button })
        assertEquals(listOf(true, false), h.pointers.map { it.down })
        assertEquals(setOf(button.id), h.router.pressedIDs())
        h.event(TouchPhase.MOVE, 1, 30, Triple(1, 35.0, 25.0), Triple(2, 75.0, 80.0), Triple(3, 250.0, 50.0))
        h.event(TouchPhase.UP, 1, 40, Triple(1, 35.0, 25.0), Triple(2, 75.0, 80.0), Triple(3, 250.0, 50.0))
        h.event(TouchPhase.UP, 2, 50, Triple(2, 75.0, 80.0), Triple(3, 250.0, 50.0))
        assertEquals("retired touches neither move nor tap", 2, h.pointers.size)
        assertEquals(1, h.edges.size)
        h.event(TouchPhase.DOWN, 1, 60, Triple(1, 20.0, 20.0), Triple(3, 250.0, 50.0))
        h.event(TouchPhase.UP, 1, 70, Triple(1, 20.0, 20.0), Triple(3, 250.0, 50.0))
        assertEquals(listOf("right", "right", "left", "left"), h.pointers.map { it.button })
        h.event(TouchPhase.UP, 3, 80, Triple(3, 250.0, 50.0))
        assertEquals(listOf(true, false), h.edges.map { it.down })
        assertEquals(h.edges.first().press, h.edges.last().press)
    }

    @Test fun `accessibility click remains available with physical tap and scrolling disabled`() {
        val pad = control("trackpad", JSONObject("""{"trackpadSettings":{"tapToClick":false,"twoFingerScroll":false}}"""))
        val h = Harness(listOf(pad))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 20.0, 20.0))
        h.event(TouchPhase.DOWN, 2, 10, Triple(1, 20.0, 20.0), Triple(2, 60.0, 60.0))
        h.event(TouchPhase.MOVE, 1, 20, Triple(1, 30.0, 30.0), Triple(2, 70.0, 70.0))
        assertTrue(h.pointers.isEmpty())
        h.router.accessibilityClick(pad, "left")
        h.router.cancel()
        assertEquals(listOf("left", "left"), h.pointers.map { it.button })
        assertTrue(h.router.pressedIDs().isEmpty())
    }

    @Test fun `accessibility direction retires the physical capture without releasing another control`() {
        val joystick = control("joystick", JSONObject("""{"joystickOutputSettings":{"analogTarget":"leftStick"}}"""))
        val button = control("button")
        val h = Harness(listOf(joystick, button))
        h.event(TouchPhase.DOWN, 1, 0, Triple(1, 95.0, 50.0))
        h.event(TouchPhase.DOWN, 2, 10, Triple(1, 95.0, 50.0), Triple(2, 250.0, 50.0))
        h.router.accessibilityDirection(joystick, InputPart.JOYSTICK_LEFT)
        assertEquals(setOf(button.id), h.router.pressedIDs())
        assertEquals(listOf(true, false), h.edges.filter { it.part == InputPart.JOYSTICK_RIGHT }.map { it.down })
        val count = h.edges.size
        h.event(TouchPhase.MOVE, 1, 20, Triple(1, 99.0, 50.0), Triple(2, 250.0, 50.0))
        assertEquals(count, h.edges.size)
        assertEquals(Vector(), h.sticks.last().vector)
        h.event(TouchPhase.UP, 1, 30, Triple(1, 99.0, 50.0), Triple(2, 250.0, 50.0))
        h.event(TouchPhase.DOWN, 3, 40, Triple(3, 95.0, 50.0), Triple(2, 250.0, 50.0))
        assertEquals(setOf(button.id, joystick.id), h.router.pressedIDs())
        h.router.cancel()
        assertEquals(1, h.edges.count { it.id == button.id && !it.down })
    }
}
