package me.zqydev.gamebox

import java.io.File
import java.io.FileOutputStream
import org.json.JSONObject

data class PendingGameResult(
    val matchId: String,
    val gameId: String,
    val source: String,
    val endpointKind: String,
) {
    fun toMap(): Map<String, String> = mapOf(
        "matchId" to matchId,
        "gameId" to gameId,
        "source" to source,
        "endpointKind" to endpointKind,
    )
}

class PendingGameResultStore(
    private val directory: File,
    private val directorySync: ResultDirectorySync = AndroidResultDirectorySync,
) {
    @Synchronized
    fun persist(args: GameLaunchArgs): Boolean {
        if (!GameResultValidator.validateMatchId(args.matchId) || args.source !in SOURCES) return false
        if (!ensureDirectory()) return false
        val destination = file(args.matchId)
        val body = JSONObject(
            linkedMapOf(
                "schemaVersion" to 1,
                "matchId" to args.matchId,
                "gameId" to args.gameId,
                "source" to args.source,
                "endpointKind" to args.endpointKind,
            ),
        ).toString()
        if (destination.exists()) return runCatching { destination.readText() == body }.getOrDefault(false)
        val temporary = File(directory, ".${args.matchId}.${System.nanoTime()}.tmp")
        return try {
            if (!temporary.createNewFile()) return false
            FileOutputStream(temporary).use { stream ->
                stream.write(body.toByteArray(Charsets.UTF_8))
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
    fun remove(matchId: String): Boolean {
        if (!GameResultValidator.validateMatchId(matchId)) return false
        val target = file(matchId)
        if (!target.exists()) return true
        return try {
            target.delete().also { removed -> if (removed) directorySync.sync(directory) }
        } catch (_: Exception) {
            false
        }
    }

    @Synchronized
    fun quarantine(matchId: String): Boolean {
        if (!GameResultValidator.validateMatchId(matchId)) return false
        val source = file(matchId)
        if (!source.isFile) return false
        val quarantine = File(directory, "quarantine")
        return try {
            if (!quarantine.isDirectory && !quarantine.mkdir()) return false
            val destination = File(quarantine, "$matchId.json")
            if (destination.exists() || !source.renameTo(destination)) return false
            directorySync.sync(directory)
            directorySync.sync(quarantine)
            true
        } catch (_: Exception) {
            false
        }
    }

    @Synchronized
    fun list(): List<PendingGameResult> = directory.listFiles { file -> file.extension == "json" }
        ?.sortedBy { it.name }
        ?.take(MAX_PENDING)
        ?.mapNotNull(::read)
        ?: emptyList()

    private fun read(file: File): PendingGameResult? = runCatching {
        if (!file.isFile || file.length() !in 2..MAX_PENDING_BYTES.toLong()) return@runCatching null
        val objectValue = JSONObject(file.readText())
        if (objectValue.optInt("schemaVersion") != 1 || objectValue.length() != 5) return@runCatching null
        PendingGameResult(
            objectValue.getString("matchId"),
            objectValue.getString("gameId"),
            objectValue.getString("source"),
            objectValue.getString("endpointKind"),
        ).takeIf {
            it.matchId == file.nameWithoutExtension &&
                GameResultValidator.validateMatchId(it.matchId) &&
                it.gameId == "gomoku" && it.source in SOURCES && it.endpointKind == it.source
        }
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

    private companion object {
        val SOURCES = setOf("public", "lan")
        const val MAX_PENDING = 32
        const val MAX_PENDING_BYTES = 8 * 1024
    }
}
