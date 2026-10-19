package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ControlGeometryTest {
    private fun control(kind: String = "button", style: String = "{}", slot: Int? = null) = Control(
        slot?.let { UUID(0, 0x100L + it) } ?: UUID.fromString("483d6c66-fd25-452c-98db-77192e7629aa"),
        "Control", kind, JSONObject(style), "standard")

    @Test fun `native visual geometry keeps non-square circle dimensions and authored overlap`() {
        val c = control(style = """{"shape":"circle","widthScale":2,"heightScale":0.5,"centerX":0.7,"centerY":0.3}""")
        val f = ControlGeometry.resolve(c, 375.0, 700.0, false)
        assertEquals(150.0, f.width, .0001); assertEquals(37.5, f.height, .0001)
        assertEquals(262.5, f.centerX, .0001); assertEquals(210.0, f.centerY, .0001)
        assertEquals(f, ControlGeometry.resolve(c.copy(id = UUID.randomUUID()), 375.0, 700.0, false))
    }
    @Test fun `oversized authored frames remain centered and preserve dimensions`() {
        val f = ControlGeometry.resolve(control(style = """{"widthScale":12,"heightScale":12,"centerX":0,"centerY":1}"""), 100.0, 100.0, false)
        assertEquals(600.0, f.width, 0.0); assertEquals(600.0, f.height, 0.0)
        assertEquals(50.0, f.centerX, 0.0); assertEquals(50.0, f.centerY, 0.0)
        assertEquals(-250.0, f.left, 0.0)
    }
    @Test fun `only starter buttons receive native default placement and menu sizing`() {
        val custom = ControlGeometry.resolve(control(), 375.0, 700.0, false)
        assertEquals(350.0, custom.centerY, 0.0)
        val up = ControlGeometry.resolve(control(slot = 1), 375.0, 700.0, false)
        assertEquals(113.5, up.centerY, .0001)
        val customJoystick = ControlGeometry.resolve(control("joystick", slot = 1), 375.0, 700.0, false)
        assertEquals(350.0, customJoystick.centerY, 0.0)
        val menu = ControlGeometry.resolve(control(slot = 9), 375.0, 700.0, false)
        assertEquals(111.0, menu.width, .0001); assertEquals(54.0, menu.height, .0001)
        val text = ControlGeometry.resolve(control("text"), 375.0, 700.0, false)
        assertEquals(43.5, text.height, .0001)
        assertEquals(75.0, text.width, .0001)
    }
    @Test fun `all canonical control base sizes match the native resolver in both orientations`() {
        val expected = mapOf("joystick" to (90.0 to 90.0), "trigger" to (90.0 to 34.0), "trackpad" to (157.5 to 92.0))
        for ((kind, size) in expected) {
            val f = ControlGeometry.resolve(control(kind), 375.0, 700.0, false)
            assertEquals(size.first, f.width, .0001); assertEquals(size.second, f.height, .0001)
        }
        val f = ControlGeometry.resolve(control("trackpad"), 700.0, 375.0, false)
        assertEquals(180.0, f.width, 0.0); assertEquals(105.0, f.height, .0001)
    }
}
