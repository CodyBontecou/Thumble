package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadButtonV1
import com.thumble.rewrite.contracts.GamepadStateV1
import java.util.Collections

data class ControlRegion(
    val id: String,
    val action: String,
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
    val hapticFeedback: TouchHapticFeedback? = null,
) {
    internal fun contains(x: Double, y: Double) =
        x >= this.x && y >= this.y && x < this.x + width && y < this.y + height

    /** One native owner per output, including distinct maps using legacy/new aliases. */
    internal val analogTarget: String?
        get() =
            when (action) {
                "leftStick",
                "leftStandardStick" -> "leftStick"
                "rightStick",
                "rightStandardStick" -> "rightStick"
                "leftTrigger",
                "leftVerticalTrigger",
                "leftHorizontalTrigger" -> "leftTrigger"
                "rightTrigger",
                "rightVerticalTrigger",
                "rightHorizontalTrigger" -> "rightTrigger"
                else -> null
            }

    internal fun valid(): Boolean =
        Regex("[A-Za-z0-9-]{1,64}").matches(id) &&
            (hapticFeedback?.valid() ?: true) &&
            action in
                GamepadButtonV1.entries.map { it.name } +
                    listOf(
                        "leftStick",
                        "rightStick",
                        "leftTrigger",
                        "rightTrigger",
                        "leftStandardStick",
                        "rightStandardStick",
                        "leftVerticalTrigger",
                        "rightVerticalTrigger",
                        "leftHorizontalTrigger",
                        "rightHorizontalTrigger",
                    ) &&
            listOf(x, y, width, height).all { it.isFinite() } &&
            x >= 0 &&
            y >= 0 &&
            width >= 0.001 &&
            height >= 0.001 &&
            x + width <= 1 &&
            y + height <= 1
}

class ControlMap(
    val version: Int = 1,
    val generation: String,
    val revision: String,
    controls: List<ControlRegion>,
) {
    val controls: List<ControlRegion> = Collections.unmodifiableList(ArrayList(controls))

    internal fun validated(): Pair<ULong, ULong> {
        val epoch = counter(generation)
        val revision = counter(revision)
        require(
            version == 1 &&
                controls.size in 1..64 &&
                controls.all { it.valid() } &&
                controls.map { it.id }.toSet().size == controls.size &&
                epoch != null &&
                epoch > 0u &&
                revision != null
        ) {
            "invalid_map"
        }
        return Pair(epoch, revision)
    }

    companion object {
        internal fun counter(value: String): ULong? =
            if (Regex("(?:0|[1-9][0-9]{0,19})").matches(value)) value.toULongOrNull() else null
    }
}

enum class ReleaseReason {
    touchCancelled,
    background,
    screenLock,
    rotation,
    profileReplacement,
    disconnected,
    disposed,
    practice,
    invalidTouch,
    transportFailure,
    sequenceExhausted,
}

data class InputSample(val generation: String, val sequence: String, val state: GamepadStateV1)

data class ActivationReceipt(val version: Int = 1, val generation: String, val revision: String)
