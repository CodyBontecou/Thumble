package com.thumble.android

import android.graphics.*
import android.graphics.drawable.Drawable
import org.json.JSONObject
import kotlin.math.*

internal fun resolvedFill(style: JSONObject, dark: Boolean, fallback: Int): JSONObject {
    val prefix = if (dark) "dark" else "light"
    return style.optJSONObject("${prefix}FillStyle") ?: style.optJSONObject("fillStyle")
        ?: JSONObject().put("kind", "solid").put("color", style.optJSONObject("${prefix}FillColor")
            ?: style.optJSONObject("fillColor") ?: rgbaJSON(fallback))
}
internal fun rgbaJSON(color: Int) = JSONObject().put("red", Color.red(color) / 255.0)
    .put("green", Color.green(color) / 255.0).put("blue", Color.blue(color) / 255.0).put("alpha", Color.alpha(color) / 255.0)
internal fun rgbaColor(json: JSONObject?, fallback: Int): Int = if (json == null) fallback else Color.argb(
    (json.finite("alpha", 1.0).coerceIn(0.0, 1.0) * 255).roundToInt(),
    (json.finite("red", 0.0).coerceIn(0.0, 1.0) * 255).roundToInt(),
    (json.finite("green", 0.0).coerceIn(0.0, 1.0) * 255).roundToInt(),
    (json.finite("blue", 0.0).coerceIn(0.0, 1.0) * 255).roundToInt())

/** Canonical shape/fill rendering. Reuses its path and shader across touch frames. */
internal class ControlDrawable(private val shape: String, private val style: JSONObject,
    private val fill: JSONObject, private val density: Float, private val assets: AssetImages = AssetImages(),
    private val presentation: JSONObject = JSONObject()) : Drawable() {
    private val path = Path()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.style = Paint.Style.STROKE }
    private var pressed = false
    private var opacity = 255
    private var baseAlpha = 255
    private var externalFilter: ColorFilter? = null
    private var image: ImageFillPainter? = null
    private val pressFilter = ColorMatrixColorFilter(ColorMatrix(floatArrayOf(
        .74f, 0f, 0f, 0f, 0f, 0f, .74f, 0f, 0f, 0f, 0f, 0f, .74f, 0f, 0f, 0f, 0f, 0f, 1f, 0f)))
    fun setPressed(value: Boolean) { if (pressed != value) { pressed = value; invalidateSelf() } }
    override fun onBoundsChange(bounds: Rect) {
        path.reset()
        val rect = RectF(bounds)
        image = if (fill.optString("kind") == "image") ImageFillPainter(fill.optJSONObject("image") ?: JSONObject(), assets, rect, density) else null
        if (shape == "polygon" || shape == "star") {
            val count = if (shape == "star") 10 else 3
            for (i in 0 until count) {
                val angle = -Math.PI / 2 + i * 2 * Math.PI / count
                val scale = if (shape == "star" && i % 2 != 0) .45 else 1.0
                val x = rect.centerX() + cos(angle).toFloat() * rect.width() / 2 * scale.toFloat()
                val y = rect.centerY() + sin(angle).toFloat() * rect.height() / 2 * scale.toFloat()
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            path.close()
        } else {
            val defaultRadius = when (shape) { "rectangle" -> 0f; "circle", "ellipse", "capsule" -> min(rect.width(), rect.height()) / 2; else -> 6 * density }
            val corners = style.optJSONObject("cornerRadii")
            val uniform = style.finite("cornerRadius", defaultRadius / density.toDouble()).coerceAtLeast(0.0) * density
            val radii = listOf("topLeading", "topTrailing", "bottomTrailing", "bottomLeading").flatMap { key ->
                val radius = (corners?.finite(key, uniform / density) ?: (uniform / density)).coerceAtLeast(0.0).toFloat() * density
                // SwiftUI clips each corner against half the shortest dimension.
                val r = min(radius, min(rect.width(), rect.height()) / 2)
                listOf(r, r)
            }.toFloatArray()
            path.addRoundRect(rect, radii, Path.Direction.CW)
        }
        paint.shader = null
        paint.color = rgbaColor(fill.optJSONObject("color"), Color.rgb(18, 18, 18))
        baseAlpha = Color.alpha(paint.color)
        val gradient = fill.optJSONObject("gradient")
        if (fill.optString("kind") == "gradient" && gradient != null) {
            val raw = gradient.optJSONArray("stops")
            val stops = (0 until min(raw?.length() ?: 0, 2048)).map { raw!!.getJSONObject(it) }
                .sortedBy { it.finite("offset", 0.0).coerceIn(0.0, 1.0) }
            if (stops.isNotEmpty()) {
                val normalized = if (stops.size == 1) listOf(stops[0], stops[0]) else stops
                val colors = normalized.map { rgbaColor(it.optJSONObject("color"), Color.rgb(18, 18, 18)) }.toIntArray()
                val offsets = if (stops.size == 1) floatArrayOf(0f, 1f) else normalized.map { it.finite("offset", 0.0).coerceIn(0.0, 1.0).toFloat() }.toFloatArray()
                paint.shader = if (gradient.optString("type") == "radial") RadialGradient(rect.centerX(), rect.centerY(), max(1f, max(rect.width(), rect.height())), colors, offsets, Shader.TileMode.CLAMP)
                else {
                    val angle = Math.toRadians(gradient.finite("angleDegrees", 0.0) % 360)
                    val dx = cos(angle).toFloat() * rect.width() / 2; val dy = sin(angle).toFloat() * rect.height() / 2
                    LinearGradient(rect.centerX() - dx, rect.centerY() - dy, rect.centerX() + dx, rect.centerY() + dy, colors, offsets, Shader.TileMode.CLAMP)
                }
            }
        }
        if (fill.optString("kind") == "tile") fill.optJSONObject("tile")?.let { tile ->
            val scale = tile.finite("scale", 1.0).coerceIn(.25, 4.0)
            val sx = tile.finite("spacingX", 0.0).coerceIn(0.0, 2.0)
            val sy = tile.finite("spacingY", 0.0).coerceIn(0.0, 2.0)
            val pattern = tile.optString("pattern", "dots")
            val spacingX = max(5.0, 13 * scale + sx * 18) * density
            val spacingY = max(5.0, 13 * scale + sy * 18) * density
            val square = max(6.0, 12 * scale) * density
            val diagonal = max(7.0, 14 * scale + max(sx, sy) * 18) * density
            val periodX = when (pattern) { "checker" -> square * 2; "diagonal" -> diagonal; else -> spacingX }
            val periodY = when (pattern) { "checker" -> square * 2; "diagonal" -> diagonal; else -> spacingY }
            // A bounded repeating texture avoids work proportional to the full canvas area.
            val bitmap = Bitmap.createBitmap(max(1, periodX.roundToInt()), max(1, periodY.roundToInt()), Bitmap.Config.ARGB_8888)
            val c = Canvas(bitmap); val p = Paint(Paint.ANTI_ALIAS_FLAG)
            c.drawColor(rgbaColor(tile.optJSONObject("backgroundColor"), Color.rgb(18, 18, 18)))
            val foreground = rgbaColor(tile.optJSONObject("foregroundColor"), Color.WHITE)
            p.color = foreground
            p.alpha = (Color.alpha(foreground) * tile.finite("opacity", 1.0).coerceIn(0.0, 1.0)).roundToInt()
            val bw = bitmap.width.toFloat(); val bh = bitmap.height.toFloat()
            when (pattern) {
                "checker" -> { c.drawRect(0f, 0f, bw / 2, bh / 2, p); c.drawRect(bw / 2, bh / 2, bw, bh, p) }
                "grid" -> {
                    p.strokeWidth = max(1.0, scale).toFloat() * density
                    for (x in listOf(0f, bw)) c.drawLine(x, 0f, x, bh, p)
                    for (y in listOf(0f, bh)) c.drawLine(0f, y, bw, y, p)
                }
                "diagonal" -> {
                    p.strokeWidth = max(1.5, 2 * scale).toFloat() * density
                    for (offset in listOf(-bw, 0f, bw)) c.drawLine(offset, bh, offset + bw, 0f, p)
                }
                else -> for (x in listOf(0f, bw)) for (y in listOf(0f, bh)) c.drawCircle(x, y, max(1.2, 2.1 * scale).toFloat() * density, p)
            }
            val matrix = Matrix().apply { setScale((periodX / bw).toFloat(), (periodY / bh).toFloat()) }
            if (pattern == "dots" || pattern == "grid") {
                val alignment = tile.optString("alignment", "topLeading")
                fun offset(horizontal: Boolean): Float {
                    val leading = if (horizontal) setOf("topLeading", "leading", "bottomLeading") else setOf("topLeading", "top", "topTrailing")
                    val trailing = if (horizontal) setOf("topTrailing", "trailing", "bottomTrailing") else setOf("bottomLeading", "bottom", "bottomTrailing")
                    val remainder = if (horizontal) rect.width() % spacingX else rect.height() % spacingY
                    return when (alignment) { in leading -> 0f; in trailing -> remainder.toFloat(); else -> (remainder / 2).toFloat() }
                }
                matrix.postTranslate(offset(true), offset(false))
            }
            paint.shader = BitmapShader(bitmap, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT).apply { setLocalMatrix(matrix) }
        }
    }
    override fun draw(canvas: Canvas) {
        val imagePainter = image
        if (imagePainter != null) {
            val saved = canvas.save(); canvas.clipPath(path); imagePainter.draw(canvas, opacity); canvas.restoreToCount(saved)
        } else {
            paint.alpha = if (paint.shader == null) baseAlpha * opacity / 255 else opacity
            paint.colorFilter = externalFilter ?: if (pressed) pressFilter else null
            canvas.drawPath(path, paint)
        }
        val strokeWidth = presentation.finite("strokeWidth", 0.0).coerceIn(0.0, 12.0).toFloat() * density
        if (strokeWidth > 0) {
            strokePaint.strokeWidth = strokeWidth
            strokePaint.color = rgbaColor(presentation.optJSONObject("strokeColor"), Color.TRANSPARENT)
            strokePaint.alpha = Color.alpha(strokePaint.color) * opacity / 255
            canvas.drawPath(path, strokePaint)
        }
    }
    override fun setAlpha(alpha: Int) { opacity = alpha; invalidateSelf() }
    override fun setColorFilter(colorFilter: ColorFilter?) { externalFilter = colorFilter; invalidateSelf() }
    @Deprecated("Drawable opacity is not used by current Android rendering")
    override fun getOpacity() = PixelFormat.TRANSLUCENT
}
