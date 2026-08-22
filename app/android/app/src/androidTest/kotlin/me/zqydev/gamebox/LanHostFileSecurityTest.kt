package me.zqydev.gamebox

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanHostFileSecurityTest {
    @Test
    fun corruptIdentityReaderRejectsRealSymlinkAndFifoWithoutBlocking() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "lan-file-security-${UUID.randomUUID()}")
        assertTrue(directory.mkdir())
        val real = File(directory, "manifest-real.json")
        real.writeText(validManifest())
        val link = File(directory, "manifest-link.json")
        val fifo = File(directory, "manifest-fifo.json")
        Os.symlink(real.path, link.path)
        Os.mkfifo(fifo.path, 0x180)
        try {
            assertEquals(
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                LanCorruptRoomIdentity.read(real),
            )
            assertNull(LanCorruptRoomIdentity.read(link))
            val started = System.nanoTime()
            assertNull(LanCorruptRoomIdentity.read(fifo))
            assertTrue(
                "FIFO read blocked",
                System.nanoTime() - started < TimeUnit.SECONDS.toNanos(1),
            )
        } finally {
            runCatching { Os.remove(link.path) }
            runCatching { Os.remove(fifo.path) }
            real.delete()
            directory.delete()
        }
    }

    @Test
    fun secretStoreRejectsLinksAndFifoAndNeverFollowsBrokenStagingLink() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = LanSecretStore(context)
        runCatching { store.delete() }
        val root = File(context.noBackupFilesDir.canonicalFile, "lan_host")
        assertTrue(root.isDirectory || root.mkdir())
        val target = File(root, "room-secrets.bin")
        val legacyTemporary = File(root, "room-secrets.bin.tmp")
        val outside = File(context.cacheDir, "lan-secret-outside-${UUID.randomUUID()}")
        val missingOutside = File(context.cacheDir, "lan-secret-missing-${UUID.randomUUID()}")
        outside.writeText("outside-canary")
        try {
            Os.symlink(outside.path, target.path)
            assertThrows(IllegalStateException::class.java) { store.load() }
            assertThrows(IllegalStateException::class.java) { store.hasStoredBlob() }
            assertThrows(IllegalStateException::class.java) { store.delete() }
            assertEquals("outside-canary", outside.readText())
            Os.remove(target.path)

            Os.symlink(missingOutside.path, target.path)
            assertThrows(IllegalStateException::class.java) { store.load() }
            assertThrows(IllegalStateException::class.java) { store.hasStoredBlob() }
            Os.remove(target.path)

            Os.mkfifo(target.path, 0x180)
            val started = System.nanoTime()
            assertThrows(IllegalStateException::class.java) { store.load() }
            assertThrows(IllegalStateException::class.java) { store.hasStoredBlob() }
            assertTrue(
                "secret FIFO check blocked",
                System.nanoTime() - started < TimeUnit.SECONDS.toNanos(1),
            )
            Os.remove(target.path)

            Os.symlink(missingOutside.path, legacyTemporary.path)
            val secrets = fixtureSecrets()
            assertThrows(IllegalStateException::class.java) { store.save(secrets) }
            assertFalse(missingOutside.exists())
            Os.remove(legacyTemporary.path)
            store.save(secrets)
            assertEquals(secrets, store.load())
            assertFalse(missingOutside.exists())
            store.delete()
        } finally {
            runCatching { Os.remove(target.path) }
            runCatching { Os.remove(legacyTemporary.path) }
            runCatching { Os.remove(missingOutside.path) }
            outside.delete()
        }
    }

    private fun validManifest(): String =
        "{\"schemaVersion\":1,\"roomId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"," +
            "\"gameId\":\"gomoku\",\"createdAt\":1,\"endpoint\":\"0.0.0.0:50000\"," +
            "\"journalFormatVersion\":1,\"journalSequence\":1}"

    private fun fixtureSecrets() = LanRoomSecrets(
        schemaVersion = 1,
        roomId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        roomKey = "room-key-canary-that-must-never-appear-plain",
        tokenPepper = "token-pepper-canary-that-must-never-appear-plain",
        hostPlayerId = "11111111-1111-4111-8111-111111111111",
        hostResumeToken = "host-resume-canary-that-must-never-appear-plain",
    )
}
