package com.thumble.rewrite.input

import com.thumble.rewrite.contracts.GamepadStateV1

/** Only successfully accepted semantic state selects appearance; never wire quantization. */
enum class PhonePresentationBank(val wire: String) {
    BASE("base"),
    LEFT_TRIGGER("left-trigger"),
    RIGHT_TRIGGER("right-trigger"),
    BOTH_TRIGGERS("both-triggers");

    companion object {
        fun accepted(state: GamepadStateV1): PhonePresentationBank =
            when {
                state.leftTrigger > .5 && state.rightTrigger > .5 -> BOTH_TRIGGERS
                state.leftTrigger > .5 -> LEFT_TRIGGER
                state.rightTrigger > .5 -> RIGHT_TRIGGER
                else -> BASE
            }
    }
}
