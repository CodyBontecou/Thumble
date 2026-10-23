package com.thumble.rewrite.input

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic journal only; touches one random host scope in the test app's no-backup directory. */
@RunWith(AndroidJUnit4::class)
class EditorJournalDeviceTest {
    private fun rejected(code: EditorJournalException.Code, action: () -> Unit) {
        try {
            action()
            fail("expected_editor_journal_rejection")
        } catch (error: EditorJournalException) {
            assertEquals(code, error.code)
        }
    }

    private fun assertLockCloseOnExec(lock: File) {
        val descriptors =
            File("/proc/self/fd").listFiles() ?: error("editor_fd_inventory_unavailable")
        assertTrue(descriptors.size <= 256)
        val found = descriptors.filter {
            it.name.all(Char::isDigit) &&
                runCatching { Os.readlink(it.path) == lock.path }.getOrDefault(false)
        }
        assertEquals(1, found.size)
        val info = File("/proc/self/fdinfo/${found.single().name}")
        val text =
            info.inputStream().use { stream ->
                val bytes = ByteArray(4097)
                val count = stream.read(bytes)
                assertTrue(count in 1..4096)
                String(bytes, 0, count, Charsets.US_ASCII)
            }
        val flags =
            text
                .lineSequence()
                .single { it.startsWith("flags:") }
                .substringAfter(':')
                .trim()
                .toLong(8)
        assertTrue(flags and 0x80000L != 0L)
    }

    @Test
    fun actualAtomicFileReopenFaultsCorruptionAndAliases() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val pin = UUID.randomUUID().toString().replace("-", "").repeat(2)
        val scope = EditorHostScope(pin, "11111111-1111-1111-1111-111111111111")
        val root = File(context.noBackupFilesDir.canonicalFile, "rewrite-editor-journal-v1")
        fun intent(op: String) =
            EditorLabelIntent(
                scope,
                op,
                "7",
                "aaaaaaaa-0000-0000-0000-000000000001",
                "ce000000-0000-0000-0000-000000000001",
                "Synthetic",
            )
        val file = File(root, "$pin.json")
        val owned =
            listOf(
                file,
                File(root, "$pin.json.new"),
                File(root, "$pin.json.bak"),
                File(root, "$pin.lock"),
            )
        try {
            val store = EditorJournalFileStore(context, pin)
            val first = EditorJournal(pin, store)
            val stale = EditorJournal(pin, EditorJournalFileStore(context, pin))
            first.enqueue(intent("first"))
            assertEquals(
                first.snapshot(),
                EditorJournal(pin, EditorJournalFileStore(context, pin)).snapshot(),
            )
            assertEquals(384, Os.lstat(file.path).st_mode and 511)
            rejected(EditorJournalException.Code.CHANGED_ON_DISK) { stale.enqueue(intent("stale")) }
            val before = file.readBytes()
            val beforeJournal =
                EditorJournal(
                    pin,
                    EditorJournalFileStore(context, pin) {
                        if (it == EditorJournalFileStore.FaultPoint.BEFORE_REPLACE) {
                            assertLockCloseOnExec(File(root, "$pin.lock"))
                            throw IllegalStateException("synthetic")
                        }
                    },
                )
            rejected(EditorJournalException.Code.UNAVAILABLE) {
                beforeJournal.enqueue(intent("before"))
            }
            assertArrayEquals(before, file.readBytes())
            assertEquals(1, beforeJournal.snapshot().entries.size)
            val uncertain =
                EditorJournal(
                    pin,
                    EditorJournalFileStore(context, pin) {
                        if (it == EditorJournalFileStore.FaultPoint.AFTER_REPLACE)
                            throw IllegalStateException("synthetic")
                    },
                )
            rejected(EditorJournalException.Code.UNCERTAIN) { uncertain.enqueue(intent("after")) }
            assertTrue(uncertain.requiresReopen())
            assertEquals("after", uncertain.recoveryOperationID())
            assertEquals(1, uncertain.snapshot().entries.size)
            rejected(EditorJournalException.Code.UNCERTAIN) { uncertain.enqueue(intent("another")) }
            assertEquals(
                listOf("first", "after"),
                EditorJournal(pin, EditorJournalFileStore(context, pin)).snapshot().entries.map {
                    it.intent.operationID
                },
            )
            val stage = File(root, "$pin.json.new")
            Os.symlink(file.path, stage.path)
            rejected(EditorJournalException.Code.UNAVAILABLE) {
                EditorJournal(pin, EditorJournalFileStore(context, pin))
            }
            assertTrue(stage.delete())
            file.writeText("corrupt")
            rejected(EditorJournalException.Code.INVALID) {
                EditorJournal(pin, EditorJournalFileStore(context, pin))
            }
            assertEquals("corrupt", file.readText())
        } finally {
            for (entry in owned) entry.delete()
        }
    }
}
