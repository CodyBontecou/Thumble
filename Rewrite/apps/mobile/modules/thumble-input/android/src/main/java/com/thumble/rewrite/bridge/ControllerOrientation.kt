package com.thumble.rewrite.bridge

import android.app.Activity
import android.content.pm.ActivityInfo
import android.os.Looper
import java.lang.ref.WeakReference
import java.util.UUID

/** One route owns a temporary Activity policy; actual measured dimensions still gate input. */
internal object ControllerOrientation {
    private data class Lease(
        val token: String,
        val activity: WeakReference<Activity>,
        val original: Int,
    )

    private var lease: Lease? = null

    fun request(activity: Activity?): String {
        check(Looper.myLooper() == Looper.getMainLooper())
        check(activity != null && !activity.isFinishing && !activity.isDestroyed)
        val previous = lease
        val original =
            if (previous != null && previous.activity.get() === activity) previous.original
            else activity.requestedOrientation
        val token = UUID.randomUUID().toString()
        try {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            lease = Lease(token, WeakReference(activity), original)
        } catch (_: RuntimeException) {
            throw IllegalStateException("controller_orientation_unavailable")
        }
        return token
    }

    fun restore(token: String): Boolean {
        check(Looper.myLooper() == Looper.getMainLooper())
        val current = lease ?: return false
        if (token.length > 64 || current.token != token) return false
        lease = null
        val activity = current.activity.get() ?: return false
        if (activity.isFinishing || activity.isDestroyed) return false
        return try {
            activity.requestedOrientation = current.original
            true
        } catch (_: RuntimeException) {
            false
        }
    }
}
