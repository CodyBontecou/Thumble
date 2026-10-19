package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class IconArtworkTest {
    private fun control(kind: String = "button", label: String = "Long label", style: JSONObject = JSONObject()) = Control(UUID.randomUUID(), label, kind, style, "standard")
    private fun icon(placement: String) = ControlIcon.parse(JSONObject().put("source", "text").put("value", "↑").put("placement", placement))!!
    @Test fun `icons normalize native defaults and retain asset rendering mode`() {
        val icon = ControlIcon.parse(JSONObject().put("source", "asset").put("value", " photo ").put("scale", 50).put("renderingMode", "original"))!!
        assertEquals("photo", icon.value); assertEquals(3.0, icon.scale, 0.0); assertEquals("center", icon.placement); assertEquals("original", icon.renderingMode)
        assertNull(ControlIcon.parse(JSONObject().put("source", "text").put("value", " ")))
    }
    @Test fun `native icon and label placement use separate offsets and authored labels take precedence`() {
        val layout = iconLayout(control(), 200.0, 100.0, null, icon("leading"), true)
        assertEquals(34.0, layout.size, .0001); assertEquals(Vector(-40.0, 0.0), layout.offset); assertEquals(Vector(22.0, 0.0), layout.labelOffset)
        val top = iconLayout(control(), 200.0, 100.0, JSONObject().put("labelPlacement", "top"), icon("leading"), true)
        assertEquals(Vector(0.0, -28.0), top.labelOffset)
    }
    @Test fun `native centered icons hide long legends while preserving short and explicit text legends`() {
        assertFalse(iconLayout(control(), 100.0, 100.0, null, icon("center"), true).legendVisible)
        assertTrue(iconLayout(control(label = "A"), 100.0, 100.0, null, icon("center"), true).legendVisible)
        assertTrue(iconLayout(control("text"), 100.0, 100.0, null, icon("center"), false).legendVisible)
        assertFalse(iconLayout(control("decoration"), 100.0, 100.0, null, icon("center"), true).legendVisible)
        assertEquals(Vector(0.0, 34.0), iconLayout(control("joystick"), 100.0, 100.0, null, null, true).labelOffset)
    }
    @Test fun `artwork frames normalize and deterministic layer order does not depend on array order`() {
        fun layer(id: String, z: Int) = JSONObject().put("id", id).put("zIndex", z).put("fillStyle", JSONObject().put("kind", "solid"))
        val a = layer("z", 1); val b = layer("a", 1).put("frame", JSONObject().put("x", 2).put("y", -1).put("width", .4).put("height", 5))
        val hidden = layer("hidden", -1).put("isHidden", true)
        val result = artworkLayers(JSONArray().put(a).put(b).put(hidden))
        assertEquals(listOf("a", "z"), result.map { it.id })
        assertEquals(.6, result[0].x, 0.0); assertEquals(0.0, result[0].y, 0.0); assertEquals(1.0, result[0].height, 0.0)
    }
    @Test fun `legacy soft light follows the separable blend and source-over alpha rules`() {
        assertEquals(0xff606060.toInt(), softLight(0xffc0c0c0.toInt(), 0xff404040.toInt()))
        assertEquals(0xff123456.toInt(), softLight(0, 0xff123456.toInt()))
        assertEquals(0x804080c0.toInt(), softLight(0x804080c0.toInt(), 0))
        assertEquals(0xff000000.toInt(), softLight(0xff000000.toInt(), 0xff000000.toInt()))
        assertEquals(0xffffffff.toInt(), softLight(0xffffffff.toInt(), 0xffffffff.toInt()))
        assertEquals(0xff00007f.toInt(), blendArtwork("multiply", 0x80ff0000.toInt(), 0xff0000ff.toInt()))
        assertEquals(0x804080c0.toInt(), blendArtwork("multiply", 0x804080c0.toInt(), 0))
    }
}
