package com.thumble.rewrite.input

import javax.crypto.KeyGenerator
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PhoneCredentialTest {
    private val pin = "11".repeat(32)

    private fun credential(epoch: Long = 7, host: String = pin, token: Int = 34) =
        PhoneCredential(
            PhoneCredentialMetadata(host, "phone-a", epoch, 1234567890000),
            ByteArray(32) { token.toByte() },
        )

    private class MemoryStorage : PhoneCredentialStorage {
        val values = mutableMapOf<String, ByteArray>()
        var failRead = false
        var failWrite = false
        var corruptReadback = false
        var depth = 0
        var writes = 0

        override fun <T> transaction(action: () -> T): T =
            synchronized(this) {
                check(depth == 0)
                depth++
                try {
                    action()
                } finally {
                    depth--
                }
            }

        override fun read(pin: String): ByteArray? {
            check(depth == 1)
            if (failRead) throw PhoneCredentialRejected("phone_credential_unavailable")
            if (corruptReadback && writes > 0) return byteArrayOf(0)
            return values[pin]?.copyOf()
        }

        override fun write(pin: String, bytes: ByteArray) {
            check(depth == 1)
            if (failWrite) throw PhoneCredentialRejected("phone_credential_unavailable")
            values[pin] = bytes.copyOf()
            writes++
        }

        override fun remove(pin: String) {
            check(depth == 1)
            values.remove(pin)
        }
    }

    private fun rejects(reason: String? = null, action: () -> Unit) {
        try {
            action()
            fail("credential operation was accepted")
        } catch (e: PhoneCredentialRejected) {
            if (reason != null) assertEquals(reason, e.reason)
        }
    }

    @Test
    fun sharedFixtureIsExactOpaqueAndImmutable() {
        val fixture =
            javaClass.classLoader!!.getResourceAsStream("phone-credential-v1.json")!!.use {
                JSONObject(it.readBytes().toString(Charsets.UTF_8))
            }
        val expected =
            fixture.getString("recordHex").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        val value = credential()
        assertArrayEquals(expected, value.encode())
        assertEquals(value.metadata, PhoneCredential.decode(expected).metadata)
        assertEquals("PhoneCredential([redacted])", value.toString())
        val token = ByteArray(32) { 34 }
        val immutable = PhoneCredential(value.metadata, token)
        token.fill(0)
        assertArrayEquals(expected, immutable.encode())
    }

    @Test
    fun malformedRecordsDoNotCreateCredentials() {
        val valid = credential().encode()
        for (bytes in
            listOf(
                byteArrayOf(),
                valid.copyOf(valid.size - 1),
                valid + byteArrayOf(0),
                ByteArray(1000),
            )) rejects { PhoneCredential.decode(bytes) }
        for (offset in listOf(0, 40, 41, 48, 56)) {
            val bad = valid.copyOf()
            when (offset) {
                40 -> bad[offset] = 65
                41 -> bad[offset] = 0
                48 -> (48..55).forEach { bad[it] = 0 }
                56 -> (56..63).forEach { bad[it] = 0 }
                else -> bad[offset] = 0
            }
            rejects { PhoneCredential.decode(bad) }
        }
        rejects { credential(0) }
        rejects { credential(-1) }
        rejects { credential(host = "AA".repeat(32)) }
    }

    @Test
    fun savesReadBackAndEqualEpochIsStrictlyIdempotent() {
        val storage = MemoryStorage()
        val vault = PhoneCredentialVault(storage)
        val value = credential()
        assertNull(vault.load(pin, 100))
        vault.save(value)
        vault.save(value)
        assertEquals(1, storage.writes)
        assertArrayEquals(value.encode(), vault.load(pin, 100)!!.encode())
        rejects("phone_credential_rollback") { vault.save(credential(6)) }
        rejects("phone_credential_rollback") { vault.save(credential(token = 9)) }
        vault.save(credential(8))
        assertEquals(8, vault.load(pin, 100)!!.metadata.epoch)
    }

    @Test
    fun storageAndReadbackFailuresCannotAcknowledgeOrErase() {
        val storage = MemoryStorage()
        val vault = PhoneCredentialVault(storage)
        val value = credential()
        vault.save(value)
        storage.failWrite = true
        rejects("phone_credential_unavailable") { vault.save(credential(8)) }
        assertArrayEquals(value.encode(), storage.values[pin])
        storage.failRead = true
        rejects("phone_credential_unavailable") { vault.load(pin, 100) }
        assertArrayEquals(value.encode(), storage.values[pin])
        val uncertain = MemoryStorage()
        uncertain.corruptReadback = true
        val other = PhoneCredentialVault(uncertain)
        rejects("phone_credential_unconfirmed") { other.save(value) }
        assertArrayEquals(value.encode(), uncertain.values[pin])
        uncertain.corruptReadback = false
        assertEquals(value.metadata, other.load(pin, 100)!!.metadata)
    }

    @Test
    fun expiryHostBindingAndForgetAreScoped() {
        val storage = MemoryStorage()
        val vault = PhoneCredentialVault(storage)
        val other = credential(host = "22".repeat(32))
        vault.save(credential())
        vault.save(other)
        rejects("phone_credential_expired") { vault.load(pin, credential().metadata.expiresAt) }
        assertNotNull(storage.values[pin])
        storage.values[pin] = other.encode()
        rejects { vault.load(pin, 100) }
        rejects { vault.save(credential()) }
        vault.forget(pin)
        assertNull(vault.load(pin, 100))
        assertEquals(other.metadata, vault.load(other.metadata.hostPin, 100)!!.metadata)
    }

    @Test
    fun realJceEncryptionUsesFreshNonceAndBindsPinNamespaceKeyAndContent() {
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val wrong = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val plain = credential().encode()
        val encrypted = PhoneCredentialCipher.encrypt(pin, key, plain)
        assertArrayEquals(plain, PhoneCredentialCipher.decrypt(pin, key, encrypted))
        assertFalse(
            encrypted
                .copyOfRange(1, 13)
                .contentEquals(PhoneCredentialCipher.encrypt(pin, key, plain).copyOfRange(1, 13))
        )
        assertFalse(encrypted.toList().windowed(plain.size).any { it == plain.toList() })
        for (offset in listOf(1, 13, encrypted.lastIndex)) {
            val bad = encrypted.copyOf()
            bad[offset] = (bad[offset].toInt() xor 1).toByte()
            try {
                PhoneCredentialCipher.decrypt(pin, key, bad)
                fail("tampered ciphertext accepted")
            } catch (_: javax.crypto.AEADBadTagException) {}
        }
        try {
            PhoneCredentialCipher.decrypt("22".repeat(32), key, encrypted)
            fail("wrong host accepted")
        } catch (_: javax.crypto.AEADBadTagException) {}
        try {
            PhoneCredentialCipher.decrypt(pin, wrong, encrypted)
            fail("wrong key accepted")
        } catch (_: javax.crypto.AEADBadTagException) {}
        rejects { PhoneCredentialCipher.decrypt(pin, key, encrypted.copyOf(183)) }
    }
}
