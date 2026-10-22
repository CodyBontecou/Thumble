package com.thumble.rewrite.qa

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.thumble.rewrite.input.EnrollmentInvitation
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic invitation data only; this proves admission, not physical-camera recognition. */
@RunWith(AndroidJUnit4::class)
class QrInvitationTest {
    private val valid =
        """{"host":"127.0.0.1","port":4433,"certificatePin":"${"11".repeat(32)}","authorityInstanceId":"authority-a","windowId":"window-a","secret":"${"22".repeat(32)}","expiresAt":9007199254740991}"""

    private fun decode(text: String): EnrollmentInvitation? {
        val type = Class.forName("com.thumble.rewrite.bridge.QrInvitationCandidate")
        return type
            .getMethod("decode", String::class.java)
            .invoke(type.getField("INSTANCE").get(null), text) as EnrollmentInvitation?
    }

    @Test
    fun exactNativeInvitationAcceptedAndRedacted() {
        val result = checkNotNull(decode(valid))
        assertEquals("127.0.0.1", result.host)
        assertEquals(4433, result.port)
        assertEquals("EnrollmentInvitation([redacted])", result.toString())
    }

    @Test
    fun unrelatedMalformedDuplicateAndOversizedCodesStayUnadmitted() {
        for (text in
            listOf(
                "https://example.invalid",
                "{}",
                valid.dropLast(1) + ",\"extra\":1}",
                valid.replace("\"port\":4433", "\"port\":4433,\"port\":4433"),
                valid.replace("4433", "0"),
                "x".repeat(4097),
                "é".repeat(2049),
            )) {
            assertNull(decode(text))
        }
    }
}
