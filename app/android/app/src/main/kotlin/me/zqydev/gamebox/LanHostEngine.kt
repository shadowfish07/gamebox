package me.zqydev.gamebox

import lanengine.Lanengine

interface LanHostEngine {
    fun createRoom(requestJson: String): String

    fun restore(secretsJson: String): String

    fun issueHostLaunch(): String

    fun status(): String

    fun closeRoom(mode: String): String

    fun prepareCleanup(allowMissingGuestAck: Boolean): String

    fun deleteActiveRoom()

    fun stop()
}

internal class LanEngineException(
    val code: String,
    cause: Throwable? = null,
) : RuntimeException(code, cause) {
    override fun toString(): String = "LanEngineException(code=$code, cause=<redacted>)"
}

internal class GoLanHostEngine(root: String) : LanHostEngine {
    private val delegate = try {
        Lanengine.newEngine(root)
    } catch (error: Exception) {
        throw mapGoError(error)
    }

    override fun createRoom(requestJson: String): String = call { delegate.createRoom(requestJson) }

    override fun restore(secretsJson: String): String = call { delegate.start(secretsJson) }

    override fun issueHostLaunch(): String = call { delegate.issueHostLaunch() }

    override fun status(): String = delegate.status()

    override fun closeRoom(mode: String): String = call { delegate.closeRoom(mode) }

    override fun prepareCleanup(allowMissingGuestAck: Boolean): String =
        call { delegate.prepareCleanup(allowMissingGuestAck) }

    override fun deleteActiveRoom() {
        call { delegate.deleteActiveRoom() }
    }

    override fun stop() {
        call { delegate.stop() }
    }

    override fun toString(): String = "GoLanHostEngine(delegate=<redacted>)"

    private fun <T> call(block: () -> T): T = try {
        block()
    } catch (error: Exception) {
        throw mapGoError(error)
    }

    private companion object {
        fun mapGoError(error: Exception): LanEngineException {
            val code = when (error.message) {
                "invalid configuration" -> "invalid_configuration"
                "not_running" -> "not_running"
                "cleanup_not_ready" -> "cleanup_not_ready"
                else -> "internal_error"
            }
            return LanEngineException(code, error)
        }
    }
}

internal data class LanCreatedRoom(
    val statusJson: String,
    val secrets: LanRoomSecrets,
    val joinExpiresAt: Long,
) {
    override fun toString(): String =
        "LanCreatedRoom(statusJson=<redacted>, secrets=<redacted>, joinExpiresAt=<time>)"
}

internal class LanHostCoordinator(
    private val engine: LanHostEngine,
    private val persistence: LanRoomSecretPersistence,
    private val generateSecrets: () -> LanRoomSecrets = ProductionLanRoomSecrets::generate,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    @Synchronized
    fun createRoom(nickname: String): String = createRoomWithAuthority(nickname).statusJson

    @Synchronized
    fun createRoomWithAuthority(nickname: String): LanCreatedRoom {
        require(nickname.isNotBlank())
        if (persistence.load() != null) {
            throw LanEngineException("room_exists")
        }
        val secrets = generateSecrets()
        val joinExpiresAt = checkedJoinExpiry()
        persistence.save(secrets)
        return try {
            LanCreatedRoom(
                statusJson = engine.createRoom(secrets.createRequestJson(nickname, joinExpiresAt)),
                secrets = secrets,
                joinExpiresAt = joinExpiresAt,
            )
        } catch (error: LanEngineException) {
            if (error.code == "invalid_configuration") {
                persistence.deleteIfMatches(secrets)
            }
            throw error
        }
    }

    @Synchronized
    fun restore(): String {
        val secrets = persistence.load() ?: return engine.status()
        return engine.restore(secrets.restoreRequestJson())
    }

    @Synchronized
    fun issueHostLaunch(): String = engine.issueHostLaunch()

    @Synchronized
    fun status(): String = engine.status()

    @Synchronized
    fun closeRoom(mode: String): String = engine.closeRoom(mode)

    @Synchronized
    fun prepareCleanup(allowMissingGuestAck: Boolean): String = engine.prepareCleanup(allowMissingGuestAck)

    @Synchronized
    fun deleteActiveRoom() = engine.deleteActiveRoom()

    @Synchronized
    fun stop() = engine.stop()

    override fun toString(): String = "LanHostCoordinator(engine=<redacted>, persistence=<redacted>)"

    private fun checkedJoinExpiry(): Long {
        val now = nowMillis()
        check(now > 0 && now <= MAX_SAFE_MILLIS - JOIN_WINDOW_MILLIS)
        return now + JOIN_WINDOW_MILLIS
    }

    private companion object {
        const val JOIN_WINDOW_MILLIS = 10 * 60 * 1000L
        const val MAX_SAFE_MILLIS = 9_007_199_254_740_991L
    }
}

private fun LanRoomSecrets.restoreRequestJson(): String =
    "{\"schemaVersion\":1,\"roomId\":${jsonString(roomId)}," +
        "\"hostPlayerId\":${jsonString(hostPlayerId)},\"tokenPepper\":${jsonString(tokenPepper)}," +
        "\"hostResumeToken\":${jsonString(hostResumeToken)}}"

private fun LanRoomSecrets.createRequestJson(nickname: String, joinExpiresAt: Long): String =
    "{\"schemaVersion\":1,\"roomId\":${jsonString(roomId)}," +
        "\"hostPlayerId\":${jsonString(hostPlayerId)},\"hostNickname\":${jsonString(nickname)}," +
        "\"roomKey\":${jsonString(roomKey)},\"tokenPepper\":${jsonString(tokenPepper)}," +
        "\"hostResumeToken\":${jsonString(hostResumeToken)},\"joinExpiresAt\":$joinExpiresAt}"

private fun jsonString(value: String): String {
    val result = StringBuilder(value.length + 2).append('"')
    value.forEach { character ->
        when (character) {
            '"' -> result.append("\\\"")
            '\\' -> result.append("\\\\")
            '\b' -> result.append("\\b")
            '\u000c' -> result.append("\\f")
            '\n' -> result.append("\\n")
            '\r' -> result.append("\\r")
            '\t' -> result.append("\\t")
            else -> if (character < ' ') {
                result.append("\\u").append(character.code.toString(16).padStart(4, '0'))
            } else {
                result.append(character)
            }
        }
    }
    return result.append('"').toString()
}
