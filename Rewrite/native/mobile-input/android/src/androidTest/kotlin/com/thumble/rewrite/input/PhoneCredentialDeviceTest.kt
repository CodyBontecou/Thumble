package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic app-private credentials only. Run on an unlocked API 29+ emulator/device. */
@TargetApi(29)
@RunWith(AndroidJUnit4::class)
class PhoneCredentialDeviceTest {
    @Test
    fun realAndroidKeystorePersistsAndDetectsTampering() {
        assertTrue("Credential provider test requires API 29+", Build.VERSION.SDK_INT >= 29)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val pin = UUID.randomUUID().toString().replace("-", "").repeat(2)
        val credential =
            PhoneCredential(
                PhoneCredentialMetadata(pin, "test-phone", 1, System.currentTimeMillis() + 300000),
                ByteArray(32) { 42 },
            )
        val vault = PhoneCredentialVault(context)
        try {
            vault.save(credential)
            val restored = PhoneCredentialVault(context).load(pin, System.currentTimeMillis())
            assertNotNull(restored)
            assertEquals(credential.metadata, restored!!.metadata)
            val record = File(context.noBackupFilesDir, "rewrite-phone-trust-v1/$pin.enc")
            val bytes = record.readBytes()
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 1).toByte()
            record.writeBytes(bytes)
            try {
                PhoneCredentialVault(context).load(pin, System.currentTimeMillis())
                fail("tampered OS-backed credential accepted")
            } catch (_: PhoneCredentialRejected) {}
            assertTrue("Failed load must preserve evidence for explicit recovery", record.exists())
        } finally {
            vault.forget(pin)
        }
        assertNull(PhoneCredentialVault(context).load(pin, System.currentTimeMillis()))
    }
}
