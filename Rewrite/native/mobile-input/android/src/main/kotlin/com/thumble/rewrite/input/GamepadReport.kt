package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadButtonV1
import com.thumble.rewrite.contracts.GamepadStateV1
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.sign

object GamepadReport {
    fun neutral() = GamepadStateV1(emptyList(), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)

    fun valid(s: GamepadStateV1) =
        s.buttons.size <= 17 &&
            s.buttons.toSet().size == s.buttons.size &&
            listOf(s.leftStickX, s.leftStickY, s.rightStickX, s.rightStickY).all {
                it.isFinite() && it in -1.0..1.0
            } &&
            listOf(s.leftTrigger, s.rightTrigger).all { it.isFinite() && it in 0.0..1.0 }

    /** Retained v2 oracle; no device creation or OS input. */
    fun encode(s: GamepadStateV1): ByteArray {
        val buttons = s.buttons.toSet()
        var mask = 0
        for (button in buttons) {
            val bit =
                when (button) {
                    GamepadButtonV1.dpadUp -> 0
                    GamepadButtonV1.dpadDown -> 1
                    GamepadButtonV1.dpadLeft -> 2
                    GamepadButtonV1.dpadRight -> 3
                    GamepadButtonV1.start -> 4
                    GamepadButtonV1.select -> 5
                    GamepadButtonV1.leftStickPress -> 6
                    GamepadButtonV1.rightStickPress -> 7
                    GamepadButtonV1.leftShoulder -> 8
                    GamepadButtonV1.rightShoulder -> 9
                    GamepadButtonV1.home -> 10
                    GamepadButtonV1.south -> 12
                    GamepadButtonV1.east -> 13
                    GamepadButtonV1.west -> 14
                    GamepadButtonV1.north -> 15
                    GamepadButtonV1.leftTriggerButton,
                    GamepadButtonV1.rightTriggerButton -> -1
                }
            if (bit >= 0) mask = mask or (1 shl bit)
        }
        if (GamepadButtonV1.dpadUp in buttons && GamepadButtonV1.dpadDown in buttons)
            mask = mask and 3.inv()
        if (GamepadButtonV1.dpadLeft in buttons && GamepadButtonV1.dpadRight in buttons)
            mask = mask and 12.inv()
        fun bounded(v: Double, minimum: Double) =
            (if (v.isFinite()) v else 0.0).coerceIn(minimum, 1.0)
        fun roundAway(v: Double) = (sign(v) * floor(abs(v) + 0.5)).toInt()
        val bytes = ByteArray(20)
        bytes[1] = 20
        bytes[2] = mask.toByte()
        bytes[3] = (mask shr 8).toByte()
        bytes[4] =
            roundAway(
                    bounded(
                        if (GamepadButtonV1.leftTriggerButton in buttons) 1.0 else s.leftTrigger,
                        0.0,
                    ) * 255
                )
                .toByte()
        bytes[5] =
            roundAway(
                    bounded(
                        if (GamepadButtonV1.rightTriggerButton in buttons) 1.0 else s.rightTrigger,
                        0.0,
                    ) * 255
                )
                .toByte()
        for ((i, raw) in
            listOf(s.leftStickX, -s.leftStickY, s.rightStickX, -s.rightStickY).withIndex()) {
            val v = bounded(raw, -1.0)
            val axis = roundAway(v * (if (v < 0) 32768 else 32767))
            bytes[6 + i * 2] = axis.toByte()
            bytes[7 + i * 2] = (axis shr 8).toByte()
        }
        return bytes
    }

    fun hex(state: GamepadStateV1) =
        encode(state).joinToString("") { "%02x".format(it.toInt() and 255) }
}
