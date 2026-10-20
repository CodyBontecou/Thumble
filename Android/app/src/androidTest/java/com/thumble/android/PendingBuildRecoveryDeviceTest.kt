package com.thumble.android

import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class PendingBuildRecoveryDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun await(label: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (!predicate() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(20)
        if (!predicate()) {
            instrumentation.uiAutomation.takeScreenshot()?.let { bitmap ->
                File(instrumentation.targetContext.cacheDir, "recovery-ui-failure.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            val labels = mutableListOf<String>()
            fun visit(item: android.view.accessibility.AccessibilityNodeInfo) {
                if (labels.size > 40) return
                labels.add("${item.packageName}/${item.className}: ${item.text?.take(100)} [${item.contentDescription?.take(100)}]")
                repeat(item.childCount) { index -> item.getChild(index)?.let(::visit) }
            }
            instrumentation.uiAutomation.rootInActiveWindow?.let(::visit)
            fail(label + "\n" + labels.joinToString("\n"))
        }
    }
    @Test fun expiredInterruptedAndCorruptBuildsSurviveSessionStartupExportAndFailedWrites() {
        val context = instrumentation.targetContext
        val root = File(context.noBackupFilesDir, "recovery-test-${UUID.randomUUID()}").apply { mkdirs() }
        val id = UUID.randomUUID(); val orphan = UUID.randomUUID()
        val raw = instrumentation.context.assets.open("profile-artifact/v1.json").use { it.readBytes() }
        val artifact = File(root, "$id.artifact.json").apply { writeBytes(raw) }
        val metadata = File(root, "$id.metadata.json").apply { writeText("""{"expiresAt":0,"state":"ADOPTING","future":"keep exact bytes"}""") }
        val corrupt = File(root, "$orphan.artifact.json").apply { writeText("incomplete original") }
        val before = root.listFiles()!!.associate { it.name to it.readBytes().toList() }
        lateinit var session: SharedBuildSession
        instrumentation.runOnMainSync { session = SharedBuildSession(root.toPath()) }
        try {
            await("read-only recovery discovery") { session.records.size == 2 }
            val record = session.records.single { it.id == id }; assertTrue(record.profileFile)
            assertFalse(session.records.single { it.id == orphan }.profileFile)
            val output = ByteArrayOutputStream()
            instrumentation.runOnMainSync { session.documentExport = record; session.saveDocument { output } }
            await("profile exported") { !session.busy && output.size() == raw.size }
            assertArrayEquals(raw, output.toByteArray())
            instrumentation.runOnMainSync {
                session.documentExport = record
                session.saveDocument { object: java.io.OutputStream() { override fun write(value: Int) { throw java.io.IOException("fixture failure") } } }
            }
            await("export failure reported") { !session.busy && session.error != null }
            assertTrue(session.error!!.contains("original"))
            assertEquals(before, root.listFiles()!!.associate { it.name to it.readBytes().toList() })
            assertTrue(artifact.isFile); assertTrue(metadata.isFile); assertTrue(corrupt.isFile)
            val token = "fictional-retired-token"
            instrumentation.runOnMainSync {
                assertTrue(session.route("https://thumble-mcp-gateway.fly.dev/share/old#token=$token"))
                assertFalse(session.route("ws://192.0.2.1:9000"))
                assertFalse(session.error.orEmpty().contains(token))
                assertTrue(session.error.orEmpty().contains("retired"))
            }
            assertEquals(before, root.listFiles()!!.associate { it.name to it.readBytes().toList() })
        } finally { instrumentation.runOnMainSync { session.close() }; root.deleteRecursively() }
    }
    @Test fun recoveryIsReachableBeforePairingAndCancelingTheFilePickerKeepsOriginals() {
        val context = instrumentation.targetContext
        val root = File(context.noBackupFilesDir, "recovery-ui-${UUID.randomUUID()}").apply { mkdirs() }
        val id = UUID.randomUUID()
        val raw = instrumentation.context.assets.open("profile-artifact/v1.json").use { it.readBytes() }
        File(root, "$id.artifact.json").writeBytes(raw)
        val before = root.listFiles()!!.associate { it.name to it.readBytes().toList() }
        val oldStore = ClientDependencies.sessionStore; val oldRecovery = ClientDependencies.sharedBuildSession
        val memory = MemorySessionStore() // Deliberately has no pairing or completed onboarding.
        ClientDependencies.sessionStore = { memory }; ClientDependencies.sharedBuildSession = { SharedBuildSession(root.toPath()) }
        var scenario: androidx.test.core.app.ActivityScenario<MainActivity>? = null
        fun node(label: String): android.view.accessibility.AccessibilityNodeInfo? {
            fun walk(item: android.view.accessibility.AccessibilityNodeInfo): android.view.accessibility.AccessibilityNodeInfo? {
                if (item.isVisibleToUser && (item.text?.toString() == label || item.contentDescription?.toString() == label)) return item
                repeat(item.childCount) { index -> item.getChild(index)?.let { child -> walk(child)?.let { return it } } }
                return null
            }
            return instrumentation.uiAutomation.rootInActiveWindow?.let(::walk)
        }
        fun click(label: String) {
            await("visible $label") { node(label) != null }
            var item = node(label)!!
            while (!item.isClickable && item.parent != null) item = item.parent
            assertTrue(item.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
        }
        try {
            scenario = androidx.test.core.app.ActivityScenario.launch(android.content.Intent(context, MainActivity::class.java)
                .addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or android.content.Intent.FLAG_ACTIVITY_CLEAR_TASK))
            lateinit var owner: ControllerSession
            scenario.onActivity { owner = androidx.lifecycle.ViewModelProvider(it)[ControllerSession::class.java] }
            await("fixture recovery loaded; error=${owner.sharedBuilds.error}") { owner.sharedBuilds.records.size == 1 }
            assertEquals(id, owner.sharedBuilds.records.single().id)
            assertTrue(owner.state.snapshot.profiles.isEmpty()); assertFalse(owner.state.paired)
            click("Recover saved builds")
            await("local recovery actions") { node("Save profile file") != null }
            assertNull(node("Open link")); assertNull(node("Adopt on Mac")); assertNull(node("Preview & Keep"))
            scenario.recreate()
            click("Save profile file")
            await("system file picker") { instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString()?.contains("documentsui") == true }
            val automation = instrumentation.uiAutomation
            assertTrue(automation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK))
            automation.waitForIdle(200, 3_000)
            // API 26 focuses the filename and opens the IME; the first Back dismisses that IME.
            if (automation.rootInActiveWindow?.packageName?.toString()?.contains("documentsui") == true) {
                assertTrue(automation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK))
            }
            await("recovery after cancel") { node("Save profile file") != null }
            assertEquals(before, root.listFiles()!!.associate { it.name to it.readBytes().toList() })
            assertTrue(memory.loadSnapshot().profiles.isEmpty()); assertNull(memory.loadMac())
        } finally {
            scenario?.close(); ClientDependencies.sessionStore = oldStore; ClientDependencies.sharedBuildSession = oldRecovery
            root.deleteRecursively()
        }
    }
    @Test fun upgradedAppDoesNotRegisterTheRetiredHostedLinkActivity() {
        val context = instrumentation.targetContext
        assertThrows(PackageManager.NameNotFoundException::class.java) {
            @Suppress("DEPRECATION")
            context.packageManager.getActivityInfo(ComponentName(context.packageName, "com.thumble.android.SharedBuildLinkActivity"), 0)
        }
        val app = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_ACTIVITIES)
        assertFalse(app.activities.orEmpty().any { it.name.endsWith("SharedBuildLinkActivity") })
    }
}
