package me.zqydev.gamebox

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.system.Os
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runners.MethodSorters

@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class LanHostExternalSmokeTest {
    @Test
    fun external01PrepareRoom() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.POST_NOTIFICATIONS,
        )
        val commands = start(context)
        val created = commands.createRoom("Host")
        val roomId = created["roomId"] as String
        val port = created["port"] as Int
        val secrets = requireNotNull(LanSecretStore(context).load())
        val directory = File(context.filesDir, "lan-test")
        check(directory.mkdirs() || directory.isDirectory)
        val handoff = File(directory, "handoff.json")
        handoff.writeText(
            JSONObject()
                .put("roomId", roomId)
                .put("nickname", "Guest")
                .put("joinAttemptId", UUID.randomUUID().toString())
                .put("candidateResumeToken", canonicalToken())
                .put("roomKey", secrets.roomKey)
                .toString(),
        )
        Os.chmod(handoff.path, 0x180)
        val status = File(directory, "status.json")
        status.writeText(
            JSONObject()
                .put("schemaVersion", 1)
                .put("roomId", roomId)
                .put("port", port)
                .put("revision", 0)
                .put("state", "waiting")
                .toString(),
        )
        Os.chmod(status.path, 0x180)
        waitUntil {
            context.getSystemService(NotificationManager::class.java)
                .activeNotifications.any { it.id == LanHostService.NOTIFICATION_ID }
        }
        Log.i("LanHostExternalSmoke", "LAN_EXTERNAL_READY roomId=$roomId revision=0 state=waiting")
    }

    @Test
    fun external02CleanupRoom() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.filesDir, "lan-test")
        val handoff = File(directory, "handoff.json")
        val status = File(directory, "status.json")
        assertTrue(handoff.delete() || !handoff.exists())
        assertTrue(status.delete() || !status.exists())
        val commands = start(context)
        val before = commands.getStatus()
        assertEquals(0L, before["gameRevision"])
        val roomId = before["roomId"] as String
        commands.closeRoom("cancel")
        waitUntil {
            context.getSystemService(NotificationManager::class.java)
                .activeNotifications.none { it.id == LanHostService.NOTIFICATION_ID }
        }
        assertFalse(handoff.exists())
        assertFalse(status.exists())
        Log.i("LanHostExternalSmoke", "LAN_EXTERNAL_CLEAN roomId=$roomId revision=0 state=cancelled")
    }

    private fun start(context: Context): LanHostCommands {
        LanHostService.serviceReady.prepareStart()
        ContextCompat.startForegroundService(context, LanHostService.commandIntent(context))
        return requireNotNull(LanHostService.serviceReady.await(10_000))
    }

    private fun canonicalToken(): String = Base64.encodeToString(
        ByteArray(32).also(SecureRandom()::nextBytes),
        Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING,
    )

    private fun waitUntil(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!predicate() && System.nanoTime() < deadline) Thread.yield()
        assertTrue(predicate())
    }
}
