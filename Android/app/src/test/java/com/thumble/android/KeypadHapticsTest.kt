package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class KeypadHapticsTest {
    @Test fun `haptic preference migrates older records and normalizes independently of practice mode`() {
        assertEquals(ClientPreferences(practiceMode=true),ClientPreferences.parse(JSONObject().put("practiceMode",true)))
        val current=ClientPreferences(practiceMode=true,hapticIntensity=.25)
        assertEquals(current,ClientPreferences.parse(current.json()))
        assertEquals(.25,current.copy(practiceMode=false).hapticIntensity,0.0)
        for (value in listOf(Double.NaN,Double.POSITIVE_INFINITY,Double.NEGATIVE_INFINITY)) {
            assertEquals(1.0,ClientPreferences(hapticIntensity=value).normalized().hapticIntensity,0.0)
        }
        assertEquals(0.0,ClientPreferences.parse(JSONObject().put("hapticIntensity",-1)).hapticIntensity,0.0)
        assertEquals(1.0,ClientPreferences.parse(JSONObject().put("hapticIntensity",3)).hapticIntensity,0.0)
    }
    @Test fun `settings offer the five native intensity levels and accessible labels`() {
        assertEquals(listOf(0.0,.25,.5,.75,1.0),HapticIntensity.levels)
        assertEquals(listOf("Off","25%","50%","75%","100%"),HapticIntensity.levels.map(HapticIntensity::label))
    }
    @Test fun `all six styles retain the shared defaults and none suppresses feedback`() {
        val expected=mapOf("none" to (0.0 to 0.0),"light" to (.45 to .48),"medium" to (.62 to .56),
            "heavy" to (.82 to .66),"soft" to (.38 to .24),"rigid" to (.70 to .92))
        for ((style,values) in expected) {
            val h=KeypadHaptic.parse(legacyStyle=style)
            assertEquals(values.first,h.intensity,0.0);assertEquals(values.second,h.sharpness,0.0)
            assertEquals(.06,h.duration,0.0)
            assertEquals(style != "none",h.waveform() != null)
        }
    }
    @Test fun `normalization retains native bounds and global intensity can turn every pattern off`() {
        val h=KeypadHaptic.parse(JSONObject("""{"style":"heavy","intensity":9,"sharpness":-2,"duration":8,"pattern":"buzz"}"""))
        assertEquals(1.0,h.intensity,0.0);assertEquals(0.0,h.sharpness,0.0);assertEquals(.30,h.duration,0.0)
        assertNull(h.waveform(0.0));assertNull(h.waveform(-2.0))
        assertEquals(h.waveform()!!.amplitudes.max(),h.waveform(Double.NaN)!!.amplitudes.max())
        assertTrue(h.waveform(.25)!!.amplitudes.max() < h.waveform()!!.amplitudes.max())
        val none=KeypadHaptic.parse(JSONObject("""{"style":"none","pattern":"buzz","intensity":1,"sharpness":1}"""))
        assertEquals("single",none.pattern);assertEquals(0.0,none.sharpness,0.0);assertNull(none.waveform())
        assertNull(KeypadHaptic(intensity=Double.NaN).waveform())
    }
    private fun samples(wave: HapticWaveform) = wave.timings.indices.flatMap { index -> List(wave.timings[index].toInt()) { wave.amplitudes[index] } }
    @Test fun `double spacing pulse duration and buzz accents survive bounded waveform mapping`() {
        for (seconds in listOf(.02,.1,.3)) {
            val double=samples(KeypadHaptic(pattern="double",duration=seconds).waveform()!!)
            val starts=double.indices.filter { double[it]>0 && (it==0 || double[it-1]==0) }
            assertEquals(listOf(0,(seconds*1000).toInt().coerceIn(45,180)),starts)
            val pulse=samples(KeypadHaptic(pattern="pulse",duration=seconds).waveform()!!)
            assertEquals(maxOf(35,(seconds*1000).toInt()),pulse.size)
            assertEquals(1,pulse.toSet().size)
            val buzz=samples(KeypadHaptic(pattern="buzz",duration=seconds).waveform()!!)
            assertTrue(buzz.size in 80..340)
            assertTrue("buzz retains accents over its continuous body",buzz.max()>pulse.max())
        }
        for (pattern in listOf("single","double","pulse","buzz")) {
            val wave=KeypadHaptic(pattern=pattern,duration=Double.POSITIVE_INFINITY,sharpness=Double.NaN).waveform()!!
            assertTrue(wave.timings.all { it>0 });assertTrue(wave.timings.sum()<=340)
            assertTrue(wave.amplitudes.all { it in 0..255 })
        }
    }
    @Test fun `sharpness changes transient envelope without changing pattern ownership`() {
        val soft=KeypadHaptic(sharpness=0.0).waveform()!!
        val rigid=KeypadHaptic(sharpness=1.0).waveform()!!
        assertTrue(soft.timings.sum()>rigid.timings.sum())
        assertEquals(soft.amplitudes.max(),rigid.amplitudes.max())
    }
    private fun resolve(layout: JSONObject, library: JSONObject = JSONObject()): KeypadHaptic {
        val control=Control(UUID.randomUUID(),"button","button",layout,"standard")
        return KeypadHaptic.parse(ControlPresentation.resolve(control,library,PresentationState.PRESSED,false).getJSONObject("hapticFeedback"))
    }
    @Test fun `native haptic cascade follows token inline then explicit layout feedback`() {
        val token=JSONObject().put("id","test").put("name","Test").put("appliesTo",JSONArray().put("button"))
            .put("visualStyle",JSONObject().put("hapticStyle","heavy"))
        val library=JSONObject().put("styleLibrary",JSONObject().put("styles",JSONArray().put(token)))
        val layout=JSONObject().put("styleID","test")
        assertEquals("heavy",resolve(layout,library).style)
        layout.put("visualStyle",JSONObject().put("hapticFeedback",JSONObject().put("style","soft").put("pattern","double")))
        assertEquals("soft",resolve(layout,library).style);assertEquals("double",resolve(layout,library).pattern)
        layout.put("hapticStyle","none")
        assertEquals("none",resolve(layout,library).style)
        layout.put("hapticFeedback",JSONObject().put("style","rigid").put("intensity",.3))
        assertEquals("rigid",resolve(layout,library).style);assertEquals(.3,resolve(layout,library).intensity,0.0)
        token.put("appliesTo",JSONArray().put("joystick"))
        assertEquals("light",resolve(JSONObject().put("styleID","test"),library).style)
    }
}
