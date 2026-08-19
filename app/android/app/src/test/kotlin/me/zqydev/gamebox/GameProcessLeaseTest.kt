package me.zqydev.gamebox

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class GameProcessLeaseTest {
    @Test
    fun `held lease rejects same process overlap and close permits reacquisition`() {
        val directory = Files.createTempDirectory("gamebox-game-lease").toFile()
        val lockFile = directory.resolve("active.lock")

        val lease = GameProcessLease.acquire(lockFile)
        try {
            assertTrue(GameProcessLease.isHeld(lockFile))
            assertTrue(GameProcessLease.isHeld(lockFile))
            assertThrows(java.io.IOException::class.java) {
                GameProcessLease.acquire(lockFile)
            }
        } finally {
            lease.close()
        }

        assertFalse(GameProcessLease.isHeld(lockFile))
        assertTrue(lockFile.isFile)
        GameProcessLease.acquire(lockFile).close()
        assertFalse(GameProcessLease.isHeld(lockFile))
        directory.deleteRecursively()
    }

    @Test
    fun `lock file is scoped under the supplied private directory`() {
        val directory = Files.createTempDirectory("gamebox-private-dir").toFile()

        assertEquals(directory.resolve("active-game.lock"), GameProcessLease.lockFile(directory))

        directory.deleteRecursively()
    }
}
