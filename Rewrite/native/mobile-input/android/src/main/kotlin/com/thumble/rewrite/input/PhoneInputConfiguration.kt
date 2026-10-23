package com.thumble.rewrite.input

/** Epoch metadata only; grant admission independently verifies the exact map again. */
data class PhoneInputConfiguration
internal constructor(
    val active: Boolean,
    val generation: String,
    val revision: String,
    val inputEnabled: Boolean = false,
    val outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
) {

    internal companion object {
        fun decode(
            value: Map<String, EnrollmentJSON.Value>,
            connection: String,
            outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
        ): PhoneInputConfiguration {
            val active =
                (value["active"] as? EnrollmentJSON.Value.BooleanValue)?.value
                    ?: throw PhoneControlRejected()
            val generation =
                (value["generation"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw PhoneControlRejected()
            val revision =
                (value["revision"] as? EnrollmentJSON.Value.Text)?.value
                    ?: throw PhoneControlRejected()
            val epoch = ControlMap.counter(generation)
            if (
                value.keys !=
                    outputMode.fields(
                        setOf(
                            "version",
                            "command",
                            "connectionId",
                            "active",
                            "generation",
                            "revision",
                            "inputEnabled",
                        )
                    ) ||
                    value["version"] != EnrollmentJSON.Value.Integer(1) ||
                    value["command"] != EnrollmentJSON.Value.Text("input-configuration") ||
                    value["connectionId"] != EnrollmentJSON.Value.Text(connection) ||
                    epoch == null ||
                    (active && epoch == 0uL) ||
                    ControlMap.counter(revision) == null
            )
                throw PhoneControlRejected()
            return PhoneInputConfiguration(
                active,
                generation,
                revision,
                outputMode.validate(value, active),
                outputMode,
            )
        }
    }
}
