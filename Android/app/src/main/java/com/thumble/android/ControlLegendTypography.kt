package com.thumble.android

import android.graphics.Typeface
import android.os.Build
import android.text.Layout
import android.text.Spannable
import android.text.SpannableString
import android.text.TextPaint
import android.text.style.MetricAffectingSpan
import android.util.TypedValue
import android.view.Gravity
import android.widget.TextView
import kotlin.math.*

/** A point distance rather than an em value, also during TextView's auto-size probes. */
private class LegendTracking(private val pixels: Float): MetricAffectingSpan() {
    private fun apply(paint: TextPaint) { paint.letterSpacing=if(paint.textSize>0) pixels/paint.textSize else 0f }
    override fun updateDrawState(paint: TextPaint)=apply(paint)
    override fun updateMeasureState(paint: TextPaint)=apply(paint)
}

internal object ControlLegendTypography {
    private fun typeface(design: String,weight: Int,condensed: Boolean=false): Typeface {
        val family=when { condensed -> "sans-serif-condensed";design=="serif" -> "serif";design=="monospaced" -> "monospace";else -> "sans-serif" }
        return if(Build.VERSION.SDK_INT>=28) Typeface.create(Typeface.create(family,Typeface.NORMAL),weight,false)
            else Typeface.create(if(weight in 500..600 && family=="sans-serif") "sans-serif-medium" else family,if(weight>=700) Typeface.BOLD else Typeface.NORMAL)
    }
    fun apply(view: TextView,metrics: ControlTypography,width: Int,height: Int) {
        fun pixels(points: Double)=TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP,abs(points).toFloat(),view.resources.displayMetrics)*if(points<0) -1 else 1
        val density=view.resources.displayMetrics.density
        val padding=(metrics.padding*density).roundToInt()
        view.maxLines=metrics.lineLimit
        view.setPadding(padding,(2*density).roundToInt(),padding,(2*density).roundToInt())
        view.gravity=Gravity.CENTER_VERTICAL or when(metrics.alignment) { "leading" -> Gravity.START;"trailing" -> Gravity.END;else -> Gravity.CENTER_HORIZONTAL }
        view.letterSpacing=0f
        var tracking=metrics.tracking
        if(metrics.size==null) {
            // Native ViewThatFits tries 16, 14, then a condensed 14-point face;
            // it never shrinks a long ordinary button legend to eight points.
            val paint=TextPaint(view.paint).apply { typeface=typeface(metrics.design,metrics.weight);letterSpacing=0f }
            val available=max(0,width-2*padding).toFloat()
            fun fits(size: Double): Boolean { paint.textSize=pixels(size);return Layout.getDesiredWidth(view.text.toString(),paint)<=available && paint.fontSpacing<=max(0,height-view.paddingTop-view.paddingBottom) }
            val selected=metrics.candidates.firstOrNull(::fits)
            val condensed=selected==null
            view.typeface=typeface(metrics.design,if(condensed) 600 else metrics.weight,condensed)
            if(condensed) tracking=-.35
            view.setAutoSizeTextTypeWithDefaults(TextView.AUTO_SIZE_TEXT_TYPE_NONE)
            view.setTextSize(TypedValue.COMPLEX_UNIT_SP,(selected ?: 14.0).toFloat())
        } else {
            view.typeface=typeface(metrics.design,metrics.weight)
            if(metrics.minimumScale==1.0) {
                view.setAutoSizeTextTypeWithDefaults(TextView.AUTO_SIZE_TEXT_TYPE_NONE)
                view.setTextSize(TypedValue.COMPLEX_UNIT_SP,metrics.size.toFloat())
            } else {
                val upper=max(1,pixels(metrics.size).roundToInt())
                val lower=max(1,ceil(pixels(metrics.size*metrics.minimumScale).toDouble()).toInt()).coerceAtMost(upper)
                if(lower==upper) { view.setAutoSizeTextTypeWithDefaults(TextView.AUTO_SIZE_TEXT_TYPE_NONE);view.setTextSize(TypedValue.COMPLEX_UNIT_PX,upper.toFloat()) }
                else view.setAutoSizeTextTypeUniformWithConfiguration(lower,upper,1,TypedValue.COMPLEX_UNIT_PX)
            }
        }
        // Replacing a nonzero tracking style must also remove its old span when
        // returning to zero; comparing String content alone would leave it active.
        val raw=view.text.toString()
        view.text=if(tracking==0.0 || raw.isEmpty()) raw else SpannableString(raw).apply {
            setSpan(LegendTracking(pixels(tracking)),0,length,Spannable.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }
}
