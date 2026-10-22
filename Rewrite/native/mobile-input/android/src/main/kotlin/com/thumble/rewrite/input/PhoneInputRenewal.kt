package com.thumble.rewrite.input

/** Native receipt context. An expired context cannot authorize its own successor. */
internal class PhoneInputRenewalScope(
    val sessionID: String,
    val udpPort: Int,
    val authorizationExpiresAt: Long,
    val credentialExpiresAt: Long,
)

/** Explicit version-six decoding; ordinary version-four/five grants reject this shape. */
internal class PhoneInputRenewal(
    value: Map<String, EnrollmentJSON.Value>,
    connection: String,
    map: ControlMap,
    scope: PhoneInputRenewalScope,
    now: Long,
) {
    val grant: PhoneInputGrant
    val authorizationExpiresAt: Long

    init {
        val expires =
            (value["authorizationExpiresAt"] as? EnrollmentJSON.Value.Integer)?.value
                ?: throw PhoneControlRejected()
        if (
            value["command"] != EnrollmentJSON.Value.Text("input-renewed") ||
                value["replacesSessionId"] != EnrollmentJSON.Value.Text(scope.sessionID) ||
                value["sessionId"] == EnrollmentJSON.Value.Text(scope.sessionID) ||
                now < 0 ||
                now >= scope.authorizationExpiresAt ||
                expires < scope.authorizationExpiresAt ||
                expires > scope.credentialExpiresAt ||
                expires <= now
        )
            throw PhoneControlRejected()
        grant =
            PhoneInputGrant(
                value - setOf("replacesSessionId", "authorizationExpiresAt") +
                    ("command" to EnrollmentJSON.Value.Text("input-granted")),
                connection,
                map,
                datagrams = true,
            )
        if (grant.udpPort != scope.udpPort) throw PhoneControlRejected()
        authorizationExpiresAt = expires
    }
}
