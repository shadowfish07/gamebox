package me.zqydev.gamebox

import android.content.Context
import android.os.Process
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal const val LAN_ROOM_SCHEMA_VERSION = 1
private const val MAX_SECRET_BLOB_BYTES = 64 * 1024
private const val MAX_SECRET_FIELD_BYTES = 4096
private const val KEY_ALIAS = "gamebox_lan_room_v1"
private const val KEYSTORE = "AndroidKeyStore"
private const val GCM_IV_BYTES = 12
private const val GCM_TAG_BITS = 128

internal data class LanRoomSecrets(
    val schemaVersion: Int,
    val roomId: String,
    val roomKey: String,
    val tokenPepper: String,
    val hostPlayerId: String,
    val hostResumeToken: String,
) {
    init {
        require(schemaVersion == LAN_ROOM_SCHEMA_VERSION)
        requireCanonicalUuid(roomId)
        requireCanonicalUuid(hostPlayerId)
        require(roomId != hostPlayerId)
        requireCredential(roomKey)
        requireCredential(tokenPepper)
        requireCredential(hostResumeToken)
    }

    override fun toString(): String =
        "LanRoomSecrets(schemaVersion=1, roomId=<id>, roomKey=<redacted>, " +
            "tokenPepper=<redacted>, hostPlayerId=<id>, hostResumeToken=<redacted>)"

    companion object {
        private fun requireCanonicalUuid(value: String) {
            require(value.length == 36 && UUID.fromString(value).toString() == value)
        }

        private fun requireCredential(value: String) {
            val size = value.toByteArray(Charsets.UTF_8).size
            require(size in 32..MAX_SECRET_FIELD_BYTES)
        }
    }
}

internal fun interface SecretEntropy {
    fun nextBytes(size: Int): ByteArray
}

internal class LanRoomSecretsGenerator(internal val entropy: SecretEntropy) {
    fun generate(): LanRoomSecrets = LanRoomSecrets(
        schemaVersion = LAN_ROOM_SCHEMA_VERSION,
        roomId = nextUuid(),
        roomKey = base64Url(entropy.nextBytes(32)),
        tokenPepper = base64Url(entropy.nextBytes(32)),
        hostPlayerId = nextUuid(),
        hostResumeToken = base64Url(entropy.nextBytes(32)),
    )

    private fun nextUuid(): String {
        val bytes = entropy.nextBytes(16)
        require(bytes.size == 16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x40).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long).toString()
    }
}

internal object ProductionLanRoomSecrets {
    fun generate(): LanRoomSecrets {
        val secureRandom = SecureRandom()
        return LanRoomSecretsGenerator { size ->
            ByteArray(size).also(secureRandom::nextBytes)
        }.generate()
    }
}

internal interface LanSecretCipher {
    fun encrypt(plaintext: ByteArray): ByteArray

    fun decrypt(ciphertext: ByteArray): ByteArray
}

internal interface LanRoomSecretPersistence {
    fun save(secrets: LanRoomSecrets)

    fun load(): LanRoomSecrets?

    fun deleteIfMatches(expected: LanRoomSecrets): Boolean

    fun delete()
}

internal interface LanSecretFileAccess {
    fun read(root: File, name: String, maximumBytes: Int): ByteArray?

    fun writeAtomically(root: File, name: String, bytes: ByteArray, maximumBytes: Int)

    fun delete(root: File, name: String, maximumBytes: Int): Boolean

    fun hasStoredBlob(root: File, name: String, maximumBytes: Int): Boolean
}

internal class LanSecretStore internal constructor(
    private val root: File,
    private val cipher: LanSecretCipher,
    private val files: LanSecretFileAccess,
) : LanRoomSecretPersistence {
    constructor(context: Context) : this(
        root = checkedRoot(context),
        cipher = AndroidKeystoreLanSecretCipher(),
        files = AndroidLanSecretFileAccess(),
    )

    @Synchronized
    override fun save(secrets: LanRoomSecrets) {
        val existing = load()
        if (existing != null) {
            if (existing == secrets) return
            throw IllegalStateException("Recoverable LAN room state already exists")
        }
        val encrypted = cipher.encrypt(LanSecretCodec.encode(secrets))
        check(encrypted.isNotEmpty() && encrypted.size <= MAX_SECRET_BLOB_BYTES)
        files.writeAtomically(root, SECRET_FILE_NAME, encrypted, MAX_SECRET_BLOB_BYTES)
    }

    @Synchronized
    override fun load(): LanRoomSecrets? {
        val encrypted = files.read(root, SECRET_FILE_NAME, MAX_SECRET_BLOB_BYTES) ?: return null
        return try {
            LanSecretCodec.decode(cipher.decrypt(encrypted))
        } catch (error: Exception) {
            throw IllegalStateException("Invalid LAN room state", error)
        }
    }

    @Synchronized
    override fun deleteIfMatches(expected: LanRoomSecrets): Boolean {
        val current = load() ?: return false
        if (current != expected) return false
        delete()
        return true
    }

    @Synchronized
    override fun delete() {
        files.delete(root, SECRET_FILE_NAME, MAX_SECRET_BLOB_BYTES)
    }

    @Synchronized
    fun hasStoredBlob(): Boolean {
        return files.hasStoredBlob(root, SECRET_FILE_NAME, MAX_SECRET_BLOB_BYTES)
    }

    override fun toString(): String = "LanSecretStore(root=<private>, cipher=<keystore>)"

    companion object {
        internal const val SECRET_FILE_NAME = "room-secrets.bin"

        private fun checkedRoot(context: Context): File {
            val noBackup = context.noBackupFilesDir.canonicalFile
            val root = File(noBackup, "lan_host").absoluteFile
            check(root.parentFile == noBackup)
            return root
        }

    }
}

private class AndroidLanSecretFileAccess : LanSecretFileAccess {
    override fun read(root: File, name: String, maximumBytes: Int): ByteArray? = protect {
        ensureRoot(root)
        val descriptor = openExisting(child(root, name)) ?: return@protect null
        try {
            val initial = regularIdentity(Os.fstat(descriptor), maximumBytes, requireNonEmpty = true)
            val bytes = ByteArray(initial.size.toInt() + 1)
            var offset = 0
            while (offset < bytes.size) {
                val count = Os.read(descriptor, bytes, offset, bytes.size - offset)
                if (count <= 0) break
                offset += count
            }
            val final = regularIdentity(Os.fstat(descriptor), maximumBytes, requireNonEmpty = true)
            check(initial.sameFile(final) && initial.size == final.size && offset.toLong() == initial.size)
            bytes.copyOf(offset)
        } finally {
            Os.close(descriptor)
        }
    }

    override fun writeAtomically(root: File, name: String, bytes: ByteArray, maximumBytes: Int) = protect {
        check(bytes.size in 1..maximumBytes)
        ensureRoot(root)
        val target = child(root, name)
        requireMissing(target)
        val temporary = child(root, "$name.tmp")
        removeVerifiedStagingFile(temporary, maximumBytes)
        var createdIdentity: FileIdentity? = null
        var descriptor: java.io.FileDescriptor? = Os.open(
            temporary.path,
            OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
                OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK,
            PRIVATE_FILE_MODE,
        )
        try {
            val opened = requireNotNull(descriptor)
            val initial = regularIdentity(Os.fstat(opened), maximumBytes, requireNonEmpty = false)
            check(initial.size == 0L)
            createdIdentity = initial
            Os.fchmod(opened, PRIVATE_FILE_MODE)
            var offset = 0
            while (offset < bytes.size) {
                val count = Os.write(opened, bytes, offset, bytes.size - offset)
                check(count > 0)
                offset += count
            }
            Os.fsync(opened)
            val written = regularIdentity(Os.fstat(opened), maximumBytes, requireNonEmpty = true)
            check(written.sameFile(initial) && written.size == bytes.size.toLong())
            createdIdentity = written
            Os.close(opened)
            descriptor = null
            requireMissing(target)
            Os.rename(temporary.path, target.path)
            syncDirectory(root)
        } catch (error: Exception) {
            descriptor?.let { runCatching { Os.close(it) } }
            createdIdentity?.let { runCatching { removeIfSame(temporary, it) } }
            throw error
        }
    }

    override fun delete(root: File, name: String, maximumBytes: Int): Boolean = protect {
        check(maximumBytes > 0)
        ensureRoot(root)
        val target = child(root, name)
        val descriptor = openExisting(target) ?: return@protect false
        try {
            val identity = ownedRegularIdentity(Os.fstat(descriptor))
            removeIfSame(target, identity)
            syncDirectory(root)
            true
        } finally {
            Os.close(descriptor)
        }
    }

    override fun hasStoredBlob(root: File, name: String, maximumBytes: Int): Boolean = protect {
        ensureRoot(root)
        val descriptor = openExisting(child(root, name)) ?: return@protect false
        try {
            regularIdentity(Os.fstat(descriptor), maximumBytes, requireNonEmpty = true)
            true
        } finally {
            Os.close(descriptor)
        }
    }

    private fun ensureRoot(root: File) {
        try {
            Os.mkdir(root.path, PRIVATE_DIRECTORY_MODE)
        } catch (error: ErrnoException) {
            if (error.errno != OsConstants.EEXIST) throw error
        }
        val initial = directoryIdentity(Os.lstat(root.path))
        val descriptor = Os.open(
            root.path,
            OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK,
            0,
        )
        try {
            check(directoryIdentity(Os.fstat(descriptor)).sameFile(initial))
        } finally {
            Os.close(descriptor)
        }
    }

    private fun openExisting(file: File): java.io.FileDescriptor? = try {
        Os.open(
            file.path,
            OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK,
            0,
        )
    } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT) null else throw error
    }

    private fun requireMissing(file: File) {
        try {
            Os.lstat(file.path)
            throw IllegalStateException("LAN room state already exists")
        } catch (error: ErrnoException) {
            if (error.errno != OsConstants.ENOENT) throw error
        }
    }

    private fun removeVerifiedStagingFile(file: File, maximumBytes: Int) {
        val descriptor = openExisting(file) ?: return
        try {
            val identity = regularIdentity(Os.fstat(descriptor), maximumBytes, requireNonEmpty = false)
            removeIfSame(file, identity)
            syncDirectory(file.parentFile!!)
        } finally {
            Os.close(descriptor)
        }
    }

    private fun removeIfSame(file: File, expected: FileIdentity) {
        val current = fileIdentity(Os.lstat(file.path))
        check(current.sameFile(expected) && current.uid == Process.myUid() && current.regular)
        Os.remove(file.path)
    }

    private fun syncDirectory(root: File) {
        val initial = directoryIdentity(Os.lstat(root.path))
        val descriptor = Os.open(
            root.path,
            OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK,
            0,
        )
        try {
            check(directoryIdentity(Os.fstat(descriptor)).sameFile(initial))
            Os.fsync(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }

    private fun child(root: File, name: String): File {
        check(name == LanSecretStore.SECRET_FILE_NAME || name == "${LanSecretStore.SECRET_FILE_NAME}.tmp")
        return File(root, name).absoluteFile.also { check(it.parentFile == root) }
    }

    private fun regularIdentity(stat: StructStat, maximumBytes: Int, requireNonEmpty: Boolean): FileIdentity {
        val identity = ownedRegularIdentity(stat)
        check(identity.size in (if (requireNonEmpty) 1L else 0L)..maximumBytes.toLong())
        return identity
    }

    private fun ownedRegularIdentity(stat: StructStat): FileIdentity = fileIdentity(stat).also {
        check(it.regular && it.uid == Process.myUid() && it.size >= 0)
    }

    private fun directoryIdentity(stat: StructStat): FileIdentity = fileIdentity(stat).also {
        check(it.directory && it.uid == Process.myUid())
    }

    private fun fileIdentity(stat: StructStat) = FileIdentity(
        device = stat.st_dev,
        inode = stat.st_ino,
        uid = stat.st_uid,
        type = stat.st_mode and OsConstants.S_IFMT,
        size = stat.st_size,
    )

    private inline fun <T> protect(block: () -> T): T = try {
        block()
    } catch (error: IllegalStateException) {
        throw error
    } catch (error: Exception) {
        throw IllegalStateException("Invalid LAN room state", error)
    }

    private data class FileIdentity(
        val device: Long,
        val inode: Long,
        val uid: Int,
        val type: Int,
        val size: Long,
    ) {
        val regular: Boolean get() = type == OsConstants.S_IFREG
        val directory: Boolean get() = type == OsConstants.S_IFDIR

        fun sameFile(other: FileIdentity): Boolean =
            device == other.device && inode == other.inode && uid == other.uid && type == other.type
    }

    private companion object {
        const val PRIVATE_FILE_MODE = 0x180
        const val PRIVATE_DIRECTORY_MODE = 0x1c0
    }
}

private object LanSecretCodec {
    private const val MAGIC = 0x47424c52

    fun encode(secrets: LanRoomSecrets): ByteArray {
        val output = ByteArrayOutputStream()
        DataOutputStream(output).use { data ->
            data.writeInt(MAGIC)
            data.writeInt(secrets.schemaVersion)
            writeString(data, secrets.roomId)
            writeString(data, secrets.roomKey)
            writeString(data, secrets.tokenPepper)
            writeString(data, secrets.hostPlayerId)
            writeString(data, secrets.hostResumeToken)
        }
        return output.toByteArray()
    }

    fun decode(encoded: ByteArray): LanRoomSecrets {
        check(encoded.size in 1..MAX_SECRET_BLOB_BYTES)
        DataInputStream(ByteArrayInputStream(encoded)).use { data ->
            check(data.readInt() == MAGIC)
            val result = LanRoomSecrets(
                schemaVersion = data.readInt(),
                roomId = readString(data),
                roomKey = readString(data),
                tokenPepper = readString(data),
                hostPlayerId = readString(data),
                hostResumeToken = readString(data),
            )
            check(data.read() == -1)
            return result
        }
    }

    private fun writeString(output: DataOutputStream, value: String) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        check(bytes.size in 1..MAX_SECRET_FIELD_BYTES)
        output.writeInt(bytes.size)
        output.write(bytes)
    }

    private fun readString(input: DataInputStream): String {
        val length = input.readInt()
        check(length in 1..MAX_SECRET_FIELD_BYTES)
        val bytes = ByteArray(length)
        input.readFully(bytes)
        val value = bytes.toString(Charsets.UTF_8)
        check(value.toByteArray(Charsets.UTF_8).contentEquals(bytes))
        return value
    }
}

private class AndroidKeystoreLanSecretCipher : LanSecretCipher {
    override fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encrypted = cipher.doFinal(plaintext)
        check(cipher.iv.size == GCM_IV_BYTES)
        return ByteBuffer.allocate(4 + 4 + GCM_IV_BYTES + 4 + encrypted.size)
            .putInt(CIPHER_MAGIC)
            .putInt(GCM_IV_BYTES)
            .put(cipher.iv)
            .putInt(encrypted.size)
            .put(encrypted)
            .array()
    }

    override fun decrypt(ciphertext: ByteArray): ByteArray {
        check(ciphertext.size in (4 + 4 + GCM_IV_BYTES + 4 + 1)..MAX_SECRET_BLOB_BYTES)
        val buffer = ByteBuffer.wrap(ciphertext)
        check(buffer.int == CIPHER_MAGIC)
        val ivLength = buffer.int
        check(ivLength == GCM_IV_BYTES && buffer.remaining() >= ivLength + 4)
        val iv = ByteArray(ivLength)
        buffer.get(iv)
        val encryptedLength = buffer.int
        check(encryptedLength > 0 && encryptedLength == buffer.remaining())
        val encrypted = ByteArray(encryptedLength)
        buffer.get(encrypted)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(encrypted)
    }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    override fun toString(): String = "AndroidKeystoreLanSecretCipher(alias=<fixed>, key=<non-exportable>)"

    companion object {
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val CIPHER_MAGIC = 0x47424145
    }
}

private fun base64Url(bytes: ByteArray): String {
    val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    val output = StringBuilder((bytes.size * 4 + 2) / 3)
    var index = 0
    while (index + 2 < bytes.size) {
        val value = ((bytes[index].toInt() and 0xff) shl 16) or
            ((bytes[index + 1].toInt() and 0xff) shl 8) or
            (bytes[index + 2].toInt() and 0xff)
        output.append(alphabet[value ushr 18])
        output.append(alphabet[value ushr 12 and 63])
        output.append(alphabet[value ushr 6 and 63])
        output.append(alphabet[value and 63])
        index += 3
    }
    val remaining = bytes.size - index
    if (remaining == 1) {
        val value = bytes[index].toInt() and 0xff
        output.append(alphabet[value ushr 2])
        output.append(alphabet[value shl 4 and 63])
    } else if (remaining == 2) {
        val value = ((bytes[index].toInt() and 0xff) shl 8) or (bytes[index + 1].toInt() and 0xff)
        output.append(alphabet[value ushr 10])
        output.append(alphabet[value ushr 4 and 63])
        output.append(alphabet[value shl 2 and 63])
    }
    return output.toString()
}
