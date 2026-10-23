package com.thumble.rewrite.input

import android.content.Context
import android.system.Os
import android.system.OsConstants
import android.util.AtomicFile
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream

/**
 * Private native store. Production paths are fixed beneath noBackupFilesDir. No vault key/token.
 */
class EditorJournalFileStore
private constructor(
    private val root: File,
    private val pin: String,
    private val fault: ((FaultPoint) -> Unit)?,
) : EditorJournalStorage {
    internal enum class FaultPoint {
        BEFORE_REPLACE,
        AFTER_REPLACE,
    }

    constructor(
        context: Context,
        certificateSHA256: String,
    ) : this(prepare(context), certificateSHA256, null)

    internal constructor(
        context: Context,
        certificateSHA256: String,
        fault: (FaultPoint) -> Unit,
    ) : this(prepare(context), certificateSHA256, fault)

    init {
        checkEditor(EditorJournalCodec.hash(pin))
    }

    private val base = File(root, "$pin.json")
    private val atomic = AtomicFile(base)

    private fun regular(file: File, empty: Boolean = false) {
        val stat = Os.lstat(file.path)
        if (
            !OsConstants.S_ISREG(stat.st_mode) ||
                stat.st_nlink != 1L ||
                stat.st_uid != Os.getuid() ||
                (stat.st_mode and 63) != 0 ||
                stat.st_size < (if (empty) 0 else 1) ||
                stat.st_size > EditorJournalCodec.MAXIMUM_BYTES
        )
            throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
    }

    private fun exists(file: File): Boolean =
        java.nio.file.Files.exists(file.toPath(), java.nio.file.LinkOption.NOFOLLOW_LINKS)

    private fun validateFiles() {
        for (file in listOf(base, File(base.path + ".new"), File(base.path + ".bak"))) if (
            exists(file)
        )
            regular(file, empty = true)
    }

    private fun <T> locked(action: () -> T): T {
        try {
            val directory = Os.lstat(root.path)
            if (
                !OsConstants.S_ISDIR(directory.st_mode) ||
                    directory.st_uid != Os.getuid() ||
                    (directory.st_mode and 63) != 0 ||
                    root.canonicalFile != root.absoluteFile
            )
                throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
            val lock = File(root, "$pin.lock")
            if (exists(lock)) regular(lock, empty = true)
            val fd =
                Os.open(
                    lock.path,
                    OsConstants.O_RDWR or
                        OsConstants.O_CREAT or
                        OsConstants.O_NOFOLLOW or
                        ANDROID_O_CLOEXEC,
                    384,
                )
            try {
                FileOutputStream(fd).use { owner ->
                    regular(lock, empty = true)
                    val held =
                        owner.channel.tryLock()
                            ?: throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
                    held.use {
                        validateFiles()
                        return action()
                    }
                }
            } finally {
                // Android FileOutputStream(FileDescriptor) does not own/close the supplied FD.
                // Locks and channel have already closed; cleanup must not rewrite commit evidence.
                try {
                    Os.close(fd)
                } catch (_: Exception) {}
            }
        } catch (error: EditorJournalException) {
            throw error
        } catch (_: Exception) {
            throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
        }
    }

    private fun readDisk(): ByteArray? {
        val bytes =
            try {
                atomic.openRead().use { stream ->
                    val out = ByteArrayOutputStream()
                    val buffer = ByteArray(16384)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        if (count == 0 || out.size() + count > EditorJournalCodec.MAXIMUM_BYTES)
                            throw EditorJournalException(EditorJournalException.Code.INVALID)
                        out.write(buffer, 0, count)
                    }
                    out.toByteArray()
                }
            } catch (_: FileNotFoundException) {
                if (exists(base) || exists(File(base.path + ".bak")))
                    throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
                return null
            }
        checkEditor(EditorJournalCodec.decode(bytes).certificateSHA256 == pin)
        return bytes
    }

    @Synchronized override fun load(): ByteArray? = locked { readDisk() }

    @Synchronized
    override fun save(candidate: ByteArray, expected: ByteArray?) {
        val owned = candidate.copyOf()
        checkEditor(EditorJournalCodec.decode(owned).certificateSHA256 == pin)
        locked {
            val current = readDisk()
            if (!(current?.contentEquals(expected ?: byteArrayOf()) ?: (expected == null)))
                throw EditorJournalException(EditorJournalException.Code.CHANGED_ON_DISK)
            var output: FileOutputStream? = null
            var replacing = false
            try {
                output = atomic.startWrite()
                // AtomicFile uses .new on current OSes and .bak recovery on older ones.
                validateFiles()
                output.write(owned)
                output.fd.sync()
                fault?.invoke(FaultPoint.BEFORE_REPLACE)
                replacing = true
                atomic.finishWrite(output)
                output = null
                fault?.invoke(FaultPoint.AFTER_REPLACE)
                val directory =
                    Os.open(
                        root.path,
                        OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or ANDROID_O_CLOEXEC,
                        0,
                    )
                try {
                    if (!OsConstants.S_ISDIR(Os.fstat(directory).st_mode))
                        throw EditorJournalException(EditorJournalException.Code.UNCERTAIN)
                    Os.fsync(directory)
                } finally {
                    Os.close(directory)
                }
                val observed = readDisk()
                if (observed?.contentEquals(owned) != true) {
                    if (observed?.contentEquals(expected ?: byteArrayOf()) ?: (expected == null)) {
                        replacing = false
                        throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
                    }
                    throw EditorJournalException(EditorJournalException.Code.UNCERTAIN)
                }
            } catch (error: Exception) {
                if (!replacing) {
                    try {
                        output?.let { atomic.failWrite(it) }
                        val restored = readDisk()
                        if (
                            !(restored?.contentEquals(expected ?: byteArrayOf())
                                ?: (expected == null))
                        )
                            throw EditorJournalException(EditorJournalException.Code.UNCERTAIN)
                    } catch (_: Exception) {
                        throw EditorJournalException(EditorJournalException.Code.UNCERTAIN)
                    }
                    throw if (error is EditorJournalException) error
                    else EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
                }
                // finishWrite may have replaced before a later fsync/readback failed.
                throw EditorJournalException(EditorJournalException.Code.UNCERTAIN)
            }
        }
    }

    companion object {
        // Public Android 8.0 NDK asm-generic/fcntl.h: O_CLOEXEC 02000000.
        // https://android.googlesource.com/platform/bionic/+/android-8.0.0_r1/libc/kernel/uapi/asm-generic/fcntl.h
        // The kernel flag works with public Os.open on API 26; the Java field starts at API 27.
        private const val ANDROID_O_CLOEXEC = 0x80000

        private fun prepare(context: Context): File {
            try {
                val parent = context.noBackupFilesDir.canonicalFile
                val directory = File(parent, "rewrite-editor-journal-v1")
                val present =
                    java.nio.file.Files.exists(
                        directory.toPath(),
                        java.nio.file.LinkOption.NOFOLLOW_LINKS,
                    )
                if (!present) {
                    if (!directory.mkdir())
                        throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
                    Os.chmod(directory.path, 448)
                }
                val stat = Os.lstat(directory.path)
                if (
                    !OsConstants.S_ISDIR(stat.st_mode) ||
                        stat.st_uid != Os.getuid() ||
                        (stat.st_mode and 63) != 0 ||
                        directory.canonicalFile != directory.absoluteFile
                )
                    throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
                return directory
            } catch (error: EditorJournalException) {
                throw error
            } catch (_: Exception) {
                throw EditorJournalException(EditorJournalException.Code.UNAVAILABLE)
            }
        }
    }
}
