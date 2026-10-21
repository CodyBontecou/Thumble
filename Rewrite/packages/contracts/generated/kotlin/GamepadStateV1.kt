// Generated from gamepad-state-v1.schema.json; do not edit. DTO only: validate before activation.
package com.thumble.rewrite.contracts

enum class GamepadButtonV1 {
    south, east, west, north, leftShoulder, rightShoulder, leftTriggerButton, rightTriggerButton, select, start, home, leftStickPress, rightStickPress, dpadUp, dpadDown, dpadLeft, dpadRight
}

data class GamepadStateV1(
    val buttons: List<GamepadButtonV1>,
    val leftStickX: Double,
    val leftStickY: Double,
    val rightStickX: Double,
    val rightStickY: Double,
    val leftTrigger: Double,
    val rightTrigger: Double,
)
