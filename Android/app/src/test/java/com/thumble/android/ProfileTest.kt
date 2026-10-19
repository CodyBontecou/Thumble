package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ProfileTest {
    private fun fixture(name: String) = JSONObject(javaClass.getResource("/controller-templates/v1/$name.json")!!.readText()).getJSONObject("profile")
    @Test fun `real productivity and SNES profiles decode both orientation variants`() {
        for (name in listOf("productivityStarter", "snes")) {
            val profile = ControllerProfile.parse(fixture(name))
            val expected = if (name == "snes") 12 else 10
            assertEquals(expected, profile.controls(false).count { it.kind == "button" })
            assertEquals(expected, profile.controls(true).count { it.kind == "button" })
            assertEquals(expected, profile.controls(false).filter { it.kind == "button" }.map { it.id }.distinct().size)
        }
        assertTrue(ControllerProfile.parse(fixture("productivityStarter")).controls(true).any { it.label == "Return" })
    }
    @Test fun `snapshot selects host profile identity and preserves it through incremental messages`() {
        val raw = fixture("snes")
        val message = WireCodec.message("pairing_accepted").put("gamepadProfiles", org.json.JSONArray().put(raw)).put("gamepadProfileID", raw.getString("id"))
        val snapshot = ProfileSnapshot().applying(message)
        assertEquals(raw.getString("id"), snapshot.selected!!.id.toString().uppercase())
        assertEquals(snapshot.selectedID, snapshot.applying(WireCodec.message("heartbeat")).selectedID)
    }
    @Test fun `hidden elements cannot send input and unsupported controls are reported`() {
        val raw = fixture("productivityStarter")
        val layout = raw.getJSONObject("landscapeCustomization")
        val elements = layout.getJSONArray("elements")
        layout.remove("buttonCustomizations")
        elements.getJSONObject(0).getJSONObject("layout").put("isHidden", true)
        elements.getJSONObject(1).put("kind", "future-control")
        val profile = ControllerProfile.parse(raw)
        assertEquals(8, profile.controls(true).size)
        assertEquals(listOf("future-control"), profile.unsupportedKinds(true))
    }
    @Test fun `orientation preference honors supported locks and handles future values`() {
        val raw = fixture("productivityStarter")
        for (value in listOf("automatic", "portrait", "landscape")) {
            raw.put("orientationPreference", value)
            assertEquals(value, ControllerProfile.parse(raw).orientationPreference)
        }
        raw.put("orientationPreference", "future-unknown")
        assertEquals("automatic", ControllerProfile.parse(raw).orientationPreference)
    }

    @Test fun `starter overrides do not replace a custom element layout or label`() {
        val raw = fixture("productivityStarter")
        val layout = raw.getJSONObject("landscapeCustomization")
        val element = layout.getJSONArray("elements").getJSONObject(0)
        val id = "483D6C66-FD25-452C-98DB-77192E7629AA"
        element.put("id", id).put("label", "Authored").put("layout", JSONObject().put("centerX", .4))
        layout.put("buttonCustomizations", JSONObject().put(id, JSONObject().put("isHidden", true)))
        layout.put("labelOverrides", JSONObject().put(id, "Wrong"))
        val control = ControllerProfile.parse(raw).controls(true).first { it.id.toString().equals(id, true) }
        assertEquals("Authored", control.label); assertEquals(.4, control.style.getDouble("centerX"), 0.0)
    }
    @Test fun `explicit design layer order breaks ties while z index remains primary`() {
        val raw = fixture("productivityStarter")
        val layout = raw.getJSONObject("landscapeCustomization")
        layout.remove("buttonCustomizations")
        val elements = layout.getJSONArray("elements")
        for (index in 0 until elements.length()) elements.getJSONObject(index).getJSONObject("layout").put("zIndex", 0)
        val first = elements.getJSONObject(0).getString("id")
        val second = elements.getJSONObject(1).getString("id")
        layout.put("designMetadata", JSONObject().put("layerOrder", org.json.JSONArray().put(JSONObject().put("kind", "builtin").put("button", second)).put("builtin.$first")))
        var controls = ControllerProfile.parse(raw).controls(true)
        assertEquals(second, controls[0].id.toString().uppercase()); assertEquals(first, controls[1].id.toString().uppercase())
        elements.getJSONObject(0).getJSONObject("layout").put("zIndex", -10)
        controls = ControllerProfile.parse(raw).controls(true)
        assertEquals(first, controls[0].id.toString().uppercase())
    }
    @Test fun `visible legend and accessibility name remain independent and optional`() {
        val raw = fixture("productivityStarter")
        val element = raw.getJSONObject("landscapeCustomization").getJSONArray("elements").getJSONObject(0)
        element.put("presentation", JSONObject().put("accessibilityName", "Move cursor up"))
        var control = ControllerProfile.parse(raw).controls(true).first { it.id.toString().equals(element.getString("id"), true) }
        assertEquals(control.label, control.legend); assertEquals("Move cursor up", control.accessibilityName)
        element.getJSONObject("presentation").put("legend", "↑")
        control = ControllerProfile.parse(raw).controls(true).first { it.id.toString().equals(element.getString("id"), true) }
        assertEquals("↑", control.legend); assertEquals("Move cursor up", control.accessibilityName)
    }

}
