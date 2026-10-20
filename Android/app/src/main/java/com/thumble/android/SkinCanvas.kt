package com.thumble.android

import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

internal data class SkinCanvas(val width: Double, val height: Double) {
    companion object {
        // Canonical frame IDs from GamepadEditorDeviceCatalog. Raw alias/model
        // normalization belongs to the profile decoder, before skin resolution.
        private val portraitSizes = mapOf(
            "iphone-17-pro" to (402.0 to 874.0),
            "iphone-17-pro-max" to (440.0 to 956.0),
            "iphone-17e" to (390.0 to 844.0),
            "iphone-air" to (420.0 to 912.0),
            "iphone-17" to (402.0 to 874.0),
            "iphone-16-pro" to (402.0 to 874.0),
            "iphone-16-pro-max" to (440.0 to 956.0),
            "iphone-16e" to (390.0 to 844.0),
            "iphone-16" to (393.0 to 852.0),
            "iphone-16-plus" to (430.0 to 932.0),
            "iphone-15-pro" to (393.0 to 852.0),
            "iphone-15-pro-max" to (430.0 to 932.0),
            "iphone-15" to (393.0 to 852.0),
            "iphone-15-plus" to (430.0 to 932.0),
            "iphone-14-pro" to (393.0 to 852.0),
            "iphone-14-pro-max" to (430.0 to 932.0),
            "iphone-14" to (390.0 to 844.0),
            "iphone-14-plus" to (428.0 to 926.0),
            "iphone-se-3" to (375.0 to 667.0),
            "iphone-13-pro" to (390.0 to 844.0),
            "iphone-13-pro-max" to (428.0 to 926.0),
            "iphone-13" to (390.0 to 844.0),
            "iphone-13-mini" to (375.0 to 812.0),
            "iphone-12-pro" to (390.0 to 844.0),
            "iphone-12-pro-max" to (428.0 to 926.0),
            "iphone-12" to (390.0 to 844.0),
            "iphone-12-mini" to (375.0 to 812.0),
            "iphone-se-2" to (375.0 to 667.0),
            "iphone-11-pro" to (375.0 to 812.0),
            "iphone-11-pro-max" to (414.0 to 896.0),
            "iphone-11" to (414.0 to 896.0),
            "iphone-xr" to (414.0 to 896.0),
            "iphone-xs" to (375.0 to 812.0),
            "iphone-xs-max" to (414.0 to 896.0)
        )
        fun from(layout: JSONObject): SkinCanvas {
            val id = layout.optJSONObject("deviceCanvas")?.optString("frameID").orEmpty()
            val orientation = id.substringAfterLast('-')
            val spec = id.substringBeforeLast('-')
            val custom = Regex("custom-([0-9]+(?:\\.[0-9]+)?)x([0-9]+(?:\\.[0-9]+)?)").matchEntire(spec)
            val size = portraitSizes[spec] ?: custom?.let {
                val w = it.groupValues[1].toDouble().coerceIn(240.0,1800.0)
                val h = it.groupValues[2].toDouble().coerceIn(240.0,1800.0)
                min(w,h) to max(w,h)
            }
            if (size == null || orientation !in listOf("portrait","landscape")) return SkinCanvas(874.0,402.0)
            return if (orientation == "portrait") SkinCanvas(size.first,size.second) else SkinCanvas(size.second,size.first)
        }
        fun orientedFrameID(layout: JSONObject, landscape: Boolean): String {
            val raw = layout.optJSONObject("deviceCanvas")?.optString("frameID").orEmpty()
            val spec = raw.substringBeforeLast('-')
            val known = portraitSizes.containsKey(spec) || Regex("custom-([0-9]+(?:\\.[0-9]+)?)x([0-9]+(?:\\.[0-9]+)?)").matches(spec)
            return (if (known) spec else "iphone-17-pro") + if (landscape) "-landscape" else "-portrait"
        }
    }
}
