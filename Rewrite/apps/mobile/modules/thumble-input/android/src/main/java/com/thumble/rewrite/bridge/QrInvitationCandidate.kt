package com.thumble.rewrite.bridge

import com.thumble.rewrite.input.EnrollmentInvitation

/** QR codes use the same bounded, exact-key native invitation contract as manual entry. */
internal object QrInvitationCandidate {
    fun decode(text: String): EnrollmentInvitation? {
        if (text.length > 4096) return null
        return runCatching {
            val bytes = text.toByteArray(Charsets.UTF_8)
            check(bytes.size <= 4096)
            EnrollmentInvitation.decode(bytes)
        }
            .getOrNull()
    }
}
