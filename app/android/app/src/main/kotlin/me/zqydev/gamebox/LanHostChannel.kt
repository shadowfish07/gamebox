package me.zqydev.gamebox

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean

internal interface LanHostCommands {
    fun getStatus(): Map<String, Any?>

    fun createRoom(nickname: String): Map<String, Any?>

    fun issueHostLaunch(): Map<String, Any?>

    fun refreshEndpoint(): Map<String, Any?>

    fun closeRoom(mode: String): Map<String, Any?>

    fun stopCompletedRoom(allowMissingGuestAck: Boolean): Map<String, Any?>
}

internal sealed class LanChannelReply {
    data class Success(val value: Map<String, Any?>) : LanChannelReply() {
        override fun toString(): String = "LanChannelReply.Success(value=<redacted>)"
    }

    data class Failure(val code: String, val details: Any? = null) : LanChannelReply() {
        override fun toString(): String = "LanChannelReply.Failure(code=$code, details=<redacted>)"
    }

    data object NotImplemented : LanChannelReply()
}

internal class LanHostCommandDispatcher(
    private val commands: () -> LanHostCommands?,
    private val ensureStartedFromVisibleActivity: () -> Unit,
) {
    fun dispatch(method: String, arguments: Any?): LanChannelReply {
        validationFailure(method, arguments)?.let { return it }
        val parsed = requireNotNull(parseArguments(method, arguments))
        if (method in STARTED_METHODS) {
            try {
                ensureStartedFromVisibleActivity()
            } catch (_: RuntimeException) {
                return LanChannelReply.Failure("service_unavailable")
            }
        }
        val host = commands() ?: return LanChannelReply.Failure("service_unavailable")
        return try {
            val value = when (method) {
                "getStatus" -> host.getStatus()
                "createRoom" -> host.createRoom(parsed.getValue("nickname") as String)
                "issueHostLaunch" -> host.issueHostLaunch()
                "refreshEndpoint" -> host.refreshEndpoint()
                "closeRoom" -> host.closeRoom(parsed.getValue("mode") as String)
                "stopCompletedRoom" -> host.stopCompletedRoom(parsed.getValue("allowMissingGuestAck") as Boolean)
                else -> return LanChannelReply.NotImplemented
            }
            if (!validResponse(method, value)) {
                LanChannelReply.Failure("invalid_response")
            } else {
                LanChannelReply.Success(LinkedHashMap(value))
            }
        } catch (error: LanEngineException) {
            LanChannelReply.Failure(error.code)
        } catch (_: IllegalArgumentException) {
            LanChannelReply.Failure("invalid_arguments")
        } catch (_: RuntimeException) {
            LanChannelReply.Failure("internal_error")
        }
    }

    fun validationFailure(method: String, arguments: Any?): LanChannelReply? = when {
        method !in METHODS -> LanChannelReply.NotImplemented
        parseArguments(method, arguments) == null -> LanChannelReply.Failure("invalid_arguments")
        else -> null
    }

    fun requiresStartedService(method: String): Boolean = method in STARTED_METHODS

    private fun parseArguments(method: String, arguments: Any?): Map<String, Any>? {
        if (method in NULL_ARGUMENT_METHODS) return if (arguments == null) emptyMap() else null
        val raw = arguments as? Map<*, *> ?: return null
        if (raw.keys.any { it !is String }) return null
        @Suppress("UNCHECKED_CAST")
        val value = raw as Map<String, Any?>
        return when (method) {
            "createRoom" -> {
                val nickname = value["nickname"] as? String
                if (value.keys == setOf("nickname") && !nickname.isNullOrBlank()) {
                    mapOf("nickname" to nickname)
                } else {
                    null
                }
            }

            "closeRoom" -> {
                val mode = value["mode"] as? String
                if (value.keys == setOf("mode") && mode in CLOSE_MODES) mapOf("mode" to mode!!) else null
            }

            "stopCompletedRoom" -> {
                val allow = value["allowMissingGuestAck"]
                if (value.keys == setOf("allowMissingGuestAck") && allow is Boolean) {
                    mapOf("allowMissingGuestAck" to allow)
                } else {
                    null
                }
            }

            else -> null
        }
    }

    private fun validResponse(method: String, value: Map<String, Any?>): Boolean {
        return try {
            when (method) {
                "createRoom" -> validCreate(value)
                "issueHostLaunch" -> validLaunch(value)
                else -> validStatus(value)
            }
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun validStatus(value: Map<String, Any?>): Boolean {
        if (value.keys != STATUS_FIELDS || value["schemaVersion"] != 1) return false
        val state = value["state"] as? String ?: return false
        val port = value["port"] as? Int ?: return false
        val revision = value["gameRevision"] as? Long ?: return false
        val endpointChanged = value["endpointChanged"] as? Boolean ?: return false
        val roomId = value["roomId"]
        val endpoint = value["endpoint"]
        if (revision !in 0..MAX_SAFE_INTEGER) return false
        if (state == "empty") {
            return roomId == null && port == 0 && revision == 0L && !endpointChanged && endpoint == null
        }
        if (state == "corrupt") {
            return roomId is String && LanHostResponseCodec.isCanonicalUUID(roomId) &&
                port == 0 && revision == 0L && !endpointChanged && endpoint == null
        }
        if (state !in RUNNING_STATES || roomId !is String || !LanHostResponseCodec.isCanonicalUUID(roomId)) {
            return false
        }
        if (port !in 49152..65535) return false
        if (endpoint == null) return true
        if (endpoint !is String) return false
        val separator = endpoint.lastIndexOf(':')
        if (separator <= 0 || separator == endpoint.lastIndex) return false
        val address = endpoint.substring(0, separator)
        val endpointPort = endpoint.substring(separator + 1)
        return LanHostResponseCodec.isPrivateIPv4(address) && endpointPort == port.toString()
    }

    private fun validCreate(value: Map<String, Any?>): Boolean {
        if (value.keys != CREATE_FIELDS) return false
        val status = LinkedHashMap(value).apply {
            remove("roomKey")
            remove("joinExpiresAt")
        }
        return validStatus(status) && status["state"] == "waiting" && status["gameRevision"] == 0L &&
            (value["roomKey"] as? String)?.let(LanHostResponseCodec::isCanonicalCredential) == true &&
            (value["joinExpiresAt"] as? Long)?.let { it in 1..MAX_SAFE_INTEGER } == true
    }

    private fun validLaunch(value: Map<String, Any?>): Boolean {
        if (value.keys != LAUNCH_FIELDS || value["schemaVersion"] != 1) return false
        val matchId = value["matchId"] as? String ?: return false
        val ticket = value["launchTicket"] as? String ?: return false
        val wsUrl = value["wsUrl"] as? String ?: return false
        val expiresAt = value["expiresAt"] as? Long ?: return false
        return LanHostResponseCodec.isCanonicalUUID(matchId) && value["gameId"] == "gomoku" &&
            LanHostResponseCodec.isCanonicalCredential(ticket) &&
            LanHostResponseCodec.isCanonicalLoopbackWS(wsUrl) && expiresAt in 1..MAX_SAFE_INTEGER
    }

    private companion object {
        val METHODS = setOf(
            "getStatus",
            "createRoom",
            "issueHostLaunch",
            "refreshEndpoint",
            "closeRoom",
            "stopCompletedRoom",
        )
        val NULL_ARGUMENT_METHODS = setOf("getStatus", "issueHostLaunch", "refreshEndpoint")
        val STARTED_METHODS = setOf("createRoom", "closeRoom", "stopCompletedRoom")
        val CLOSE_MODES = setOf("cancel", "resign", "discard_corrupt")
        val RUNNING_STATES = setOf("waiting", "active", "finished", "cancelled")
        const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
        val STATUS_FIELDS = setOf(
            "schemaVersion",
            "state",
            "roomId",
            "port",
            "gameRevision",
            "endpointChanged",
            "endpoint",
        )
        val CREATE_FIELDS = STATUS_FIELDS + setOf("roomKey", "joinExpiresAt")
        val LAUNCH_FIELDS = setOf(
            "schemaVersion",
            "matchId",
            "gameId",
            "launchTicket",
            "wsUrl",
            "expiresAt",
        )
    }
}

internal class LanHostServiceReadyBarrier(
    private val onWaiting: () -> Unit = {},
) {
    private var commands: LanHostCommands? = null
    private var generation = 0L

    @Synchronized
    fun prepareStart() {
        commands = null
        generation++
        (this as java.lang.Object).notifyAll()
    }

    @Synchronized
    fun ready(value: LanHostCommands) {
        commands = value
        (this as java.lang.Object).notifyAll()
    }

    @Synchronized
    fun destroyed(value: LanHostCommands) {
        if (commands != null && commands !== value) return
        commands = null
        generation++
        (this as java.lang.Object).notifyAll()
    }

    @Synchronized
    fun await(timeoutMillis: Long): LanHostCommands? {
        require(timeoutMillis > 0)
        commands?.let { return it }
        val awaitedGeneration = generation
        val deadline = System.nanoTime() + timeoutMillis * 1_000_000L
        onWaiting()
        while (commands == null && generation == awaitedGeneration) {
            val remainingNanos = deadline - System.nanoTime()
            if (remainingNanos <= 0) return null
            val millis = remainingNanos / 1_000_000L
            val nanos = (remainingNanos % 1_000_000L).toInt()
            (this as java.lang.Object).wait(millis, nanos)
        }
        return commands
    }

    @Synchronized
    fun current(): LanHostCommands? = commands
}

internal class LanHostAsyncDispatcher(
    private val serviceReady: LanHostServiceReadyBarrier,
    private val ensureStartedFromVisibleActivity: () -> Unit,
    private val recoverableRoomExists: () -> Boolean,
    private val worker: Executor,
    private val postToMain: Executor,
    private val timeoutMillis: Long,
) {
    private val commandDispatcher = LanHostCommandDispatcher({ null }) {}

    fun dispatch(method: String, arguments: Any?, callback: (LanChannelReply) -> Unit) {
        val delivered = AtomicBoolean(false)
        fun complete(reply: LanChannelReply) {
            postToMain.execute {
                if (delivered.compareAndSet(false, true)) callback(reply)
            }
        }
        commandDispatcher.validationFailure(method, arguments)?.let {
            complete(it)
            return
        }
        if (commandDispatcher.requiresStartedService(method)) {
            serviceReady.prepareStart()
            try {
                ensureStartedFromVisibleActivity()
            } catch (_: RuntimeException) {
                complete(LanChannelReply.Failure("service_unavailable"))
                return
            }
        }
        try {
            worker.execute {
                val reply = try {
                    val readyCommands = serviceReady.current()
                    when {
                        readyCommands != null ->
                            LanHostCommandDispatcher({ readyCommands }) {}.dispatch(method, arguments)

                        method == "getStatus" && !recoverableRoomExists() ->
                            LanChannelReply.Success(emptyStatus())

                        else -> {
                            if (method == "getStatus") {
                                serviceReady.prepareStart()
                                ensureStartedFromVisibleActivity()
                            }
                            val commands = serviceReady.await(timeoutMillis)
                            if (commands == null) {
                                LanChannelReply.Failure("service_unavailable")
                            } else {
                                LanHostCommandDispatcher({ commands }) {}.dispatch(method, arguments)
                            }
                        }
                    }
                } catch (_: RuntimeException) {
                    LanChannelReply.Failure("service_unavailable")
                }
                complete(reply)
            }
        } catch (_: RuntimeException) {
            complete(LanChannelReply.Failure("service_unavailable"))
        }
    }

    private fun emptyStatus(): Map<String, Any?> = linkedMapOf(
        "schemaVersion" to 1,
        "state" to "empty",
        "roomId" to null,
        "port" to 0,
        "gameRevision" to 0L,
        "endpointChanged" to false,
        "endpoint" to null,
    )
}

internal class LanHostChannel(
    messenger: BinaryMessenger,
    serviceReady: LanHostServiceReadyBarrier,
    ensureStartedFromVisibleActivity: () -> Unit,
    recoverableRoomExists: () -> Boolean,
    worker: Executor,
    postToMain: Executor,
    timeoutMillis: Long = 5_000,
) {
    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val dispatcher = LanHostAsyncDispatcher(
        serviceReady,
        ensureStartedFromVisibleActivity,
        recoverableRoomExists,
        worker,
        postToMain,
        timeoutMillis,
    )

    init {
        channel.setMethodCallHandler { call, result ->
            dispatcher.dispatch(call.method, call.arguments) { reply ->
                when (reply) {
                    is LanChannelReply.Success -> result.success(reply.value)
                    is LanChannelReply.Failure -> result.error(reply.code, ERROR_MESSAGE, reply.details)
                    LanChannelReply.NotImplemented -> result.notImplemented()
                }
            }
        }
    }

    fun close() {
        channel.setMethodCallHandler(null)
    }

    override fun toString(): String = "LanHostChannel(channel=$CHANNEL_NAME, handler=<redacted>)"

    private companion object {
        const val CHANNEL_NAME = "me.zqydev.gamebox/lan_host"
        const val ERROR_MESSAGE = "LAN host operation failed."
    }
}
