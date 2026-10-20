package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class BindingPresentationTest {
    private val profile=UUID.randomUUID()
    private val element=UUID.randomUUID()
    private fun entry(part: String="primary",text: String="⌘A")=BindingPresentation(element,part,text,"Command A")
    @Test fun `orientation override including empty entries wins over common metadata`() {
        val common=ProfileBindingPresentations(profile,null,listOf(entry()))
        val portrait=ProfileBindingPresentations(profile,"portrait",emptyList())
        val groups=listOf(common,portrait)
        assertEquals(common.entries,BindingPresentations.entries(groups,profile,true))
        assertTrue(BindingPresentations.entries(groups,profile,false).isEmpty())
        assertTrue(BindingPresentations.entries(groups,UUID.randomUUID(),true).isEmpty())
        assertEquals(groups,BindingPresentations.decode(BindingPresentations.encode(groups)))
    }
    @Test fun `wire metadata retains missing fields and empty arrays explicitly clear`() {
        val initial=ProfileSnapshot(bindingPresentations=listOf(ProfileBindingPresentations(profile,null,listOf(entry()))))
        assertEquals(initial,initial.applying(JSONObject()))
        assertEquals(emptyList<ProfileBindingPresentations>(),initial.applying(JSONObject().put("bindingPresentations",JSONArray())).bindingPresentations)
        val wire=initial.bindingPresentations.first().json()
        wire.getJSONArray("entries").getJSONObject(0).getJSONObject("input").put("part","joystick_up")
        assertEquals("joystick_up",BindingPresentations.decode(JSONArray().put(wire)).first().entries.first().part)
    }
    @Test fun `visual duplicate comparison uses authored label and text icon with case diacritic whitespace folding`() {
        assertNull(BindingPresentations.visibleHint(" É \u00a0","e",null))
        assertEquals("⌘A",BindingPresentations.visibleHint("  ⌘A  ","Launch",null))
        val icon=ControlIcon.parse(JSONObject().put("source","text").put("value","⌘ A"))
        assertNull(BindingPresentations.visibleHint("⌘A","Launch",icon))
        assertNull(BindingPresentations.visibleHint("\n\t","Launch",null))
    }
    @Test fun `joystick and trigger use canonical element parts without guessing outputs from labels`() {
        fun control(kind: String)=Control(element,"Jump",kind,JSONObject(),"standard")
        val entries=listOf(entry("primary","P"),entry("joystick_right","D"),entry("joystick_up","W"),entry("trigger_digital","T"))
        assertEquals("↑W →D",BindingPresentations.text(control("joystick"),entries))
        assertEquals("Up Command A, Right Command A",BindingPresentations.text(control("joystick"),entries,true))
        assertEquals("T",BindingPresentations.text(control("trigger"),entries))
        assertEquals("P",BindingPresentations.text(control("button"),entries))
        assertNull(BindingPresentations.text(control("text"),entries))
        assertNull(BindingPresentations.text(control("decoration"),entries))
    }
    @Test fun `binding glyph preference defaults on and survives other preference changes`() {
        assertTrue(ClientPreferences.parse(JSONObject()).showBindingGlyphs)
        val preferences=ClientPreferences(showBindingGlyphs=false).copy(hapticIntensity=.5,practiceMode=true)
        assertEquals(preferences,ClientPreferences.parse(preferences.json()))
    }
    @Test(expected=IllegalArgumentException::class) fun `unknown input parts cannot masquerade as primary`() {
        BindingPresentations.decode(JSONArray().put(ProfileBindingPresentations(profile,null,listOf(entry("not-a-part"))).json()))
    }
}
