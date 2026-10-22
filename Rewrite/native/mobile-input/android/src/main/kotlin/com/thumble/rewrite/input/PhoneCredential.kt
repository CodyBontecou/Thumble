package com.thumble.rewrite.input

import android.annotation.TargetApi
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class PhoneCredentialRejected(val reason: String = "phone_credential_invalid") : Exception(reason)

data class PhoneCredentialMetadata(
    val hostPin: String,
    val phoneID: String,
    val epoch: Long,
    val expiresAt: Long,
)

/** Opaque native credential: no generated copy/components or token getter. */
class PhoneCredential
internal constructor(val metadata: PhoneCredentialMetadata, token: ByteArray) {
    private val secret = token.copyOf()

    init {
        if (
            !pin(metadata.hostPin) ||
                !metadata.phoneID.matches(Regex("[A-Za-z0-9-]{1,64}")) ||
                metadata.epoch <= 0 ||
                metadata.expiresAt <= 0 ||
                token.size != 32
        )
            throw PhoneCredentialRejected()
    }

    override fun toString() = "PhoneCredential([redacted])"

    internal fun authenticationFrame(authority: String): ControlTLSFrame {
        if (!EnrollmentInvitation.identity(authority)) throw PhoneCredentialRejected()
        val value =
            org.json
                .JSONObject()
                .put("version", 1)
                .put("command", "authenticate")
                .put("authorityInstanceId", authority)
                .put("phoneId", metadata.phoneID)
                .put("credentialEpoch", metadata.epoch.toString())
                .put("credential", secret.joinToString("") { "%02x".format(it.toInt() and 255) })
        return ControlTLSFrame(
            ControlTLSFrame.Kind.CONTROL,
            value.toString().toByteArray(Charsets.UTF_8),
        )
    }

    internal fun encode(): ByteArray {
        val id = metadata.phoneID.toByteArray(Charsets.UTF_8)
        val out = java.io.ByteArrayOutputStream()
        out.write(MAGIC)
        out.write(metadata.hostPin.chunked(2).map { it.toInt(16).toByte() }.toByteArray())
        out.write(id.size)
        out.write(id)
        for (value in listOf(metadata.epoch, metadata.expiresAt)) for (i in 0..7) out.write(
            (value ushr (i * 8)).toInt() and 255
        )
        out.write(secret)
        return out.toByteArray()
    }

    companion object {
        private val MAGIC = byteArrayOf(84, 72, 80, 67, 49, 0, 0, 0)

        internal fun pin(value: String) = value.matches(Regex("[0-9a-f]{64}"))

        internal fun decode(bytes: ByteArray): PhoneCredential {
            if (bytes.size !in 90..153 || !bytes.copyOfRange(0, 8).contentEquals(MAGIC))
                throw PhoneCredentialRejected()
            val count = bytes[40].toInt() and 255
            if (count !in 1..64 || bytes.size != 89 + count) throw PhoneCredentialRejected()
            fun number(offset: Int): Long {
                var value = 0L
                for (i in 0..7) value = value or ((bytes[offset + i].toLong() and 255) shl (i * 8))
                return value
            }
            val pin =
                bytes.copyOfRange(8, 40).joinToString("") { "%02x".format(it.toInt() and 255) }
            val id = bytes.copyOfRange(41, 41 + count).toString(Charsets.UTF_8)
            return PhoneCredential(
                PhoneCredentialMetadata(pin, id, number(41 + count), number(49 + count)),
                bytes.copyOfRange(57 + count, bytes.size),
            )
        }
    }
}

internal interface PhoneCredentialStorage {
    fun <T> transaction(action: () -> T): T

    fun read(pin: String): ByteArray?

    fun write(pin: String, bytes: ByteArray)

    fun remove(pin: String)
}

/** Synchronous native enrollment-worker API; never schedule storage on the UI/input thread. */
class PhoneCredentialVault internal constructor(private val storage: PhoneCredentialStorage) {
    @TargetApi(29) constructor(context: Context) : this(AndroidPhoneCredentialStorage(context))

    fun load(hostPin: String, now: Long): PhoneCredential? = storage.transaction {
        if (!PhoneCredential.pin(hostPin) || now < 0) throw PhoneCredentialRejected()
        val bytes = storage.read(hostPin) ?: return@transaction null
        val credential = PhoneCredential.decode(bytes)
        if (credential.metadata.hostPin != hostPin) throw PhoneCredentialRejected()
        if (now >= credential.metadata.expiresAt)
            throw PhoneCredentialRejected("phone_credential_expired")
        credential
    }

    /**
     * A caller may acknowledge enrollment only after a verified readback. Failures preserve
     * storage.
     */
    fun save(credential: PhoneCredential) = storage.transaction {
        val pin = credential.metadata.hostPin
        val bytes = credential.encode()
        val old = storage.read(pin)
        if (old != null) {
            val prior = PhoneCredential.decode(old)
            if (prior.metadata.hostPin != pin) throw PhoneCredentialRejected()
            if (prior.metadata.phoneID == credential.metadata.phoneID) {
                if (credential.metadata.epoch < prior.metadata.epoch)
                    throw PhoneCredentialRejected("phone_credential_rollback")
                if (credential.metadata.epoch == prior.metadata.epoch) {
                    if (!bytes.contentEquals(old))
                        throw PhoneCredentialRejected("phone_credential_rollback")
                    return@transaction
                }
            }
        }
        storage.write(pin, bytes)
        if (storage.read(pin)?.contentEquals(bytes) != true)
            throw PhoneCredentialRejected("phone_credential_unconfirmed")
    }

    fun forget(hostPin: String) = storage.transaction {
        if (!PhoneCredential.pin(hostPin)) throw PhoneCredentialRejected()
        storage.remove(hostPin)
    }
}

@TargetApi(29)
internal class AndroidPhoneCredentialStorage(context: Context) : PhoneCredentialStorage {
    private val root: File

    init {
        if (Build.VERSION.SDK_INT < 29)
            throw PhoneCredentialRejected("phone_credential_unavailable")
        val parent = context.noBackupFilesDir.canonicalFile
        root = File(parent, "rewrite-phone-trust-v1")
        if (!root.exists() && !root.mkdir())
            throw PhoneCredentialRejected("phone_credential_unavailable")
        if (
            !OsConstants.S_ISDIR(Os.lstat(root.path).st_mode) ||
                root.canonicalFile != root.absoluteFile
        )
            throw PhoneCredentialRejected("phone_credential_unavailable")
        Os.chmod(root.path, 448)
    }

    private fun regular(file: File) {
        val stat = Os.lstat(file.path)
        if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_nlink != 1L)
            throw PhoneCredentialRejected("phone_credential_unavailable")
        Os.chmod(file.path, 384)
    }

    override fun <T> transaction(action: () -> T): T {
        try {
            val lock = File(root, "vault.lock")
            if (lock.exists() || java.nio.file.Files.isSymbolicLink(lock.toPath())) regular(lock)
            return RandomAccessFile(lock, "rw").use { owner ->
                regular(lock)
                val lease =
                    owner.channel.tryLock()
                        ?: throw PhoneCredentialRejected("phone_credential_unavailable")
                lease.use { action() }
            }
        } catch (e: PhoneCredentialRejected) {
            throw e
        } catch (_: Exception) {
            throw PhoneCredentialRejected("phone_credential_unavailable")
        }
    }

    private fun record(pin: String): AtomicFile {
        if (!PhoneCredential.pin(pin)) throw PhoneCredentialRejected()
        val base = File(root, "$pin.enc")
        for (f in listOf(base, File(base.path + ".new"), File(base.path + ".bak"))) {
            if (f.exists() || java.nio.file.Files.isSymbolicLink(f.toPath())) regular(f)
        }
        return AtomicFile(base)
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(ALIAS))
            return store.getKey(ALIAS, null) as? SecretKey
                ?: throw PhoneCredentialRejected("phone_credential_unavailable")
        if (!create || root.listFiles()?.any { it.name != "vault.lock" } != false)
            throw PhoneCredentialRejected("phone_credential_unavailable")
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                            ALIAS,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                        .setKeySize(256)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setRandomizedEncryptionRequired(true)
                        .setUnlockedDeviceRequired(true)
                        .build()
                )
            }
            .generateKey()
    }

    override fun read(pin: String): ByteArray? {
        val file = record(pin)
        val encrypted =
            try {
                file.openRead().use { input ->
                    val buffer = ByteArray(183)
                    var count = 0
                    while (count < buffer.size) {
                        val size = input.read(buffer, count, buffer.size - count)
                        if (size < 0) break
                        if (size == 0) throw PhoneCredentialRejected()
                        count += size
                    }
                    if (count !in 119..182) throw PhoneCredentialRejected()
                    buffer.copyOf(count)
                }
            } catch (_: FileNotFoundException) {
                if (File(root, "$pin.enc").exists() || File(root, "$pin.enc.bak").exists())
                    throw PhoneCredentialRejected("phone_credential_unavailable")
                return null
            }
        return PhoneCredentialCipher.decrypt(pin, key(false), encrypted)
    }

    override fun write(pin: String, bytes: ByteArray) {
        val file = record(pin)
        val encrypted = PhoneCredentialCipher.encrypt(pin, key(true), bytes)
        val output = file.startWrite()
        try {
            output.write(encrypted)
            file.finishWrite(output)
            regular(File(root, "$pin.enc"))
        } catch (e: Exception) {
            file.failWrite(output)
            throw e
        }
    }

    override fun remove(pin: String) {
        record(pin).delete()
    }

    companion object {
        private const val ALIAS = PhoneCredentialCipher.namespace
    }
}

internal object PhoneCredentialCipher {
    const val namespace = "com.thumble.rewrite.phone-trust.v1"

    fun encrypt(pin: String, key: SecretKey, bytes: ByteArray): ByteArray {
        if (!PhoneCredential.pin(pin) || bytes.size !in 90..153) throw PhoneCredentialRejected()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD((namespace + "\u0000" + pin).toByteArray(Charsets.UTF_8))
        if (cipher.iv.size != 12) throw PhoneCredentialRejected()
        return byteArrayOf(1) + cipher.iv + cipher.doFinal(bytes)
    }

    fun decrypt(pin: String, key: SecretKey, bytes: ByteArray): ByteArray {
        if (!PhoneCredential.pin(pin) || bytes.size !in 119..182 || bytes[0] != 1.toByte())
            throw PhoneCredentialRejected()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        cipher.updateAAD((namespace + "\u0000" + pin).toByteArray(Charsets.UTF_8))
        return cipher.doFinal(bytes.copyOfRange(13, bytes.size))
    }
}
