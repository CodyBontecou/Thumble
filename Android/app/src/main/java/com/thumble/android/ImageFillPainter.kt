package com.thumble.android

import android.graphics.*
import org.json.JSONObject
import kotlin.math.*

/** Prepares raster transforms once per visual frame; draw only submits cached patches. */
internal class ImageFillPainter(private val image: JSONObject, assets: AssetImages,
    private val bounds: RectF, private val density: Float) {
    private val raster = assets.image(image, bounds.width().roundToInt(), bounds.height().roundToInt())
    private data class Patch(val bitmap: Bitmap, val destination: RectF, val matrix: Matrix?, val shader: Shader?)
    private val patches = mutableListOf<Patch>()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private val filter = adjustmentFilter(image)
    init {
        raster?.let { asset ->
            val source = RectF(0f, 0f, asset.bitmap.width.toFloat(), asset.bitmap.height.toFloat())
            val contentMode = image.optString("contentMode", "fill")
            val mode = image.optString("resizingMode").ifEmpty { if (contentMode == "tile") "tile" else "scale" }
            val insets = image.optJSONObject("nineSliceInsets")
            fun inset(key: String) = insets?.finite(key, 0.0)?.coerceIn(0.0, .49)?.toFloat() ?: 0f
            val l = inset("leading"); val r = inset("trailing"); val t = inset("top"); val b = inset("bottom")
            val nine = mode in setOf("nine_slice_stretch", "nine_slice_tile") && insets != null && l + r < .98f && t + b < .98f
            if (nine) {
                val capScaleX = min(1f, bounds.width() / max(.001f, asset.intrinsicWidth * density * (l + r)))
                val capScaleY = min(1f, bounds.height() / max(.001f, asset.intrinsicHeight * density * (t + b)))
                val sx = floatArrayOf(0f, source.width() * l, source.width() * (1 - r), source.width())
                val sy = floatArrayOf(0f, source.height() * t, source.height() * (1 - b), source.height())
                val dx = floatArrayOf(bounds.left, bounds.left + asset.intrinsicWidth * l * density * capScaleX,
                    bounds.right - asset.intrinsicWidth * r * density * capScaleX, bounds.right)
                val dy = floatArrayOf(bounds.top, bounds.top + asset.intrinsicHeight * t * density * capScaleY,
                    bounds.bottom - asset.intrinsicHeight * b * density * capScaleY, bounds.bottom)
                for (row in 0..2) for (column in 0..2) {
                    val src = RectF(sx[column], sy[row], sx[column + 1], sy[row + 1])
                    val dst = RectF(dx[column], dy[row], dx[column + 1], dy[row + 1])
                    if (src.width() > 0 && src.height() > 0 && dst.width() > 0 && dst.height() > 0) {
                        add(asset, src, dst, mode == "nine_slice_tile" && (column == 1 || row == 1))
                    }
                }
            } else if (mode == "tile" || contentMode == "tile") add(asset, source, bounds, true)
            else {
                val factor = if (contentMode == "fit") min(bounds.width() / source.width(), bounds.height() / source.height())
                    else max(bounds.width() / source.width(), bounds.height() / source.height())
                val w = source.width() * factor; val h = source.height() * factor
                add(asset, source, RectF(bounds.centerX() - w / 2, bounds.centerY() - h / 2, bounds.centerX() + w / 2, bounds.centerY() + h / 2), false)
            }
        }
    }
    private fun add(asset: RasterAsset, src: RectF, dst: RectF, tile: Boolean) {
        val x = src.left.roundToInt().coerceIn(0, asset.bitmap.width - 1)
        val y = src.top.roundToInt().coerceIn(0, asset.bitmap.height - 1)
        val w = max(1, src.right.roundToInt() - x).coerceAtMost(asset.bitmap.width - x)
        val h = max(1, src.bottom.roundToInt() - y).coerceAtMost(asset.bitmap.height - y)
        // Isolate each patch so bilinear filtering cannot bleed a neighboring
        // cap's pixels across a stretched center or edge.
        val cropped = if (x == 0 && y == 0 && w == asset.bitmap.width && h == asset.bitmap.height) asset.bitmap else Bitmap.createBitmap(asset.bitmap, x, y, w, h)
        if (!tile) patches.add(Patch(cropped, dst, Matrix().apply { setRectToRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), dst, Matrix.ScaleToFit.FILL) }, null))
        else {
            val matrix = Matrix().apply {
                setScale(asset.intrinsicWidth * density / asset.bitmap.width, asset.intrinsicHeight * density / asset.bitmap.height)
                postTranslate(dst.left, dst.top)
            }
            patches.add(Patch(cropped, dst, null, BitmapShader(cropped, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT).apply { setLocalMatrix(matrix) }))
        }
    }
    fun draw(canvas: Canvas, opacity: Int) {
        if (raster == null) {
            paint.shader = null; paint.colorFilter = null; paint.color = 0xB8000000.toInt(); paint.alpha = 184 * opacity / 255
            canvas.drawRect(bounds, paint)
            paint.color = Color.WHITE; paint.alpha = 189 * opacity / 255; paint.textAlign = Paint.Align.CENTER; paint.textSize = 12 * density
            canvas.drawText("No image", bounds.centerX(), bounds.centerY() - (paint.ascent() + paint.descent()) / 2, paint)
            return
        }
        paint.color = Color.WHITE
        paint.alpha = (opacity * image.finite("opacity", 1.0).coerceIn(0.0, 1.0)).roundToInt()
        paint.colorFilter = filter
        for (patch in patches) {
            val saved = canvas.save()
            canvas.clipRect(patch.destination)
            paint.shader = patch.shader
            if (patch.shader != null) canvas.drawRect(patch.destination, paint)
            else canvas.drawBitmap(patch.bitmap, patch.matrix!!, paint)
            canvas.restoreToCount(saved)
        }
    }
    companion object {
        private fun adjustmentFilter(image: JSONObject): ColorMatrixColorFilter {
            fun value(key: String) = image.finite(key, 0.0).coerceIn(-1.0, 1.0).toFloat()
            val brightness = (value("exposure") * .22f + value("shadows") * .08f - value("highlights") * .04f) * 255
            val contrast = 1 + value("contrast") * .55f
            val shift = 127.5f * (1 - contrast)
            val result = ColorMatrix(floatArrayOf(1f,0f,0f,0f,brightness, 0f,1f,0f,0f,brightness, 0f,0f,1f,0f,brightness, 0f,0f,0f,1f,0f))
            result.postConcat(ColorMatrix(floatArrayOf(contrast,0f,0f,0f,shift, 0f,contrast,0f,0f,shift, 0f,0f,contrast,0f,shift, 0f,0f,0f,1f,0f)))
            result.postConcat(ColorMatrix().apply { setSaturation(max(0f, 1 + value("saturation") * .8f)) })
            val angle = Math.toRadians(((value("tint") + value("temperature")) * 10).toDouble())
            val c = cos(angle).toFloat(); val s = sin(angle).toFloat()
            result.postConcat(ColorMatrix(floatArrayOf(
                .213f+c*.787f-s*.213f, .715f-c*.715f-s*.715f, .072f-c*.072f+s*.928f,0f,0f,
                .213f-c*.213f+s*.143f, .715f+c*.285f+s*.140f, .072f-c*.072f-s*.283f,0f,0f,
                .213f-c*.213f-s*.787f, .715f-c*.715f+s*.715f, .072f+c*.928f+s*.072f,0f,0f,
                0f,0f,0f,1f,0f)))
            return ColorMatrixColorFilter(result)
        }
    }
}
