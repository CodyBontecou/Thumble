package com.thumble.android

import java.util.UUID
import kotlin.math.max
import kotlin.math.min

/** Port of GamepadLayoutResolver.defaultNormalizedCenter for unspecialized starter controls. */
internal fun defaultCenter(id: UUID, southpaw: Boolean, width: Double, height: Double,
                           controlWidth: Double, controlHeight: Double): Pair<Double, Double> {
    val index = if (id.toString().startsWith("00000000-0000-0000-0000-")) (id.leastSignificantBits - 0x100).toInt() else 0
    if (width >= height) {
        val x = min(.18, max(.08, controlWidth * 1.12 / width))
        val y = min(.26, max(.10, controlHeight * 1.12 / height))
        val nav = if (southpaw) .82 else .18
        val action = if (southpaw) .18 else .82
        return when (index) {
            1 -> nav to .56 - y; 2 -> nav to .56 + y
            3 -> nav - x to .56; 4 -> nav + x to .56
            8 -> action - x * .55 to .56 - y * .55; 7 -> action + x * .55 to .56 - y * .55
            6 -> action - x * .55 to .56 + y * .55; 5 -> action + x * .55 to .56 + y * .55
            9 -> .43 to .56; 10 -> .57 to .56
            else -> .5 to .56
        }
    }
    val x = min(.22, max(.13, controlWidth * 1.16 / width))
    val y = min(.12, max(.08, controlHeight * 1.10 / height))
    val nav = if (southpaw) .74 else .28
    val action = if (southpaw) .28 else .74
    return when (index) {
        1 -> .5 to nav - y; 2 -> .5 to nav + y
        3 -> .5 - x to nav; 4 -> .5 + x to nav
        8 -> .5 - x * .55 to action - y * .75; 7 -> .5 + x * .55 to action - y * .75
        6 -> .5 - x * .55 to action + y * .75; 5 -> .5 + x * .55 to action + y * .75
        9 -> .36 to .51; 10 -> .64 to .51
        else -> .5 to .51
    }
}
