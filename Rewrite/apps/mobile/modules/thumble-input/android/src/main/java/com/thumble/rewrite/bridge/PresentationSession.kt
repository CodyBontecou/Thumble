package com.thumble.rewrite.bridge

import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.view.View
import com.thumble.rewrite.input.*
import java.io.Closeable
import java.util.concurrent.Executors

/** Optional cosmetics, with a separate socket/executor and main-thread lifetime checks. */
internal class PresentationSession(
    private val anchor: View,
    private val endpoint: TrustedHostEndpoint,
    private val saved: SavedControllerRequest,
    private val map: SavedControllerMap,
    private val bank: () -> PhonePresentationBank,
    private val active: () -> Boolean,
    private val notification: (Map<String, Any>) -> Unit,
) : Closeable {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "ThumblePhonePresentation").apply { isDaemon = true }
    }
    private val gate = Any()
    @Volatile private var closed = false
    @Volatile private var epoch = 0L
    private var client: PhonePresentationClient? = null
    private var busy = false
    // Worker-only immutable verified icon values; at most64/512KiB raw PNG bytes.
    private val cache = LinkedHashMap<String, PhonePresentationIcon>()
    private var cacheBytes = 0
    private val poll = Runnable { beginBatch() }

    private fun theme() =
        if (
            anchor.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
                Configuration.UI_MODE_NIGHT_YES
        )
            "dark"
        else "light"

    private fun valid(ticket: Long, scheme: String, selected: PhonePresentationBank?) =
        !closed && epoch == ticket && active() && theme() == scheme && bank() == selected

    fun start() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (!closed && !busy) beginBatch()
    }

    fun refreshTheme() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (closed) return
        epoch++
        main.removeCallbacks(poll)
        synchronized(gate) { client?.close() }
        if (!busy) beginBatch()
    }

    fun refreshBank() = refreshTheme()

    private fun emit(
        ticket: Long,
        scheme: String,
        request: PhonePresentationRequest,
        event: Map<String, Any>,
    ) {
        main.post {
            if (valid(ticket, scheme, request.bank))
                runCatching {
                    notification(request.bankNotification(endpoint.authorityInstanceID))
                    if (valid(ticket, scheme, request.bank)) notification(event)
                }
        }
    }

    private fun store(icon: PhonePresentationIcon) {
        if (cache.containsKey(icon.sha256)) return
        while (cache.isNotEmpty() && (cache.size >= 64 || cacheBytes + icon.byteCount > 524288)) {
            val key = cache.keys.first()
            cacheBytes -= cache.remove(key)!!.byteCount
        }
        if (cache.size < 64 && icon.byteCount <= 8192 && cacheBytes + icon.byteCount <= 524288) {
            cache[icon.sha256] = icon
            cacheBytes += icon.byteCount
        }
    }

    private fun beginBatch() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (closed || busy) return
        if (!active()) {
            close()
            return
        }
        val ticket = epoch
        val scheme = theme()
        val request =
            try {
                PhonePresentationRequest(saved, map, scheme, bank())
            } catch (_: Exception) {
                runCatching {
                    notification(
                        errorEvent(
                            PhonePresentationRequest(saved, map, scheme, bank()),
                            "presentation_unavailable",
                        )
                    )
                }
                main.postDelayed(poll, 2000)
                return
            }
        busy = true
        worker.execute {
            var batch: PhonePresentationClient? = null
            try {
                val next = PhonePresentationClient(endpoint, anchor.context.applicationContext)
                batch = next
                synchronized(gate) {
                    check(!closed && epoch == ticket)
                    client = next
                }
                val metadata = next.read(request)
                if (closed || epoch != ticket) return@execute
                // An unchanged successful metadata response still refreshes the UI observation
                // timer.
                emit(ticket, scheme, request, metadata.bridgeEvent())
                for (control in metadata.controls) {
                    if (closed || epoch != ticket) break
                    val hash = control.iconSHA256 ?: continue
                    val icon = cache[hash] ?: next.icon(control)
                    if (closed || epoch != ticket) break
                    store(icon)
                    emit(ticket, scheme, request, icon.notification(metadata, control.id))
                }
            } catch (error: Exception) {
                if (!closed && epoch == ticket) {
                    val code =
                        (error as? PhonePresentationUnavailable)?.code?.takeIf { it in ERRORS }
                            ?: "presentation_unavailable"
                    emit(ticket, scheme, request, errorEvent(request, code))
                }
            } finally {
                batch?.close()
                synchronized(gate) { if (client === batch) client = null }
                if (closed) {
                    cache.clear()
                    cacheBytes = 0
                }
                main.post {
                    busy = false
                    if (!closed) {
                        if (!active()) close()
                        else if (epoch != ticket || theme() != scheme) beginBatch()
                        else main.postDelayed(poll, 2000)
                    }
                }
            }
        }
    }

    private fun errorEvent(request: PhonePresentationRequest, code: String): Map<String, Any> =
        request.bankNotification(endpoint.authorityInstanceID).toMutableMap().apply {
            put("kind", "error")
            put("error", code)
        }

    override fun close() {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (closed) return
        closed = true
        epoch++
        main.removeCallbacks(poll)
        synchronized(gate) {
            client?.close()
            client = null
        }
        worker.shutdownNow()
    }

    companion object {
        private val ERRORS =
            setOf(
                "presentation_busy",
                "presentation_timeout",
                "presentation_unavailable",
                "presentation_reactivation_required",
                "presentation_unsupported_profile",
                "presentation_response_too_large",
                "presentation_stale",
            )
    }
}
