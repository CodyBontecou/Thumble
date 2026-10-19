package com.thumble.android

import android.graphics.*
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToInt

/** Passive paint planes; no artwork object is a View, input target, or AX node. */
internal class ArtworkPainter(array: JSONArray?, private val assets: AssetImages, private val density: Float,
    private val legacyBlending: Boolean = Build.VERSION.SDK_INT < 29) {
    private val layers = artworkLayers(array)
    val requiresSoftwareBuffer = legacyBlending && layers.any { it.blend in setOf("soft_light", "multiply") && it.opacity > 0 }
    private data class Prepared(val layer: ArtworkLayer, val drawable: ControlDrawable, val rect: RectF)
    private var prepared = emptyList<Prepared>()
    private var width = 0
    private var height = 0
    private var sourceBitmap: Bitmap? = null
    private var sourcePixels = IntArray(0)
    private var destinationPixels = IntArray(0)
    private val paint = Paint()
    fun resize(w: Int, h: Int) {
        if (width == w && height == h) return
        width = w; height = h
        sourceBitmap?.recycle(); sourceBitmap = null
        sourcePixels = IntArray(0); destinationPixels = IntArray(0)
        prepared = if (w <= 0 || h <= 0) emptyList() else layers.filter { it.opacity > 0 && it.width > 0 && it.height > 0 }.map { layer ->
            val rect = RectF((layer.x * w).toFloat(), (layer.y * h).toFloat(), ((layer.x + layer.width) * w).toFloat(), ((layer.y + layer.height) * h).toFloat())
            val drawable = ControlDrawable("rectangle", JSONObject(), layer.fill, density, assets)
            drawable.setBounds(0, 0, rect.width().roundToInt().coerceAtLeast(1), rect.height().roundToInt().coerceAtLeast(1))
            Prepared(layer, drawable, rect)
        }
    }
    fun draw(canvas: Canvas, plane: String, backing: Bitmap? = null) {
        for (entry in prepared) {
            if (entry.layer.plane != plane) continue
            if (entry.layer.blend in setOf("soft_light", "multiply") && legacyBlending) {
                val target = requireNotNull(backing) { "Legacy artwork blending requires the surface buffer" }
                val source = sourceBitmap ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also { sourceBitmap = it }
                source.eraseColor(Color.TRANSPARENT)
                val layerCanvas = Canvas(source)
                val save = layerCanvas.saveLayer(0f, 0f, width.toFloat(), height.toFloat(), Paint().apply { alpha = (entry.layer.opacity * 255).roundToInt() })
                paintEntry(layerCanvas, entry); layerCanvas.restoreToCount(save)
                if (sourcePixels.size != width * height) { sourcePixels = IntArray(width * height); destinationPixels = IntArray(width * height) }
                source.getPixels(sourcePixels, 0, width, 0, 0, width, height)
                target.getPixels(destinationPixels, 0, width, 0, 0, width, height)
                for (index in sourcePixels.indices) destinationPixels[index] = blendArtwork(entry.layer.blend, sourcePixels[index], destinationPixels[index])
                target.setPixels(destinationPixels, 0, width, 0, 0, width, height)
            } else {
                paint.alpha = (entry.layer.opacity * 255).roundToInt()
                if (Build.VERSION.SDK_INT >= 29 && !legacyBlending) paint.blendMode = when (entry.layer.blend) {
                    "multiply" -> BlendMode.MULTIPLY; "screen" -> BlendMode.SCREEN; "overlay" -> BlendMode.OVERLAY
                    "soft_light" -> BlendMode.SOFT_LIGHT; else -> BlendMode.SRC_OVER
                } else paint.xfermode = PorterDuffXfermode(when (entry.layer.blend) {
                    "multiply" -> PorterDuff.Mode.MULTIPLY; "screen" -> PorterDuff.Mode.SCREEN; "overlay" -> PorterDuff.Mode.OVERLAY; else -> PorterDuff.Mode.SRC_OVER
                })
                val saved = canvas.saveLayer(0f, 0f, width.toFloat(), height.toFloat(), paint)
                paintEntry(canvas, entry); canvas.restoreToCount(saved)
            }
        }
    }
    private fun paintEntry(canvas: Canvas, entry: Prepared) {
        val saved = canvas.save()
        canvas.rotate(entry.layer.rotation.toFloat(), entry.rect.centerX(), entry.rect.centerY())
        canvas.translate(entry.rect.left, entry.rect.top)
        // Preserve fractional authored extents after the Drawable's pixel rounding.
        canvas.scale(entry.rect.width() / entry.drawable.bounds.width(), entry.rect.height() / entry.drawable.bounds.height())
        entry.drawable.draw(canvas)
        canvas.restoreToCount(saved)
    }
}
