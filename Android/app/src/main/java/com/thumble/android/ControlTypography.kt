package com.thumble.android

import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

/** GamepadNativeContentPresentation font metrics, before platform font selection. */
internal data class ControlTypography(val size: Double?,val candidates: List<Double>,val minimumScale: Double,
    val lineLimit: Int,val tracking: Double,val weight: Int,val design: String,val padding: Double,val alignment: String) {
    companion object {
        private val authoredFields=setOf("legend","fontSize","fontWeight","fontDesign","tracking","lineLimit","alignment","labelPadding","labelPlacement")
        fun shortLegend(value: String)=SkinText.prefix(value,2)==value
        fun resolve(control: Control,width: Double,height: Double,content: JSONObject?): ControlTypography {
            val legend=content?.let { if(it.has("legend") && !it.isNull("legend")) it.optString("legend") else null } ?: control.legend
            val authored=content!=null && authoredFields.any { content.has(it) && !content.isNull(it) }
            val text=control.kind=="text";val pointing=control.kind in setOf("joystick","trackpad");val trigger=control.kind=="trigger"
            val fit=!authored && !text && !pointing && !trigger && !shortLegend(legend)
            val fallback=when(control.kind) {
                "text" -> max(10.0,height*.72)
                "joystick" -> if(min(width,height)<=88) 12.0 else 14.0
                "trackpad" -> if(width<=96) 12.0 else 14.0
                "trigger" -> if(height<=44) 12.0 else 14.0
                else -> if(shortLegend(legend)) 32.0 else 14.0
            }
            val explicit=content?.optDouble("fontSize")?.takeIf { it.isFinite() }?.coerceIn(8.0,72.0)
            val size=if(fit) null else explicit ?: fallback
            val minimum=when {
                authored -> if(explicit==null) .48 else 1.0
                text -> .12
                trigger -> .5
                fit -> 1.0
                pointing -> .48
                else -> .55
            }
            val weight=when(content?.optString("fontWeight")) {
                "regular" -> 400;"medium" -> 500;"semibold" -> 600;"bold" -> 700
                else -> if(authored || text || !pointing && !trigger && !fit) 600 else 500
            }
            val design=content?.optString("fontDesign")?.takeIf { it in setOf("system","rounded","serif","monospaced") }
                ?: if(authored || text) "rounded" else "system"
            return ControlTypography(size,if(fit) listOf(16.0,14.0,14.0) else listOf(size!!),minimum,
                if(authored) (content?.optInt("lineLimit",1) ?: 1).coerceIn(1,4) else 1,
                (if(authored) content?.finite("tracking",0.0)?.coerceIn(-4.0,12.0) ?: 0.0
                 else if(!text && !pointing && !trigger && !fit) -1.28 else 0.0),weight,design,
                content?.finite("labelPadding",defaultLabelPadding(control))?.coerceIn(0.0,32.0) ?: defaultLabelPadding(control),
                content?.optString("alignment")?.takeIf { it in setOf("leading","center","trailing") } ?: "center")
        }
    }
}
