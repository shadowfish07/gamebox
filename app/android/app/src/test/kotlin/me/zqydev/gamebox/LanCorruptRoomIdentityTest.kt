package me.zqydev.gamebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanCorruptRoomIdentityTest {
    @Test
    fun `extracts only identity from exact bounded manifest`() {
        assertEquals(
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            LanCorruptRoomIdentity.decode(validManifest().toByteArray()),
        )
    }

    @Test
    fun `rejects unknown fields oversize and noncanonical room identity`() {
        assertNull(LanCorruptRoomIdentity.decode(validManifest().replace("}", ",\"extra\":true}").toByteArray()))
        assertNull(LanCorruptRoomIdentity.decode(ByteArray(64 * 1024 + 1)))
        assertNull(
            LanCorruptRoomIdentity.decode(
                validManifest().replace(
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                    "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                ).toByteArray(),
            ),
        )
    }

    @Test
    fun `nofollow metadata rejects symlink fifo foreign owner and changed descriptor before read`() {
        var reads = 0
        val invalid = listOf(
            LanCorruptRoomIdentity.FileMetadata(regular = false, ownerMatches = true, size = 100, device = 1, inode = 1),
            LanCorruptRoomIdentity.FileMetadata(regular = false, ownerMatches = true, size = 100, device = 1, inode = 2),
            LanCorruptRoomIdentity.FileMetadata(regular = true, ownerMatches = false, size = 100, device = 1, inode = 3),
            LanCorruptRoomIdentity.FileMetadata(regular = true, ownerMatches = true, size = 100, device = 1, inode = 4),
        )
        invalid.take(3).forEach { metadata ->
            assertNull(
                LanCorruptRoomIdentity.readVerified(metadata) { _, _ ->
                    reads++
                    validManifest().toByteArray() to metadata
                },
            )
        }
        assertNull(
            LanCorruptRoomIdentity.readVerified(invalid.last()) { _, _ ->
                reads++
                validManifest().toByteArray() to invalid.last().copy(inode = 5)
            },
        )
        assertEquals(1, reads)
    }

    @Test
    fun `manifest endpoint and journal counters are validated but never returned as game state`() {
        val decoded = LanCorruptRoomIdentity.decode(validManifest().toByteArray())
        assertEquals("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", decoded)
        assertFalse(decoded!!.contains("50000"))
        assertTrue(decoded.length == 36)
        assertNull(LanCorruptRoomIdentity.decode(validManifest().replace("50000", "80").toByteArray()))
    }

    private fun validManifest() =
        "{\"schemaVersion\":1,\"roomId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"," +
            "\"gameId\":\"gomoku\",\"createdAt\":1000,\"endpoint\":\"0.0.0.0:50000\"," +
            "\"journalFormatVersion\":1,\"journalSequence\":1}"
}
