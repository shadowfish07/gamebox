package me.zqydev.gamebox

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

fun interface ResultDirectorySync {
    fun sync(directory: File)
}

internal object AndroidResultDirectorySync : ResultDirectorySync {
    override fun sync(directory: File) {
        val descriptor = Os.open(
            directory.path,
            OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW,
            0,
        )
        try {
            Os.fsync(descriptor)
        } finally {
            Os.close(descriptor)
        }
    }
}

data class StoredGameResult(val raw: String, val sha256: String) {
    fun toMap(): Map<String, String> = mapOf("result" to raw, "sha256" to sha256)
}

class AtomicResultStore(
    private val directory: File,
    private val directorySync: ResultDirectorySync = AndroidResultDirectorySync,
) {
    @Synchronized
    fun persist(raw: String): Boolean {
        val validated = GameResultValidator.validate(raw) ?: return false
        val bytes = validated.canonical.toByteArray(Charsets.UTF_8)
        if (!ensureDirectory()) return false
        val destination = file(validated.matchId)
        if (destination.exists()) return read(destination)?.raw == validated.canonical
        val temporary = File(directory, ".${validated.matchId}.${System.nanoTime()}.tmp")
        return try {
            if (!temporary.createNewFile()) return false
            FileOutputStream(temporary).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
            if (destination.exists() || !temporary.renameTo(destination)) {
                temporary.delete()
                false
            } else {
                directorySync.sync(directory)
                true
            }
        } catch (_: Exception) {
            temporary.delete()
            false
        }
    }

    @Synchronized
    fun get(matchId: String): StoredGameResult? =
        if (GameResultValidator.validateMatchId(matchId)) read(file(matchId)) else null

    @Synchronized
    fun list(): List<StoredGameResult> {
        val files = directory.listFiles { file -> file.extension == "json" }
            ?.sortedBy { it.name }
            ?.take(MAX_RESULTS)
            ?: return emptyList()
        return files.mapNotNull(::read)
    }

    private fun read(file: File): StoredGameResult? = runCatching {
        if (!file.isFile || file.length() !in 2..MAX_RESULT_BYTES.toLong()) return@runCatching null
        val raw = file.readText(Charsets.UTF_8)
        val validated = GameResultValidator.validate(raw) ?: return@runCatching null
        if (file.nameWithoutExtension != validated.matchId) return@runCatching null
        StoredGameResult(validated.canonical, sha256(validated.canonical.toByteArray(Charsets.UTF_8)))
    }.getOrNull()

    private fun ensureDirectory(): Boolean = try {
        if (directory.isDirectory) return true
        if (!directory.mkdir() || !directory.isDirectory) return false
        directory.parentFile?.let(directorySync::sync)
        true
    } catch (_: SecurityException) {
        false
    }

    private fun file(matchId: String) = File(directory, "$matchId.json")

    companion object {
        const val MAX_RESULT_BYTES = 512 * 1024
        private const val MAX_RESULTS = 512

        fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
    }
}
