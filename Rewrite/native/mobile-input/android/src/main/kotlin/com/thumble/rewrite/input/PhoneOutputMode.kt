package com.thumble.rewrite.input

/** Explicit caller intent. This cannot create or authorize an OS device. */
enum class PhoneOutputMode {
    RECORDING,
    MACOS_HID;

    internal fun fields(base: Set<String>): Set<String> =
        if (this == RECORDING) base else base + "outputBackend"

    internal fun validate(
        value: Map<String, EnrollmentJSON.Value>,
        enabled: Boolean? = null,
    ): Boolean {
        val actual =
            (value["inputEnabled"] as? EnrollmentJSON.Value.BooleanValue)?.value
                ?: throw PhoneControlRejected()
        if (this == RECORDING) {
            if (actual || value.containsKey("outputBackend")) throw PhoneControlRejected()
        } else if (
            value["outputBackend"] != EnrollmentJSON.Value.Text("macos-hid") ||
                (enabled != null && actual != enabled)
        )
            throw PhoneControlRejected()
        return actual
    }
}
