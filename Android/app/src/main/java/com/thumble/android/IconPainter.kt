package com.thumble.android

import android.graphics.*
import org.json.JSONObject
import kotlin.math.*

/** Native text/asset icons plus portable drawings for the template symbol vocabulary. */
internal class IconPainter(private val icon: ControlIcon, private val assets: AssetImages) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
    private var raster: RasterAsset? = null
    private var rasterSize = -1
    fun draw(canvas: Canvas, centerX: Float, centerY: Float, size: Float, foreground: Int) {
        if (size <= 0) return
        val tint = rgbaColor(icon.tint, foreground)
        paint.color = tint; paint.alpha = Color.alpha(tint); paint.shader = null; paint.colorFilter = null
        paint.style = Paint.Style.FILL; paint.typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        if (icon.source == "asset") {
            if (rasterSize != size.roundToInt()) {
                rasterSize = size.roundToInt()
                raster = assets.image(JSONObject().put("assetID", icon.value).put("contentMode", "fit"), rasterSize, rasterSize)
            }
            val bitmap = raster?.bitmap
            if (bitmap != null) {
                val scale = min(size / bitmap.width, size / bitmap.height)
                val width = bitmap.width * scale; val height = bitmap.height * scale
                paint.alpha = 255
                if (icon.renderingMode == "template") paint.colorFilter = PorterDuffColorFilter(tint, PorterDuff.Mode.SRC_IN)
                canvas.drawBitmap(bitmap, null, RectF(centerX - width / 2, centerY - height / 2, centerX + width / 2, centerY + height / 2), paint)
            } else placeholder(canvas, centerX, centerY, size)
        } else if (icon.source == "text") text(canvas, icon.value, centerX, centerY, size)
        else symbol(canvas, centerX, centerY, size)
    }
    private fun text(canvas: Canvas, value: String, x: Float, y: Float, size: Float) {
        paint.textSize = size; paint.textAlign = Paint.Align.CENTER
        canvas.drawText(value, x, y - (paint.ascent() + paint.descent()) / 2, paint)
    }
    private fun placeholder(canvas: Canvas, x: Float, y: Float, size: Float) {
        paint.alpha = (paint.alpha * .72).roundToInt(); paint.style = Paint.Style.STROKE; paint.strokeWidth = max(1f, size * .06f)
        canvas.drawRect(x - size * .4f, y - size * .35f, x + size * .4f, y + size * .35f, paint)
        val path = Path().apply { moveTo(x - size * .35f, y + size * .25f); lineTo(x - size * .1f, y); lineTo(x + size * .1f, y + size * .17f); lineTo(x + size * .3f, y - size * .05f) }
        canvas.drawPath(path, paint)
        paint.style = Paint.Style.FILL
    }
    private fun symbol(canvas: Canvas, x: Float, y: Float, size: Float) {
        val name = icon.value
        if (name == "command" || name == "command.square") {
            text(canvas, "⌘", x, y, size * .85f)
            if (name.endsWith(".square")) {
                paint.style = Paint.Style.STROKE; paint.strokeWidth = max(1f, size * .05f)
                canvas.drawRoundRect(x - size / 2, y - size / 2, x + size / 2, y + size / 2, size * .12f, size * .12f, paint)
            }
            return
        }
        val saved = canvas.save()
        canvas.translate(x - size / 2, y - size / 2); canvas.scale(size, size)
        paint.style = Paint.Style.STROKE; paint.strokeWidth = .09f; paint.strokeCap = Paint.Cap.ROUND; paint.strokeJoin = Paint.Join.ROUND
        val path = Path()
        fun line(vararg values: Float) { path.moveTo(values[0], values[1]); for (i in 2 until values.size step 2) path.lineTo(values[i], values[i + 1]) }
        when (name) {
            "arrow.up" -> { line(.5f,.88f,.5f,.12f); line(.18f,.42f,.5f,.1f,.82f,.42f) }
            "arrow.down" -> { line(.5f,.12f,.5f,.88f); line(.18f,.58f,.5f,.9f,.82f,.58f) }
            "arrow.left" -> { line(.88f,.5f,.12f,.5f); line(.42f,.18f,.1f,.5f,.42f,.82f) }
            "arrow.right", "arrow.right.to.line" -> {
                val end = if (name.endsWith("to.line")) .76f else .9f
                line(.1f,.5f,end,.5f); line(end-.3f,.18f,end,.5f,end-.3f,.82f)
                if (name.endsWith("to.line")) line(.94f,.12f,.94f,.88f)
            }
            "return" -> { line(.87f,.2f,.87f,.55f,.13f,.55f); line(.4f,.28f,.12f,.55f,.4f,.82f) }
            "terminal" -> { path.addRoundRect(.04f,.12f,.96f,.88f,.08f,.08f,Path.Direction.CW); line(.2f,.32f,.38f,.5f,.2f,.68f); line(.5f,.68f,.75f,.68f) }
            "xmark.octagon.fill" -> {
                paint.style = Paint.Style.FILL
                for (i in 0..7) { val a = Math.PI / 8 + i * Math.PI / 4; val px = .5f + cos(a).toFloat() * .5f; val py = .5f + sin(a).toFloat() * .5f; if (i == 0) path.moveTo(px,py) else path.lineTo(px,py) }
                path.close(); canvas.drawPath(path, paint)
                paint.color = if (Color.luminance(paint.color) > .5) Color.BLACK else Color.WHITE
                paint.style = Paint.Style.STROKE; path.reset(); line(.32f,.32f,.68f,.68f); line(.32f,.68f,.68f,.32f)
            }
            "plus" -> { line(.5f,.15f,.5f,.85f); line(.15f,.5f,.85f,.5f) }
            "minus" -> line(.15f,.5f,.85f,.5f)
            "xmark" -> { line(.2f,.2f,.8f,.8f); line(.2f,.8f,.8f,.2f) }
            "checkmark" -> line(.15f,.5f,.4f,.75f,.85f,.2f)
            "play.fill" -> { paint.style = Paint.Style.FILL; line(.2f,.1f,.9f,.5f,.2f,.9f); path.close() }
            "pause.fill" -> { paint.style = Paint.Style.FILL; path.addRect(.2f,.1f,.4f,.9f,Path.Direction.CW); path.addRect(.6f,.1f,.8f,.9f,Path.Direction.CW) }
            "stop.fill" -> { paint.style = Paint.Style.FILL; path.addRoundRect(.15f,.15f,.85f,.85f,.04f,.04f,Path.Direction.CW) }
            else -> { paint.style = Paint.Style.FILL; text(canvas, "?", .5f, .5f, .85f) }
        }
        canvas.drawPath(path, paint)
        canvas.restoreToCount(saved)
    }
}
