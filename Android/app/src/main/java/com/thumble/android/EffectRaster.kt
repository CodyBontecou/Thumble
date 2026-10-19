package com.thumble.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.util.LruCache
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.*

internal data class EffectRaster(val bitmap: Bitmap, val left: Float, val top: Float, val scale: Float) {
    fun draw(canvas: Canvas, paint: Paint? = null) = canvas.drawBitmap(bitmap, null,
        RectF(left, top, left + bitmap.width * scale, top + bitmap.height * scale), paint)
}

/** Surface-owned, bounded cache. Eviction never recycles bitmaps retained by display lists. */
internal class EffectRasterCache {
    private val cache = object : LruCache<String, EffectRaster>((Runtime.getRuntime().maxMemory() / 8).coerceIn(8L * 1024 * 1024, 32L * 1024 * 1024).toInt()) {
        override fun sizeOf(key: String, value: EffectRaster) = value.bitmap.allocationByteCount
    }
    fun get(key: String, build: () -> EffectRaster): EffectRaster = cache.get(key) ?: build().also { cache.put(key, it) }
    fun remove(key: String) { cache.remove(key) }
    companion object { private val ids = AtomicLong(); fun id() = ids.incrementAndGet() }
}

/** Three separable box passes approximate a Gaussian while preserving premultiplied alpha. */
internal fun blurBitmap(bitmap: Bitmap, sigma: Float): Bitmap {
    if (sigma <= .01f) return bitmap
    val w = bitmap.width; val h = bitmap.height
    var input = IntArray(w * h); var output = IntArray(input.size)
    bitmap.getPixels(input, 0, w, 0, 0, w, h)
    for (i in input.indices) {
        val p = input[i]; val a = p ushr 24
        input[i] = a shl 24 or (((p ushr 16 and 255) * a / 255) shl 16) or (((p ushr 8 and 255) * a / 255) shl 8) or ((p and 255) * a / 255)
    }
    var lower = floor(sqrt(4 * sigma * sigma + 1.0)).toInt().coerceAtLeast(1)
    if (lower % 2 == 0) lower--
    val upper = lower + 2
    val count = ((12 * sigma * sigma - 3 * lower * lower - 12 * lower - 9) / (-4.0 * lower - 4)).roundToInt().coerceIn(0, 3)
    fun pass(radius: Int, horizontal: Boolean) {
        val lines = if (horizontal) h else w; val length = if (horizontal) w else h
        val stride = if (horizontal) 1 else w
        val divisor = radius * 2 + 1
        for (line in 0 until lines) {
            val base = if (horizontal) line * w else line
            var a = 0; var r = 0; var g = 0; var b = 0
            fun add(pixel: Int, sign: Int) { a += (pixel ushr 24) * sign; r += (pixel ushr 16 and 255) * sign; g += (pixel ushr 8 and 255) * sign; b += (pixel and 255) * sign }
            for (j in 0..min(radius, length - 1)) add(input[base + j * stride], 1)
            for (j in 0 until length) {
                output[base + j * stride] = ((a + divisor / 2) / divisor shl 24) or ((r + divisor / 2) / divisor shl 16) or ((g + divisor / 2) / divisor shl 8) or ((b + divisor / 2) / divisor)
                if (j - radius >= 0) add(input[base + (j - radius) * stride], -1)
                if (j + radius + 1 < length) add(input[base + (j + radius + 1) * stride], 1)
            }
        }
        val old = input; input = output; output = old
    }
    for (index in 0..2) { val radius = ((if (index < count) lower else upper) - 1) / 2; pass(radius, true); pass(radius, false) }
    for (i in input.indices) {
        val p = input[i]; val a = p ushr 24
        input[i] = if (a == 0) 0 else (a shl 24) or (((p ushr 16 and 255) * 255 / a).coerceAtMost(255) shl 16) or (((p ushr 8 and 255) * 255 / a).coerceAtMost(255) shl 8) or ((p and 255) * 255 / a).coerceAtMost(255)
    }
    return Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).also { it.setPixels(input, 0, w, 0, 0, w, h) }
}
