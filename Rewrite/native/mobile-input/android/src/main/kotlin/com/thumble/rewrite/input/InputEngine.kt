package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadButtonV1
import com.thumble.rewrite.contracts.GamepadStateV1
import java.util.Collections
import kotlin.math.abs
import kotlin.math.hypot

/** Native UI-thread owner; no React callback is involved in touch sampling. */
class InputEngine(
    private val output: (InputSample) -> Boolean,
    private val feedback: (GamepadStateV1) -> Unit = {},
) {
    internal var onRelease: (ReleaseReason) -> Unit = {}

    private data class Capture(val region: ControlRegion, val x: Double, val y: Double)

    private val owner = Thread.currentThread()
    private var map: ControlMap? = null
    private var epoch = 0uL
    private var revision = 0uL
    private var sequence = 0uL
    private val captures = mutableMapOf<Long, Capture>()
    private var admitted = false
    private var surfaceClaimed = false
    private var publishing = false
    private var disposed = false
    var connected = false
        private set

    var practice = false
        private set

    var state = GamepadReport.neutral()
        private set

    var lastRelease: ReleaseReason? = null
        private set

    val generation: String
        get() = epoch.toString()

    private fun checkOwner() = check(Thread.currentThread() === owner) { "wrong_input_thread" }

    fun activate(next: ControlMap): ActivationReceipt {
        checkOwner()
        check(!publishing) { "reentrant" }
        check(!disposed) { "unavailable" }
        val (newEpoch, newRevision) = next.validated()
        require(newEpoch > epoch && newRevision >= revision) { "stale_map" }
        cancel(ReleaseReason.profileReplacement)
        map = next
        epoch = newEpoch
        revision = newRevision
        sequence = 0u
        admitted = false
        return ActivationReceipt(generation = next.generation, revision = next.revision)
    }

    fun connect(generation: String) {
        checkOwner()
        check(!publishing) { "reentrant" }
        check(!disposed && !practice && map != null && generation == this.generation) {
            "unavailable"
        }
        check(!admitted) { "fresh_generation_required" }
        admitted = true
        captures.clear()
        state = GamepadReport.neutral()
        connected = true
        emit()
    }

    /** Claim a newly bound neutral engine exactly once without reactivating its grant. */
    fun claimTouchSurface(): ControlMap {
        checkOwner()
        check(!publishing) { "reentrant" }
        check(
            !disposed &&
                connected &&
                !practice &&
                !surfaceClaimed &&
                captures.isEmpty() &&
                sequence == 1uL
        ) {
            "unavailable"
        }
        val admitted = checkNotNull(map) { "unavailable" }
        surfaceClaimed = true
        return admitted
    }

    fun begin(id: Long, generation: String, x: Double, y: Double): Boolean {
        checkOwner()
        if (!accepts(generation) || publishing) return false
        if (id < 0 || !validPoint(x, y) || captures.containsKey(id) || captures.size >= 16) {
            cancel(ReleaseReason.invalidTouch)
            return false
        }
        val region = map?.controls?.asReversed()?.firstOrNull { it.contains(x, y) } ?: return false
        if (
            region.analogTarget != null &&
                captures.values.any { it.region.analogTarget == region.analogTarget }
        )
            return false
        captures[id] = Capture(region, x, y)
        update()
        return true
    }

    fun move(id: Long, generation: String, x: Double, y: Double) {
        checkOwner()
        if (!accepts(generation) || publishing) return
        val capture = captures[id] ?: return
        if (!validPoint(x, y)) {
            cancel(ReleaseReason.invalidTouch)
            return
        }
        captures[id] = capture.copy(x = x, y = y)
        update()
    }

    fun end(id: Long, generation: String) {
        checkOwner()
        if (!accepts(generation) || publishing || captures.remove(id) == null) return
        update()
    }

    fun tick() {
        checkOwner()
        if (!publishing && !disposed) emit()
    }

    fun setPractice(enabled: Boolean) {
        checkOwner()
        if (publishing || disposed || enabled == practice) return
        cancel(ReleaseReason.practice)
        practice = enabled
    }

    fun cancel(reason: ReleaseReason) {
        checkOwner()
        if (publishing || disposed) return
        val wasConnected = connected
        captures.clear()
        state = GamepadReport.neutral()
        lastRelease = reason
        emit()
        connected = false
        if (reason == ReleaseReason.disposed) disposed = true
        if (wasConnected) onRelease(reason)
    }

    private fun accepts(generation: String) =
        !disposed && map != null && generation == this.generation && (connected || practice)

    private fun validPoint(x: Double, y: Double) =
        x.isFinite() && y.isFinite() && abs(x) <= 16 && abs(y) <= 16

    private fun update() {
        val buttons = mutableSetOf<GamepadButtonV1>()
        var lx = 0.0
        var ly = 0.0
        var rx = 0.0
        var ry = 0.0
        var lt = 0.0
        var rt = 0.0
        for (capture in captures.values) {
            val r = capture.region
            if (r.analogTarget == "leftStick" || r.analogTarget == "rightStick") {
                var x = ((capture.x - r.x) / r.width - 0.5) * 2
                var y = ((capture.y - r.y) / r.height - 0.5) * 2
                val length = hypot(x, y)
                if (length > 1) {
                    x /= length
                    y /= length
                }
                if (r.action == "leftStandardStick" || r.action == "rightStandardStick") {
                    // Retained pad vector: clamp radius, then radial .12 deadzone,
                    // sensitivity 1, no inversion/cardinal snapping/digital directions.
                    val radius = hypot(x, y)
                    if (radius <= 0.12) {
                        x = 0.0
                        y = 0.0
                    } else {
                        val scaled = ((radius - 0.12) / 0.88).coerceIn(0.0, 1.0)
                        x = x / radius * scaled
                        y = y / radius * scaled
                    }
                }
                if (r.analogTarget == "leftStick") {
                    lx = x
                    ly = y
                } else {
                    rx = x
                    ry = y
                }
            } else if (
                r.action == "leftVerticalTrigger" ||
                    r.action == "rightVerticalTrigger" ||
                    r.action == "leftHorizontalTrigger" ||
                    r.action == "rightHorizontalTrigger"
            ) {
                // Captured triggers retain ownership while dragged outside the pad.
                val raw =
                    if (r.action.endsWith("VerticalTrigger")) {
                        1.0 - (capture.y - r.y) / r.height
                    } else {
                        (capture.x - r.x) / r.width
                    }
                val clamped = raw.coerceIn(0.0, 1.0)
                val value =
                    if (clamped <= 0.03) 0.0 else ((clamped - 0.03) / 0.97).coerceIn(0.0, 1.0)
                if (r.analogTarget == "leftTrigger") lt = value else rt = value
            } else if (r.contains(capture.x, capture.y)) {
                when (r.action) {
                    "leftTrigger" -> lt = 1.0
                    "rightTrigger" -> rt = 1.0
                    else -> buttons.add(GamepadButtonV1.valueOf(r.action))
                }
            }
        }
        state =
            GamepadStateV1(
                Collections.unmodifiableList(GamepadButtonV1.entries.filter { it in buttons }),
                lx,
                ly,
                rx,
                ry,
                lt,
                rt,
            )
        emit()
    }

    private fun emit() {
        if (publishing) return
        publishing = true
        try {
            feedback(state)
            if (!connected || practice) return
            if (sequence == ULong.MAX_VALUE) {
                connected = false
                captures.clear()
                state = GamepadReport.neutral()
                lastRelease = ReleaseReason.sequenceExhausted
                feedback(state)
                onRelease(ReleaseReason.sequenceExhausted)
                return
            }
            val sample = InputSample(generation, sequence.toString(), state)
            sequence++
            if (!output(sample)) {
                connected = false
                captures.clear()
                state = GamepadReport.neutral()
                lastRelease = ReleaseReason.transportFailure
                feedback(state)
                onRelease(ReleaseReason.transportFailure)
            }
        } catch (_: Exception) {
            connected = false
            captures.clear()
            state = GamepadReport.neutral()
            lastRelease = ReleaseReason.transportFailure
            onRelease(ReleaseReason.transportFailure)
        } finally {
            publishing = false
        }
    }
}
