package com.thumble.android

import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

internal data class SkinCompatibilityIssue(val code: String, val message: String)
internal data class SkinCompatibilityResult(val status: String, val issues: List<SkinCompatibilityIssue> = emptyList()) {
    val allowsTemplateArtwork get() = status == "compatible"
    fun json() = JSONObject().put("status",status).put("issues",JSONArray().also { a ->
        issues.forEach { a.put(JSONObject().put("code",it.code).put("message",it.message)) }
    })
}

/** Native compatibility contract over a canonical, validated customization. */
internal object SkinCompatibility {
    private val features = setOf("action_set_layers","artwork_layers","nine_slice_images","bitmap_control_states")
    private val roleNames = mapOf("primary_action" to "primary action", "secondary_action" to "secondary action", "custom" to "custom action")
    private fun strings(a: JSONArray?) = if(a==null) emptyList() else (0 until a.length()).map { a.getString(it) }.distinct()
    private fun objects(a: JSONArray?) = if(a==null) emptyList() else (0 until a.length()).map { a.getJSONObject(it) }
    private fun has(o: JSONObject,k: String) = o.has(k) && !o.isNull(k)

    internal data class Geometry(val id: String,val kind: String,val role: String,val frame: ControlFrame,val rotation: Double)
    internal fun geometry(layout: JSONObject): List<Geometry> {
        val canvas = SkinCanvas.from(layout)
        val profile = ControllerProfile(UUID(0,0),"Compatibility",JSONObject().put("customization",layout))
        val controls = profile.controls(false).map { control ->
            val role = control.source.optString("visualRole").ifEmpty { when(control.kind) {
                "button" -> "custom"; "text","decoration" -> "decoration"; else -> control.kind
            } }
            Geometry("${if(control.isBuiltin) "builtin" else "custom"}.${control.id.toString().uppercase()}",control.kind,role,
                ControlGeometry.resolve(control,canvas.width,canvas.height,layout.optString("layoutMode")=="southpaw"),control.style.finite("rotationDegrees",0.0))
        }.toMutableList()
        val top = layout.optJSONObject("topBarActivationRegion") ?: SkinProfileResolver.defaultTopBar()
        if(!top.optBoolean("isHidden")) {
            val w=60*top.finite("widthScale",1.0);val h=44*top.finite("heightScale",1.0)
            val halfW=min(canvas.width/2,max(w/2,1.0));val halfH=min(canvas.height/2,max(h/2,1.0))
            val x=(top.finite("centerX",.5)*canvas.width).coerceIn(halfW,max(halfW,canvas.width-halfW))
            val y=(top.finite("centerY",.115)*canvas.height).coerceIn(halfH,max(halfH,canvas.height-halfH))
            controls.add(Geometry("system.top_bar_activation","decoration","system",ControlFrame(x,y,w,h),top.finite("rotationDegrees",0.0)))
        }
        return controls
    }

    fun evaluate(raw: JSONObject?,layout: JSONObject,orientation: String): SkinCompatibilityResult {
        if(raw==null) return SkinCompatibilityResult("compatible")
        val issues=mutableListOf<SkinCompatibilityIssue>();var incompatible=false
        fun fail(code: String,message: String) { issues.add(SkinCompatibilityIssue(code,message));incompatible=true }
        val orientations=strings(raw.optJSONArray("orientations"))
        if(orientations.isNotEmpty() && orientation !in orientations)
            fail("unsupported-orientation","The skin does not provide $orientation artwork.")
        val size=SkinCanvas.from(layout);val aspect=max(size.width,1.0)/max(size.height,1.0)
        val minimum=if(has(raw,"minimumAspectRatio")) raw.finite("minimumAspectRatio",.25).coerceIn(.25,4.0) else null
        val maximum=if(has(raw,"maximumAspectRatio")) raw.finite("maximumAspectRatio",minimum ?: .25).coerceIn(minimum ?: .25,4.0) else null
        if(minimum!=null && aspect<minimum) fail("aspect-ratio-too-small","The keypad aspect ratio is below the skin's artwork range.")
        if(maximum!=null && aspect>maximum) fail("aspect-ratio-too-large","The keypad aspect ratio is above the skin's artwork range.")
        val controls=geometry(layout);val roles=controls.map { it.role }.toSet()
        for(role in strings(raw.optJSONArray("requiredRoles"))) if(role !in roles)
            fail("missing-role","The keypad has no ${roleNames[role] ?: role} control required by the artwork.")
        for(feature in strings(raw.optJSONArray("requiredFeatures"))) if(feature !in features)
            fail("missing-rendering-feature","This app does not support $feature.")
        if(raw.optString("mode","universal")=="captured_controller" && !capturedMatches(raw.optJSONObject("capturedGeometry"),layout,orientation,controls)) {
            fail("captured-geometry-mismatch","The controller differs from the captured appearance contract; aligned artwork is hidden.")
            return SkinCompatibilityResult("incompatible",issues)
        }
        if(raw.optString("mode")=="template_aligned") {
            val metadata=layout.optJSONObject("designMetadata")
            if(metadata==null || !has(metadata,"sourceTemplateID") || !has(metadata,"sourceTemplateRevision")) {
                issues.add(SkinCompatibilityIssue("unknown-template","The keypad has no canonical template identity; semantic styling remains available but aligned artwork is hidden."))
                return SkinCompatibilityResult(if(incompatible) "incompatible" else "degraded",issues)
            }
            val templates=objects(raw.optJSONArray("templates")).filter { it.optString("templateID").trim().isNotEmpty() }
            val id=SkinText.canonicalKey(metadata.getString("sourceTemplateID").lowercase());val revision=metadata.getLong("sourceTemplateRevision")
            if(templates.isNotEmpty() && templates.none {
                val low=max(1L,it.optLong("minimumRevision",1L));val high=if(has(it,"maximumRevision")) max(low,it.getLong("maximumRevision")) else Long.MAX_VALUE
                SkinText.canonicalKey(SkinText.prefix(SkinText.trim(it.getString("templateID")).lowercase(),80))==id && revision in low..high
            }) fail("template-mismatch","The skin artwork targets a different canonical keypad template.")
        }
        return SkinCompatibilityResult(if(incompatible) "incompatible" else "compatible",issues)
    }

    private fun capturedMatches(raw: JSONObject?,layout: JSONObject,orientation: String,actual: List<Geometry>): Boolean {
        if(raw==null) return false
        val variants=objects(raw.optJSONArray("variants"))
        if(variants.isEmpty() || variants.size>2 || variants.map { it.optString("orientation") }.toSet().size!=variants.size) return false
        for(variant in variants) {
            if(!variant.finite("canvasWidth",0.0).let { it in 240.0..1800.0 } || !variant.finite("canvasHeight",0.0).let { it in 240.0..1800.0 }) return false
            val insets=variant.optJSONObject("safeAreaInsets") ?: return false
            if(listOf("top","leading","bottom","trailing").any { insets.finite(it,-1.0) !in 0.0..0.45 }) return false
            val controls=objects(variant.optJSONArray("controls"))
            if(controls.size>256 || controls.map { it.optString("id") }.toSet().size!=controls.size) return false
            for(control in controls) {
                val id=control.optString("id");if(id.isEmpty() || id.toByteArray(Charsets.UTF_8).size>128) return false
                val frame=control.optJSONObject("frame") ?: return false
                val x=frame.finite("x",-1.0);val y=frame.finite("y",-1.0);val w=frame.finite("width",0.0);val h=frame.finite("height",0.0)
                if(x<0 || y<0 || w<=0 || h<=0 || x+w>1.000001 || y+h>1.000001) return false
                if(has(control,"rotationDegrees") && control.finite("rotationDegrees",181.0) !in -180.0..180.0) return false
                control.optJSONObject("presentation")?.let { if(!validPresentation(it)) return false }
            }
        }
        val variant=variants.firstOrNull { it.optString("orientation")==orientation } ?: return false
        val size=SkinCanvas.from(layout)
        if(abs(size.width-variant.getDouble("canvasWidth"))>=.001 || abs(size.height-variant.getDouble("canvasHeight"))>=.001) return false
        val expected=objects(variant.optJSONArray("controls"))
        if(actual.map { it.id }.toSet()!=expected.map { it.getString("id") }.toSet()) return false
        for(control in expected) {
            val found=actual.first { it.id==control.getString("id") };val frame=control.getJSONObject("frame")
            if(found.kind!=control.getString("kind") || abs(found.frame.left/size.width-frame.getDouble("x"))>=.000001 ||
                abs(found.frame.top/size.height-frame.getDouble("y"))>=.000001 || abs(found.frame.width/size.width-frame.getDouble("width"))>=.000001 ||
                abs(found.frame.height/size.height-frame.getDouble("height"))>=.000001 ||
                (has(control,"rotationDegrees") && abs(found.rotation-control.getDouble("rotationDegrees"))>=.000001)) return false
        }
        return true
    }

    private fun validPresentation(p: JSONObject): Boolean = try {
        SkinContractCodec.presentation(p)
        true
    } catch(_: SkinPackageException) { false }
}
