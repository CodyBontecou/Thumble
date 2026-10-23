package com.thumble.rewrite.input

import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/** Keep the test-owned native sampler alive while subprocess IO stays on its reader thread. */
internal fun <T> awaitNativeProbeReply(reply: Future<T>, sample: () -> Unit = {}): T {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
    while (true) {
        val remaining = deadline - System.nanoTime()
        if (remaining <= 0) throw TimeoutException("native_probe_reply_deadline")
        try {
            return reply.get(
                minOf(remaining, TimeUnit.MILLISECONDS.toNanos(16)),
                TimeUnit.NANOSECONDS,
            )
        } catch (_: TimeoutException) {
            sample()
        }
    }
}
