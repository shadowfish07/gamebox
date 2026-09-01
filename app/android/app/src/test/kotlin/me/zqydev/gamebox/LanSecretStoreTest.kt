package me.zqydev.gamebox

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.BasicFileAttributes
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LanSecretStoreTest {
    @Test
    fun `generated bundle contains exactly durable room authority`() {
        val generator = LanRoomSecretsGenerator(CountingEntropy())

        val secrets = generator.generate()

        UUID.fromString(secrets.roomId)
        UUID.fromString(secrets.hostPlayerId)
        assertEquals(43, secrets.roomKey.length)
        assertEquals(43, secrets.tokenPepper.length)
        assertEquals(43, secrets.hostResumeToken.length)
        assertEquals(128, (generator.entropy as CountingEntropy).bytesRequested)
        assertFalse(secrets.toString().contains(secrets.roomKey))
        assertFalse(secrets.toString().contains(secrets.tokenPepper))
        assertFalse(secrets.toString().contains(secrets.hostResumeToken))
    }

    @Test
    fun `encrypted bundle round trips through bounded atomic file`() {
        val root = Files.createTempDirectory("lan-room-store").toFile()
        val cipher = PrefixCipher()
        val store = testStore(root, cipher)
        val secrets = fixtureSecrets()

        store.save(secrets)

        assertEquals(secrets, store.load())
        assertTrue(File(root, "room-secrets.bin").isFile)
        assertFalse(File(root, "room-secrets.bin.tmp").exists())
        assertFalse(File(root, "room-secrets.bin").readText().contains(secrets.roomKey))
        assertFalse(store.toString().contains(secrets.roomKey))
    }

    @Test
    fun `strict decoder rejects trailing fields truncation and oversized blob`() {
        val root = Files.createTempDirectory("lan-room-store-invalid").toFile()
        val cipher = PrefixCipher()
        val store = testStore(root, cipher)
        val target = File(root, "room-secrets.bin")
        store.save(fixtureSecrets())

        target.appendBytes(byteArrayOf(0x01))
        assertThrows(IllegalStateException::class.java) { store.load() }

        target.writeBytes(ByteArray(64 * 1024 + 1))
        assertThrows(IllegalStateException::class.java) { store.load() }
    }

    @Test
    fun `definitive create rejection deletes only the matching unused bundle`() {
        val root = Files.createTempDirectory("lan-room-store-delete").toFile()
        val store = testStore(root, PrefixCipher())
        val first = fixtureSecrets()
        val replacement = first.copy(roomId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")

        store.save(replacement)
        assertFalse(store.deleteIfMatches(first))
        assertEquals(replacement, store.load())
        assertTrue(store.deleteIfMatches(replacement))
        assertNull(store.load())
    }

    @Test
    fun `save never overwrites a different recoverable authority bundle`() {
        val root = Files.createTempDirectory("lan-room-store-preserve").toFile()
        val store = testStore(root, PrefixCipher())
        val existing = fixtureSecrets()
        val replacement = existing.copy(roomId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        store.save(existing)

        assertThrows(IllegalStateException::class.java) { store.save(replacement) }

        assertEquals(existing, store.load())
        store.save(existing)
        assertEquals(existing, store.load())
    }

    @Test
    fun `delete failure retains the matching recoverable authority`() {
        val root = Files.createTempDirectory("lan-room-store-retain").toFile()
        val access = TestFileAccess()
        val stable = testStore(root, PrefixCipher(), access)
        val secrets = fixtureSecrets()
        stable.save(secrets)
        val failing = testStore(root, PrefixCipher(), FailingDeleteAccess(access))

        assertThrows(IllegalStateException::class.java) { failing.deleteIfMatches(secrets) }

        assertEquals(secrets, stable.load())
    }

    private fun testStore(
        root: File,
        cipher: LanSecretCipher,
        files: LanSecretFileAccess = TestFileAccess(),
    ) = LanSecretStore(
        // macOS exposes /var as a symlink; production roots are already anchored
        // below Context.noBackupFilesDir.canonicalFile.
        root = root.canonicalFile,
        cipher = cipher,
        files = files,
    )

    private fun fixtureSecrets() = LanRoomSecrets(
        schemaVersion = 1,
        roomId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        roomKey = "room-key-canary-that-must-never-appear-plain",
        tokenPepper = "token-pepper-canary-that-must-never-appear-plain",
        hostPlayerId = "11111111-1111-4111-8111-111111111111",
        hostResumeToken = "host-resume-canary-that-must-never-appear-plain",
    )

    private class PrefixCipher : LanSecretCipher {
        override fun encrypt(plaintext: ByteArray): ByteArray =
            byteArrayOf(0x47, 0x42) + plaintext.map { (it.toInt() xor 0x5a).toByte() }

        override fun decrypt(ciphertext: ByteArray): ByteArray {
            require(ciphertext.size >= 2 && ciphertext[0] == 0x47.toByte() && ciphertext[1] == 0x42.toByte())
            return ciphertext.copyOfRange(2, ciphertext.size).map { (it.toInt() xor 0x5a).toByte() }.toByteArray()
        }
    }

    private class CountingEntropy : SecretEntropy {
        var bytesRequested: Int = 0
            private set

        override fun nextBytes(size: Int): ByteArray {
            bytesRequested += size
            return ByteArray(size) { index -> (bytesRequested + index).toByte() }
        }
    }

    private class TestFileAccess : LanSecretFileAccess {
        override fun read(root: File, name: String, maximumBytes: Int): ByteArray? {
            Files.createDirectories(root.toPath())
            val path = File(root, name).toPath()
            if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return null
            val attributes = attributes(path)
            check(attributes.isRegularFile && attributes.size() in 1..maximumBytes.toLong())
            return Files.readAllBytes(path).also { check(it.size.toLong() == attributes.size()) }
        }

        override fun writeAtomically(root: File, name: String, bytes: ByteArray, maximumBytes: Int) {
            check(bytes.size in 1..maximumBytes)
            Files.createDirectories(root.toPath())
            val target = File(root, name).toPath()
            check(!Files.exists(target, LinkOption.NOFOLLOW_LINKS))
            val temporary = File(root, "$name.tmp").toPath()
            if (Files.exists(temporary, LinkOption.NOFOLLOW_LINKS)) {
                check(attributes(temporary).isRegularFile)
                Files.delete(temporary)
            }
            Files.write(temporary, bytes, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE)
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE)
        }

        override fun delete(root: File, name: String, maximumBytes: Int): Boolean {
            val path = File(root, name).toPath()
            if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return false
            check(attributes(path).isRegularFile)
            Files.delete(path)
            return true
        }

        override fun hasStoredBlob(root: File, name: String, maximumBytes: Int): Boolean {
            val path = File(root, name).toPath()
            if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return false
            val attributes = attributes(path)
            check(attributes.isRegularFile && attributes.size() in 1..maximumBytes.toLong())
            return true
        }

        private fun attributes(path: java.nio.file.Path): BasicFileAttributes =
            Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
    }

    private class FailingDeleteAccess(private val delegate: LanSecretFileAccess) : LanSecretFileAccess by delegate {
        override fun delete(root: File, name: String, maximumBytes: Int): Boolean {
            throw IllegalStateException("injected delete failure")
        }
    }
}
