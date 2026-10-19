package com.thumble.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** No generated toString/copy/component methods that can accidentally expose a bearer token. */
internal class TrustedMac(val serverID: String, val authToken: String, val urls: List<String>) {
    init {
        require(serverID.isNotBlank() && serverID.length <= 512)
        require(authToken.isNotBlank() && authToken.length <= 4096)
        require(urls.size in 1..16)
        urls.forEach { PairingTarget.validateURL(it) }
    }
    fun target() = PairingTarget(urls, null, serverID)
    override fun toString() = "TrustedMac([redacted])"
}

internal data class ClientPreferences(val practiceMode: Boolean = false, val hapticIntensity: Double = 1.0) {
    fun normalized() = copy(hapticIntensity=HapticIntensity.normalized(hapticIntensity))
    fun json() = JSONObject().put("practiceMode",practiceMode).put("hapticIntensity",HapticIntensity.normalized(hapticIntensity))
    companion object {
        fun parse(json: JSONObject) = ClientPreferences(json.optBoolean("practiceMode"),
            HapticIntensity.normalized(json.optDouble("hapticIntensity",1.0)))
    }
}

internal interface SessionStore {
    fun loadMac(): TrustedMac?
    fun saveMac(mac: TrustedMac)
    fun forgetMac()
    fun loadSnapshot(): ProfileSnapshot
    fun saveSnapshot(snapshot: ProfileSnapshot)
    fun loadPendingSkinSelections(): List<PendingSkinSelection> = emptyList()
    fun saveSkinState(snapshot: ProfileSnapshot, pending: List<PendingSkinSelection>) {
        check(pending.isEmpty()) { "This profile store cannot persist pending skin changes" }
        saveSnapshot(snapshot)
    }
    fun loadPreferences(): ClientPreferences = ClientPreferences()
    fun savePreferences(preferences: ClientPreferences) {}
}

internal class MemorySessionStore : SessionStore {
    private var mac: TrustedMac? = null
    private var snapshot = ProfileSnapshot()
    private var preferences = ClientPreferences()
    private var pendingSkins = emptyList<PendingSkinSelection>()
    override fun loadMac() = mac
    override fun saveMac(mac: TrustedMac) { this.mac = mac }
    override fun forgetMac() { mac = null; snapshot = ProfileSnapshot(); pendingSkins = emptyList() }
    override fun loadSnapshot() = snapshot
    override fun saveSnapshot(snapshot: ProfileSnapshot) { this.snapshot = snapshot }
    override fun loadPendingSkinSelections() = pendingSkins
    override fun saveSkinState(snapshot: ProfileSnapshot, pending: List<PendingSkinSelection>) {
        this.snapshot=snapshot;pendingSkins=pending.toList()
    }
    override fun loadPreferences() = preferences
    override fun savePreferences(preferences: ClientPreferences) { this.preferences = preferences }
}

/** Used only on the client's transport queue. All files are private and excluded from backup. */
internal class AndroidSessionStore(context: Context, namespace: String = "session") : SessionStore {
    private val directory = File(context.noBackupFilesDir, namespace).apply { mkdirs() }
    private val credential = AtomicFile(File(directory, "trusted-mac.enc"))
    private val profiles = AtomicFile(File(directory, "profiles.json"))
    private val settings = AtomicFile(File(directory, "preferences.json"))
    private val alias = "com.thumble.android.$namespace.v1"
    private val associatedData = "Thumble trusted Mac v1".toByteArray()

    override fun loadMac(): TrustedMac? = try {
        val bytes = credential.readFully()
        require(bytes.size in 30..65_536 && bytes[0] == 1.toByte())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
        cipher.updateAAD(associatedData)
        val json = JSONObject(cipher.doFinal(bytes.copyOfRange(13, bytes.size)).toString(Charsets.UTF_8))
        val urls = json.getJSONArray("urls")
        TrustedMac(json.getString("serverID"), json.getString("authToken"),
            (0 until urls.length()).map { urls.getString(it) })
    } catch (_: Exception) {
        // Missing/invalidated keys, tampering, and corrupt records require a fresh pairing.
        eraseCredential()
        null
    }

    override fun saveMac(mac: TrustedMac) {
        val json = JSONObject().put("serverID", mac.serverID).put("authToken", mac.authToken)
            .put("urls", JSONArray(mac.urls)).toString().toByteArray()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        cipher.updateAAD(associatedData)
        require(cipher.iv.size == 12)
        write(credential, byteArrayOf(1) + cipher.iv + cipher.doFinal(json))
    }

    override fun forgetMac() { eraseCredential(); profiles.delete() }
    private fun eraseCredential() {
        credential.delete()
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias) }
    }
    override fun loadSnapshot(): ProfileSnapshot = try {
        val bytes = profiles.readFully()
        require(bytes.size <= WireCodec.MAX_PAYLOAD)
        ProfileSnapshot().applying(JSONObject(bytes.toString(Charsets.UTF_8)))
    } catch (_: Exception) { ProfileSnapshot() }

    override fun loadPendingSkinSelections(): List<PendingSkinSelection> {
        val bytes=try { profiles.readFully() } catch (_: java.io.FileNotFoundException) { return emptyList() }
        require(bytes.size<=WireCodec.MAX_PAYLOAD)
        val json=JSONObject(bytes.toString(Charsets.UTF_8))
        return SkinSelectionJournal.decode(if(json.has("androidPendingSkinSelections")) json.getJSONArray("androidPendingSkinSelections") else null)
    }
    override fun saveSnapshot(snapshot: ProfileSnapshot) = saveSkinState(snapshot,loadPendingSkinSelections())
    override fun saveSkinState(snapshot: ProfileSnapshot, pending: List<PendingSkinSelection>) {
        require(pending.size<=256)
        val json = WireCodec.message("gamepad_profiles").put("gamepadProfiles", JSONArray().apply {
            snapshot.profiles.forEach { put(it.source) }
        }).put("gamepadProfileID", snapshot.selectedID?.toString())
            .put("defaultGamepadProfileID",snapshot.defaultID?.toString())
            .put("androidPendingSkinSelections",SkinSelectionJournal.encode(pending)).toString().toByteArray()
        require(json.size <= WireCodec.MAX_PAYLOAD)
        write(profiles, json)
    }

    override fun loadPreferences(): ClientPreferences = try {
        val bytes = settings.readFully()
        require(bytes.size <= 16_384)
        ClientPreferences.parse(JSONObject(bytes.toString(Charsets.UTF_8)))
    } catch (_: Exception) { ClientPreferences() }

    override fun savePreferences(preferences: ClientPreferences) {
        write(settings, preferences.json().toString().toByteArray())
    }

    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "Pairing key unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }

    private fun write(file: AtomicFile, bytes: ByteArray) {
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) }
        catch (error: Exception) { file.failWrite(stream); throw error }
    }
}

/** Ordinary dependency seam; instrumentation can keep fixture sessions out of real saved trust. */
internal object ClientDependencies {
    var sessionStore: (Context) -> SessionStore = { AndroidSessionStore(it) }
}
