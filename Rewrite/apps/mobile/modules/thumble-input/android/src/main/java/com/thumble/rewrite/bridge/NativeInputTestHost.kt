package com.thumble.rewrite.bridge

import android.app.Instrumentation
import com.thumble.rewrite.input.ControlMap
import com.thumble.rewrite.input.PhoneInputConfiguration

/** Native instrumentation port only. No Expo, JavaScript, environment or navigation setter. */
internal object NativeInputTestHost {
    @Volatile
    private var provider: ((PhoneInputConfiguration, Double, Double) -> ControlMap)? = null

    @JvmStatic
    fun install(
        instrumentation: Instrumentation,
        value: ((PhoneInputConfiguration, Double, Double) -> ControlMap)?,
    ) {
        val target = instrumentation.targetContext.packageName
        check(target.endsWith(".qa") && instrumentation.context.packageName == "$target.test")
        provider = value
    }

    fun current(): ((PhoneInputConfiguration, Double, Double) -> ControlMap)? = provider
}
