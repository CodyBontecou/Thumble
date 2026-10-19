package com.thumble.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class EffectPresentationTest {
    private fun resolve(state: JSONObject): JSONObject {
        val style = JSONObject().put("visualStyle",JSONObject().put("normal",state))
        return ControlPresentation.resolve(Control(UUID.randomUUID(),"Effects","button",style,"standard"),JSONObject(),PresentationState.NORMAL,false)
    }
    @Test fun `native color-only effects acquire their documented defaults`() {
        val color = JSONObject().put("red",1).put("green",1).put("blue",1)
        val p = resolve(JSONObject().put("innerShadowColor",color).put("highlightColor",color).put("bevelHighlightColor",color))
        assertEquals(4.0,p.getDouble("innerShadowRadius"),0.0)
        assertEquals(8.0,p.getDouble("highlightRadius"),0.0); assertEquals(.42,p.getDouble("highlightOpacity"),0.0)
        assertEquals(1.0,p.getDouble("bevelWidth"),0.0)
    }
    @Test fun `explicit zero overrides color defaults and effects normalize native scalar budgets`() {
        val color = JSONObject().put("red",1).put("green",1).put("blue",1)
        val p = resolve(JSONObject().put("highlightColor",color).put("highlightOpacity",0).put("highlightRadius",0)
            .put("bevelHighlightColor",color).put("bevelWidth",0).put("innerShadowRadius",1000).put("innerShadowX",-1000).put("indexWidth",1000))
        assertEquals(0.0,p.getDouble("highlightOpacity"),0.0); assertEquals(0.0,p.getDouble("highlightRadius"),0.0); assertEquals(0.0,p.getDouble("bevelWidth"),0.0)
        assertEquals(64.0,p.getDouble("innerShadowRadius"),0.0); assertEquals(-64.0,p.getDouble("innerShadowX"),0.0); assertEquals(12.0,p.getDouble("indexWidth"),0.0)
    }
}
