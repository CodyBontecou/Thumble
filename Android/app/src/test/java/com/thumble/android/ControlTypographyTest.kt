package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class ControlTypographyTest {
    private fun plan(kind: String="button",label: String="Long legend",w: Double=100.0,h: Double=100.0,content: JSONObject?=null)=
        ControlTypography.resolve(Control(UUID.randomUUID(),label,kind,JSONObject(),"standard"),w,h,content)
    @Test fun `native fallback metrics distinguish text pointing and trigger controls`() {
        assertEquals(36.0,plan("text",h=50.0).size!!,0.0);assertEquals(.12,plan("text").minimumScale,0.0)
        assertEquals(12.0,plan("joystick",w=88.0).size!!,0.0);assertEquals(14.0,plan("joystick",w=88.1).size!!,0.0)
        assertEquals(12.0,plan("trackpad",w=96.0).size!!,0.0);assertEquals(14.0,plan("trackpad",w=96.1).size!!,0.0)
        assertEquals(12.0,plan("trigger",h=44.0).size!!,0.0);assertEquals(14.0,plan("trigger",h=44.1).size!!,0.0)
        assertEquals(.5,plan("trigger").minimumScale,0.0)
        assertNull(plan().size);assertEquals(listOf(16.0,14.0,14.0),plan().candidates)
    }
    @Test fun `authored typography preserves explicit size and native minimum scales`() {
        val inherited=plan(label="AB",content=JSONObject().put("tracking",2))
        assertEquals(32.0,inherited.size!!,0.0);assertEquals(.48,inherited.minimumScale,0.0)
        assertEquals(-1.28,plan(label="AB").tracking,0.0)
        assertEquals(0.0,plan(label="AB",content=JSONObject().put("alignment","center")).tracking,0.0)
        val fixed=plan(content=JSONObject().put("fontSize",21).put("lineLimit",3).put("fontWeight","bold").put("fontDesign","serif"))
        assertEquals(21.0,fixed.size!!,0.0);assertEquals(1.0,fixed.minimumScale,0.0);assertEquals(3,fixed.lineLimit)
        assertEquals(700,fixed.weight);assertEquals("serif",fixed.design)
        assertNull("an icon alone retains native fit",plan(content=JSONObject().put("icon",JSONObject().put("value","star"))).size)
    }
    @Test fun `native short legends use extended graphemes rather than Unicode scalars`() {
        for(text in listOf("AB","e\u0301e\u0301","👨‍👩‍👧‍👦🇵🇷")) {
            assertTrue(ControlTypography.shortLegend(text));assertEquals(32.0,plan(label=text).size!!,0.0)
        }
        assertFalse(ControlTypography.shortLegend("e\u0301AB"));assertNull(plan(label="e\u0301AB").size)
    }
}
