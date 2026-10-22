package com.thumble.rewrite.input

/** Native receiver acknowledgment; does not renew TTL or authorize a replacement source. */
internal class PhoneInputProgress(
    value: Map<String, EnrollmentJSON.Value>,
    connection: String,
    session: String,
    map: ControlMap,
    lastOffered: ULong?,
    previous: ULong?,
    outputMode: PhoneOutputMode = PhoneOutputMode.RECORDING,
) {
    val active: Boolean
    val lastAccepted: ULong?

    init {
        if (
            value.keys !=
                outputMode.fields(
                    setOf(
                        "version",
                        "command",
                        "connectionId",
                        "sessionId",
                        "active",
                        "generation",
                        "revision",
                        "lastAcceptedSequence",
                        "inputEnabled",
                    )
                ) ||
                value["version"] != EnrollmentJSON.Value.Integer(1) ||
                value["command"] != EnrollmentJSON.Value.Text("input-status") ||
                value["connectionId"] != EnrollmentJSON.Value.Text(connection) ||
                value["sessionId"] != EnrollmentJSON.Value.Text(session) ||
                value["generation"] != EnrollmentJSON.Value.Text(map.generation) ||
                value["revision"] != EnrollmentJSON.Value.Text(map.revision)
        )
            throw PhoneControlRejected()
        active =
            (value["active"] as? EnrollmentJSON.Value.BooleanValue)?.value
                ?: throw PhoneControlRejected()
        outputMode.validate(value, active)
        lastAccepted =
            when (val sequence = value["lastAcceptedSequence"]) {
                EnrollmentJSON.Value.Null -> {
                    if (previous != null) throw PhoneControlRejected()
                    null
                }
                is EnrollmentJSON.Value.Text -> {
                    val number = sequence.value.toULongOrNull() ?: throw PhoneControlRejected()
                    if (
                        number.toString() != sequence.value ||
                            number >= 1_048_576uL ||
                            lastOffered == null ||
                            number > lastOffered ||
                            (previous != null && number < previous)
                    )
                        throw PhoneControlRejected()
                    number
                }
                else -> throw PhoneControlRejected()
            }
    }
}
