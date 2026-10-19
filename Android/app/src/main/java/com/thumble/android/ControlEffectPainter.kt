package com.thumble.android

import android.graphics.*
import org.json.JSONObject
import kotlin.math.*

/** Native highlight → bevel → inner shadow → state mark, followed by stacked outer shadows. */
internal class ControlEffectPainter(private val presentation: JSONObject, private val density: Float) {
    private data class Shadow(val color: Int, val radius: Float, val x: Float, val y: Float)
    private fun n(key: String, default: Double = 0.0) = presentation.finite(key, default).toFloat() * density
    private val shadows: List<Shadow>
    val outset: Float
    val hasEffects: Boolean
    init {
        val array = presentation.optJSONArray("shadows")
        shadows = if (array != null && array.length() > 0) (0 until min(array.length(), 8)).map { index ->
            val s = array.getJSONObject(index)
            val color = rgbaColor(s.optJSONObject("color"), Color.TRANSPARENT)
            Shadow((color and 0x00ffffff) or ((Color.alpha(color) * s.finite("opacity", 1.0).coerceIn(0.0, 1.0)).roundToInt() shl 24),
                s.finite("radius", 0.0).coerceIn(0.0, 64.0).toFloat() * density,
                s.finite("x", 0.0).coerceIn(-64.0, 64.0).toFloat() * density, s.finite("y", 0.0).coerceIn(-64.0, 64.0).toFloat() * density)
        }.filter { Color.alpha(it.color) > 0 } else listOf(Shadow(rgbaColor(presentation.optJSONObject("shadowColor"), Color.TRANSPARENT), n("shadowRadius"), n("shadowX"), n("shadowY"))).filter { Color.alpha(it.color) > 0 }
        val shadowOutset = shadows.sumOf { (it.radius * 3 + max(abs(it.x), abs(it.y))).toDouble() }.toFloat()
        val glow = if (presentation.has("glowColor")) n("glowRadius") * 3 else 0f
        outset = max(shadowOutset, glow) + max(n("strokeWidth"), n("bevelWidth")) / 2 + 2
        hasEffects = shadows.isNotEmpty() || glow > 0 || n("innerShadowRadius") > 0 || presentation.finite("highlightOpacity", 0.0) > 0 || n("bevelWidth") > 0 || n("indexWidth") > 0
    }
    fun overlay(canvas: Canvas, path: Path, bounds: RectF) {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val highlightOpacity = presentation.finite("highlightOpacity", 0.0).coerceIn(0.0, 1.0)
        if (highlightOpacity > 0) {
            paint.color = rgbaColor(presentation.optJSONObject("highlightColor"), Color.WHITE)
            paint.alpha = (paint.alpha * highlightOpacity).roundToInt()
            val radius = n("highlightRadius")
            if (radius > 0) paint.maskFilter = BlurMaskFilter(radius, BlurMaskFilter.Blur.NORMAL)
            val saved = canvas.save(); canvas.clipPath(path); canvas.translate(n("highlightX"), n("highlightY")); canvas.drawPath(path, paint); canvas.restoreToCount(saved)
        }
        paint.maskFilter = null; paint.alpha = 255
        val bevel = n("bevelWidth")
        if (bevel > 0) {
            paint.style = Paint.Style.STROKE; paint.strokeWidth = bevel
            paint.shader = LinearGradient(bounds.left,bounds.top,bounds.right,bounds.bottom,
                rgbaColor(presentation.optJSONObject("bevelHighlightColor"),0x9effffff.toInt()), rgbaColor(presentation.optJSONObject("bevelShadowColor"),0x3d000000),Shader.TileMode.CLAMP)
            canvas.drawPath(path, paint); paint.shader = null
        }
        val innerRadius = n("innerShadowRadius")
        if (innerRadius > 0) {
            paint.color = rgbaColor(presentation.optJSONObject("innerShadowColor"),0x38000000)
            paint.style = Paint.Style.STROKE; paint.strokeWidth = max(density, innerRadius * 2)
            paint.maskFilter = BlurMaskFilter(innerRadius,BlurMaskFilter.Blur.NORMAL)
            val saved = canvas.save(); canvas.clipPath(path); canvas.translate(n("innerShadowX"),n("innerShadowY")); canvas.drawPath(path,paint); canvas.restoreToCount(saved)
        }
        paint.maskFilter = null; paint.style = Paint.Style.FILL
        val indexWidth = n("indexWidth")
        if (indexWidth > 0 && presentation.has("indexColor")) {
            paint.color = rgbaColor(presentation.optJSONObject("indexColor"),Color.TRANSPARENT)
            val width = max(8 * density,min(bounds.width() * .34f,18 * density)); val y = bounds.top + max(2 * density,indexWidth)
            canvas.drawRoundRect(bounds.centerX()-width/2,y-indexWidth/2,bounds.centerX()+width/2,y+indexWidth/2,indexWidth/2,indexWidth/2,paint)
        }
    }
    fun raster(bounds: Rect, path: Path, face: (Canvas) -> Unit): EffectRaster {
        val pad = ceil(outset).toInt()
        val logicalWidth = bounds.width() + pad * 2; val logicalHeight = bounds.height() + pad * 2
        val scale = max(1.0,sqrt(logicalWidth.toDouble() * logicalHeight / 1_048_576)).toFloat()
        val width = max(1,ceil(logicalWidth / scale).toInt()); val height = max(1,ceil(logicalHeight / scale).toInt())
        var current = Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888)
        Canvas(current).apply { this.scale(1/scale,1/scale); translate(pad.toFloat()-bounds.left,pad.toFloat()-bounds.top); face(this); overlay(this,path,RectF(bounds)) }
        for (shadow in shadows) {
            val next = Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888); val canvas = Canvas(next)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
            if (shadow.radius > 0) {
                paint.setShadowLayer(shadow.radius/scale,shadow.x/scale,shadow.y/scale,shadow.color)
                canvas.drawBitmap(current,0f,0f,paint)
            } else {
                val alpha = current.extractAlpha(); paint.color = shadow.color
                canvas.drawBitmap(alpha,shadow.x/scale,shadow.y/scale,paint); alpha.recycle(); canvas.drawBitmap(current,0f,0f,null)
            }
            current.recycle(); current = next
        }
        val glow = n("glowRadius")
        if (glow > 0 && presentation.has("glowColor")) {
            val next = Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888); val canvas = Canvas(next)
            canvas.save(); canvas.scale(1/scale,1/scale); canvas.translate(pad.toFloat()-bounds.left,pad.toFloat()-bounds.top)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = rgbaColor(presentation.optJSONObject("glowColor"),Color.TRANSPARENT); alpha = (alpha*.68f).roundToInt(); maskFilter = BlurMaskFilter(glow,BlurMaskFilter.Blur.NORMAL) }
            canvas.drawPath(path,paint); canvas.restore(); canvas.drawBitmap(current,0f,0f,null); current.recycle(); current = next
        }
        return EffectRaster(current,bounds.left-pad.toFloat(),bounds.top-pad.toFloat(),scale)
    }
}
