package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ControlPresentationTest {
    private fun control(kind: String = "button", style: JSONObject = JSONObject()) = Control(UUID.randomUUID(), "Authored", kind, style, "standard")
    private fun solid(red: Double) = JSONObject().put("kind", "solid").put("color", JSONObject().put("red", red).put("green", 0).put("blue", 0))
    private fun canvas(applies: JSONArray = JSONArray().put("button")): JSONObject {
        val visual = JSONObject()
            .put("normal", JSONObject().put("fillStyle", solid(.2)).put("strokeWidth", 3).put("content", JSONObject().put("fontSize", 24).put("legend", "Token")))
            .put("pressed", JSONObject().put("fillStyle", solid(.8)).put("content", JSONObject().put("fontWeight", "bold")))
        val token = JSONObject().put("id", "token").put("name", "Token").put("appliesTo", applies).put("visualStyle", visual)
        return JSONObject().put("styleLibrary", JSONObject().put("styles", JSONArray().put(token)))
    }

    @Test fun `token state inherits normal fields then inline normal overrides the token state`() {
        val style = JSONObject().put("styleID", "token").put("visualStyle", JSONObject()
            .put("normal", JSONObject().put("fillStyle", solid(.4)).put("content", JSONObject().put("legend", "Inline")))
            .put("pressed", JSONObject().put("content", JSONObject().put("fontSize", 30))))
        val c = control(style = style)
        val source = style.toString()
        val result = ControlPresentation.resolve(c, canvas(), PresentationState.PRESSED, false)
        assertEquals(.4, result.getJSONObject("fillStyle").getJSONObject("color").getDouble("red"), 0.0)
        assertEquals(3.0, result.getDouble("strokeWidth"), 0.0)
        val content = result.getJSONObject("content")
        assertEquals("Inline", content.getString("legend")); assertEquals("bold", content.getString("fontWeight")); assertEquals(30.0, content.getDouble("fontSize"), 0.0)
        assertEquals("resolution does not mutate the synced profile", source, style.toString())
    }
    @Test fun `active uses its own override or falls back to pressed without changing token applicability`() {
        val style = JSONObject().put("styleID", "token")
        val base = canvas(JSONArray().put("trigger"))
        val c = control("trigger", style)
        assertEquals(.8, ControlPresentation.resolve(c, base, PresentationState.ACTIVE, true).getJSONObject("fillStyle").getJSONObject("color").getDouble("red"), 0.0)
        base.getJSONObject("styleLibrary").getJSONArray("styles").getJSONObject(0).getJSONObject("visualStyle").put("active", JSONObject().put("fillStyle", solid(.9)))
        assertEquals(.9, ControlPresentation.resolve(c, base, PresentationState.ACTIVE, false).getJSONObject("fillStyle").getJSONObject("color").getDouble("red"), 0.0)
        assertEquals(1.0, ControlPresentation.resolve(control("button", style), base, PresentationState.NORMAL, false).getDouble("strokeWidth"), 0.0)
    }
    @Test fun `native baseline darkens authored fills but explicit state fills stay exact and images stay unchanged`() {
        val style = JSONObject().put("fillStyle", solid(1.0))
        val c = control(style = style)
        assertEquals(.74, ControlPresentation.resolve(c, JSONObject(), PresentationState.PRESSED, false).getJSONObject("fillStyle").getJSONObject("color").getDouble("red"), 0.0)
        style.put("visualStyle", JSONObject().put("pressed", JSONObject().put("fillStyle", solid(.9))))
        assertEquals(.9, ControlPresentation.resolve(c, JSONObject(), PresentationState.PRESSED, false).getJSONObject("fillStyle").getJSONObject("color").getDouble("red"), 0.0)
        style.remove("visualStyle")
        val image = JSONObject().put("kind", "image").put("image", JSONObject().put("assetID", "picture").put("opacity", .5))
        style.put("fillStyle", image)
        assertEquals(image.toString(), ControlPresentation.resolve(c, JSONObject(), PresentationState.PRESSED, false).getJSONObject("fillStyle").toString())
    }
    @Test fun `null state fields inherit while zero fields override and native bounds normalize`() {
        val style = JSONObject().put("visualStyle", JSONObject().put("normal", JSONObject().put("strokeWidth", 4))
            .put("disabled", JSONObject().put("strokeWidth", JSONObject.NULL).put("opacity", 0).put("scale", 9)
                .put("content", JSONObject().put("fontSize", 1000).put("lineLimit", 9))))
        val result = ControlPresentation.resolve(control(style = style), JSONObject(), PresentationState.DISABLED, false)
        assertEquals(4.0, result.getDouble("strokeWidth"), 0.0); assertEquals(0.0, result.getDouble("opacity"), 0.0); assertEquals(1.5, result.getDouble("scale"), 0.0)
        assertEquals(72.0, result.getJSONObject("content").getDouble("fontSize"), 0.0); assertEquals(4, result.getJSONObject("content").getInt("lineLimit"))
    }
    @Test fun `native accent baseline uses current Geist palette in each scheme`() {
        val c = control()
        val blue = JSONObject().put("accentStyle", "blue")
        val normal = ControlPresentation.resolve(c, blue, PresentationState.NORMAL, false).getJSONObject("fillStyle").getJSONObject("color")
        assertEquals(240.0 / 255, normal.getDouble("red"), 0.0)
        val pressed = ControlPresentation.resolve(c, blue, PresentationState.PRESSED, true).getJSONObject("fillStyle").getJSONObject("color")
        assertEquals(71.0 / 255, pressed.getDouble("red"), 0.0)
        assertEquals(168.0 / 255, pressed.getDouble("green"), 0.0)
    }
    @Test fun `style identifiers match native normalization and an empty applicability list means every kind`() {
        assertEquals("token-name", normalizedStyleID(" ..token name.. "))
        val c = control("trackpad", JSONObject().put("styleID", "token"))
        assertEquals(3.0, ControlPresentation.resolve(c, canvas(JSONArray()), PresentationState.NORMAL, false).getDouble("strokeWidth"), 0.0)
    }
    @Test fun `authored face scale combines with native kind-specific press scale`() {
        val presentation = JSONObject().put("scale", .5)
        assertEquals(.47f, ControlPresentation.effectiveScale(control(), true, presentation), .0001f)
        assertEquals(.485f, ControlPresentation.effectiveScale(control("trackpad"), true, presentation), .0001f)
        assertEquals(.5f, ControlPresentation.effectiveScale(control("joystick"), true, presentation), .0001f)
        assertEquals(.5f, ControlPresentation.effectiveScale(control(), false, presentation), .0001f)
    }
}
