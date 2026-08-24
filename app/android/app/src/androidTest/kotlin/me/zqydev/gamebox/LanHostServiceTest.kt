package me.zqydev.gamebox

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.system.Os
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanHostServiceTest {
    @Test
    fun foregroundPrecedesRealRoomAndExplicitRevisionZeroCancelRemovesNotification() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.POST_NOTIFICATIONS,
        )
        val barrier = LanHostService.serviceReady
        barrier.prepareStart()
        ContextCompat.startForegroundService(context, LanHostService.commandIntent(context))
        val commands = barrier.await(10_000)
        assertNotNull(commands)
        waitUntil { notificationPresent(context.getSystemService(NotificationManager::class.java)) }

        val created = commands!!.createRoom("Host")
        assertEquals("waiting", created["state"])
        assertEquals(0L, created["gameRevision"])
        val cancelled = commands.closeRoom("cancel")
        assertEquals("cancelled", cancelled["state"])
        waitUntil { !notificationPresent(context.getSystemService(NotificationManager::class.java)) }
    }

    @Test
    fun encryptedBundleCorruptionUsesStrictManifestIdentityThenExplicitlyDiscards() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val commands = start(context)
        val roomId = commands.createRoom("Host")["roomId"]
        stopForRecovery(context, commands)
        secretFile(context).writeBytes(byteArrayOf(1, 2, 3))

        val recovered = start(context)
        val corrupt = recovered.getStatus()
        assertEquals("corrupt", corrupt["state"])
        assertEquals(roomId, corrupt["roomId"])
        assertFalse(notificationPresent(context.getSystemService(NotificationManager::class.java)))
        assertEquals("corrupt", recovered.closeRoom("discard_corrupt")["state"])
        assertFalse(secretFile(context).exists())
        assertFalse(activeRoom(context).exists())
    }

    @Test
    fun untrustedBundleAndManifestFailClosedButExplicitDiscardReturnsExactEmpty() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val commands = start(context)
        commands.createRoom("Host")
        stopForRecovery(context, commands)
        secretFile(context).writeBytes(byteArrayOf(1, 2, 3))
        File(activeRoom(context), "manifest.json").writeText("{\"schemaVersion\":1,\"extra\":true}")

        val recovered = start(context)
        val failure = assertThrows(LanEngineException::class.java) { recovered.getStatus() }
        assertEquals("internal_error", failure.code)
        assertFalse(notificationPresent(context.getSystemService(NotificationManager::class.java)))
        assertEquals(
            linkedMapOf<String, Any?>(
                "schemaVersion" to 1,
                "state" to "empty",
                "roomId" to null,
                "port" to 0,
                "gameRevision" to 0L,
                "endpointChanged" to false,
                "endpoint" to null,
            ),
            recovered.closeRoom("discard_corrupt"),
        )
        assertFalse(secretFile(context).exists())
        assertFalse(activeRoom(context).exists())
    }

    @Test
    fun hostileActiveRoomEntryMakesDiscardFailClosedAndRetainsSecretBundle() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val commands = start(context)
        commands.createRoom("Host")
        stopForRecovery(context, commands)
        val activeRoom = activeRoom(context)
        val manifest = File(activeRoom, "manifest.json")
        val journal = requireNotNull(
            activeRoom.listFiles()?.singleOrNull { it.name.matches(Regex("[0-9]{16}\\.json")) },
        )
        val manifestBytes = manifest.readBytes()
        val journalBytes = journal.readBytes()
        secretFile(context).writeBytes(byteArrayOf(1, 2, 3))
        val hostile = File(activeRoom, "hostile-fifo")
        Os.mkfifo(hostile.path, 0x180)

        val recovered = start(context)
        val failure = assertThrows(LanEngineException::class.java) {
            recovered.closeRoom("discard_corrupt")
        }
        assertEquals("internal_error", failure.code)
        assertTrue(secretFile(context).exists())
        assertTrue(hostile.exists())
        assertTrue(manifestBytes.contentEquals(manifest.readBytes()))
        assertTrue(journalBytes.contentEquals(journal.readBytes()))

        Os.remove(hostile.path)
        recovered.closeRoom("discard_corrupt")
        assertFalse(secretFile(context).exists())
        assertFalse(activeRoom(context).exists())
    }

    private fun start(context: Context): LanHostCommands {
        LanHostService.serviceReady.prepareStart()
        ContextCompat.startForegroundService(context, LanHostService.commandIntent(context))
        return requireNotNull(LanHostService.serviceReady.await(10_000))
    }

    private fun stopForRecovery(context: Context, commands: LanHostCommands) {
        assertTrue(context.stopService(Intent(context, LanHostService::class.java)))
        waitUntil { LanHostService.serviceReady.current() !== commands }
    }

    private fun secretFile(context: Context) = File(context.noBackupFilesDir, "lan_host/room-secrets.bin")

    private fun activeRoom(context: Context) = File(context.noBackupFilesDir, "lan_host_engine/active_room")

    private fun notificationPresent(manager: NotificationManager): Boolean =
        manager.activeNotifications.any { it.id == LanHostService.NOTIFICATION_ID }

    private fun waitUntil(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!predicate() && System.nanoTime() < deadline) Thread.yield()
        assertTrue(predicate())
    }
}
