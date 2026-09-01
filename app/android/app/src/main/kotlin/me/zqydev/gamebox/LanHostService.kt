package me.zqydev.gamebox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.Process
import android.system.Os
import android.system.OsConstants
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.io.File
import java.net.URI
import java.util.UUID
import java.util.concurrent.Executors

internal class LanHostService : Service(), LanHostCommands {
    private val startupExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "lan-host-startup").apply { priority = Thread.NORM_PRIORITY }
    }
    private lateinit var secretStore: LanSecretStore
    private var coordinator: LanHostCoordinator? = null
    private var startupFailure = false
    private var corruptRoomId: String? = null
    private var destroyed = false
    private var foreground = false

    override fun onCreate() {
        super.onCreate()
        secretStore = LanSecretStore(this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        showForegroundBeforeEngine()
        startupExecutor.execute {
            initializeAfterForeground(intent?.action ?: ACTION_RECOVER, startId)
        }
        return START_STICKY
    }

    @Synchronized
    private fun initializeAfterForeground(action: String, startId: Int) {
        if (destroyed) return
        startupFailure = false
        corruptRoomId = null
        try {
            if (secretStore.hasStoredBlob()) {
                ensureCoordinator().restore()
            } else if (action == ACTION_RECOVER) {
                removeForegroundAndStop(startId)
                return
            } else {
                ensureCoordinator()
            }
        } catch (_: RuntimeException) {
            startupFailure = true
            corruptRoomId = LanCorruptRoomIdentity.read(File(activeRoomRoot(), "manifest.json"))
            demoteForeground()
        }
        serviceReady.ready(this)
    }

    @Synchronized
    override fun getStatus(): Map<String, Any?> {
        checkNotDestroyed()
        if (startupFailure) {
            return corruptRoomId?.let(::corruptStatus) ?: throw LanEngineException("internal_error")
        }
        return LanHostResponseCodec.status(requireCoordinator().status(), LanNetworkAddress.current())
    }

    @Synchronized
    override fun createRoom(nickname: String): Map<String, Any?> {
        checkAvailable()
        return try {
            val created = requireCoordinator().createRoomWithAuthority(nickname)
            LinkedHashMap(LanHostResponseCodec.status(created.statusJson, LanNetworkAddress.current())).apply {
                put("roomKey", created.secrets.roomKey)
                put("joinExpiresAt", created.joinExpiresAt)
            }
        } catch (error: RuntimeException) {
            if (!secretStore.hasStoredBlob()) removeForegroundAndStop()
            throw error
        }
    }

    @Synchronized
    override fun issueHostLaunch(): Map<String, Any?> {
        checkAvailable()
        val secrets = secretStore.load() ?: throw LanEngineException("internal_error")
        return LinkedHashMap(LanHostResponseCodec.launch(requireCoordinator().issueHostLaunch())).apply {
            put("playerId", secrets.hostPlayerId)
            put("resumeToken", secrets.hostResumeToken)
        }
    }

    @Synchronized
    override fun refreshEndpoint(): Map<String, Any?> = getStatus()

    @Synchronized
    override fun closeRoom(mode: String): Map<String, Any?> {
        checkNotDestroyed()
        if (mode == "discard_corrupt") {
            if (startupFailure) {
                val result = corruptRoomId?.let(::corruptStatus) ?: emptyStatus()
                requireCoordinator().discardCorruptAuthority {
                    deleteResolvedRoomAndSecrets()
                }
                removeForegroundAndStop()
                return result
            }
            val status = getStatus()
            if (status["state"] != "corrupt") throw LanEngineException("invalid_configuration")
            requireCoordinator().discardCorruptAuthority {
                deleteResolvedRoomAndSecrets()
            }
            removeForegroundAndStop()
            return status
        }
        checkAvailable()
        if (mode != "cancel" && mode != "resign") throw LanEngineException("invalid_configuration")
        val coordinator = requireCoordinator()
        val status = LanHostResponseCodec.status(coordinator.closeRoom(mode), LanNetworkAddress.current())
        if (mode == "cancel") {
            coordinator.prepareCleanup(false)
            deleteResolvedRoomAndSecrets()
            removeForegroundAndStop()
        }
        return status
    }

    @Synchronized
    override fun stopCompletedRoom(allowMissingGuestAck: Boolean): Map<String, Any?> {
        checkAvailable()
        val status = LanHostResponseCodec.status(
            requireCoordinator().prepareCleanup(allowMissingGuestAck),
            LanNetworkAddress.current(),
        )
        deleteResolvedRoomAndSecrets()
        removeForegroundAndStop()
        return status
    }

    @Synchronized
    override fun onDestroy() {
        destroyed = true
        serviceReady.destroyed(this)
        startupExecutor.shutdownNow()
        try {
            coordinator?.stop()
        } catch (_: RuntimeException) {
            // Lifecycle teardown retains the journal and encrypted recovery bundle.
        }
        coordinator = null
        super.onDestroy()
    }

    override fun toString(): String = "LanHostService(runtime=<redacted>, foreground=$foreground)"

    private fun checkNotDestroyed() {
        if (destroyed) throw LanEngineException("internal_error")
    }

    private fun checkAvailable() {
        checkNotDestroyed()
        if (startupFailure) throw LanEngineException("internal_error")
    }

    private fun ensureCoordinator(): LanHostCoordinator = coordinator ?: run {
        val root = engineRoot()
        LanHostCoordinator(GoLanHostEngine(root.path), secretStore).also { coordinator = it }
    }

    private fun requireCoordinator(): LanHostCoordinator = coordinator ?: throw LanEngineException("not_running")

    private fun showForegroundBeforeEngine() {
        val notificationManager = getSystemService(NotificationManager::class.java)
        notificationManager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "局域网对局",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "保持面对面局域网对局连接"
                setShowBadge(false)
            },
        )
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification: Notification = NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("正在主持局域网对局")
            .setContentText("同一局域网内的玩家可以加入")
            .setContentIntent(openApp)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
        foreground = true
    }

    private fun removeForegroundAndStop(startId: Int? = null) {
        demoteForeground()
        if (startId == null) stopSelf() else stopSelf(startId)
    }

    private fun demoteForeground() {
        if (foreground) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            foreground = false
        }
    }

    private fun corruptStatus(roomId: String): Map<String, Any?> = linkedMapOf(
        "schemaVersion" to 1,
        "state" to "corrupt",
        "roomId" to roomId,
        "port" to 0,
        "gameRevision" to 0L,
        "endpointChanged" to false,
        "endpoint" to null,
    )

    private fun emptyStatus(): Map<String, Any?> = linkedMapOf(
        "schemaVersion" to 1,
        "state" to "empty",
        "roomId" to null,
        "port" to 0,
        "gameRevision" to 0L,
        "endpointChanged" to false,
        "endpoint" to null,
    )

    private fun deleteResolvedRoomAndSecrets() {
        requireCoordinator().deleteActiveRoom()
        secretStore.delete()
    }

    private fun engineRoot(): File {
        val noBackupRoot = noBackupFilesDir.canonicalFile
        val root = File(noBackupRoot, ENGINE_ROOT_NAME).absoluteFile
        check(root.parentFile == noBackupRoot)
        return root
    }

    private fun activeRoomRoot(): File {
        val engineRoot = engineRoot()
        val activeRoom = File(engineRoot, ACTIVE_ROOM_NAME).absoluteFile
        check(activeRoom.parentFile == engineRoot)
        return activeRoom
    }

    companion object {
        internal const val NOTIFICATION_ID = 0x4c414e
        internal val serviceReady = LanHostServiceReadyBarrier()
        private const val NOTIFICATION_CHANNEL_ID = "lan_host_active"
        private const val ACTION_COMMAND = "me.zqydev.gamebox.action.LAN_HOST_COMMAND"
        private const val ACTION_RECOVER = "me.zqydev.gamebox.action.LAN_HOST_RECOVER"
        private const val ENGINE_ROOT_NAME = "lan_host_engine"
        private const val ACTIVE_ROOM_NAME = "active_room"

        internal fun commandIntent(context: Context): Intent =
            Intent(context, LanHostService::class.java).setAction(ACTION_COMMAND)

        internal fun recoverIntent(context: Context): Intent =
            Intent(context, LanHostService::class.java).setAction(ACTION_RECOVER)
    }
}

internal object LanCorruptRoomIdentity {
    private const val MAX_MANIFEST_BYTES = 64 * 1024
    private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
    private val FIELDS = setOf(
        "schemaVersion",
        "roomId",
        "gameId",
        "createdAt",
        "endpoint",
        "journalFormatVersion",
        "journalSequence",
    )

    internal data class FileMetadata(
        val regular: Boolean,
        val ownerMatches: Boolean,
        val size: Long,
        val device: Long,
        val inode: Long,
    )

    fun read(file: File): String? = try {
        val pathStat = Os.lstat(file.path)
        val initial = FileMetadata(
            regular = OsConstants.S_ISREG(pathStat.st_mode),
            ownerMatches = pathStat.st_uid == Process.myUid(),
            size = pathStat.st_size,
            device = pathStat.st_dev,
            inode = pathStat.st_ino,
        )
        readVerified(initial) { maximum, expected ->
            val descriptor = Os.open(
                file.path,
                OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or
                    OsConstants.O_NOFOLLOW or OsConstants.O_NONBLOCK,
                0,
            )
            try {
                val descriptorStat = Os.fstat(descriptor)
                val descriptorMetadata = FileMetadata(
                    regular = OsConstants.S_ISREG(descriptorStat.st_mode),
                    ownerMatches = descriptorStat.st_uid == Process.myUid(),
                    size = descriptorStat.st_size,
                    device = descriptorStat.st_dev,
                    inode = descriptorStat.st_ino,
                )
                if (descriptorMetadata != expected) {
                    return@readVerified ByteArray(0) to descriptorMetadata
                }
                val bytes = ByteArray(maximum + 1)
                var size = 0
                while (size < bytes.size) {
                    val read = Os.read(descriptor, bytes, size, bytes.size - size)
                    if (read <= 0) break
                    size += read
                }
                bytes.copyOf(size) to descriptorMetadata
            } finally {
                Os.close(descriptor)
            }
        }
    } catch (_: Exception) {
        null
    }

    internal fun readVerified(
        initial: FileMetadata,
        reader: (maximum: Int, expected: FileMetadata) -> Pair<ByteArray, FileMetadata>,
    ): String? {
        if (!initial.regular || !initial.ownerMatches || initial.size !in 1..MAX_MANIFEST_BYTES.toLong()) {
            return null
        }
        val (bytes, descriptor) = reader(MAX_MANIFEST_BYTES, initial)
        if (descriptor != initial || bytes.size.toLong() != initial.size) return null
        return decode(bytes)
    }

    internal fun decode(bytes: ByteArray): String? = try {
        if (bytes.size !in 1..MAX_MANIFEST_BYTES) return null
        val decoded = FlatJsonParser(bytes.toString(Charsets.UTF_8), MAX_MANIFEST_BYTES).parse()
        if (decoded.keys != FIELDS || decoded["schemaVersion"] != 1L || decoded["gameId"] != "gomoku") return null
        val roomId = decoded["roomId"] as? String ?: return null
        val createdAt = decoded["createdAt"] as? Long ?: return null
        val endpoint = decoded["endpoint"] as? String ?: return null
        val journalFormatVersion = decoded["journalFormatVersion"] as? Long ?: return null
        val journalSequence = decoded["journalSequence"] as? Long ?: return null
        val port = endpoint.removePrefix("0.0.0.0:").takeIf { endpoint.startsWith("0.0.0.0:") }
            ?.toIntOrNull() ?: return null
        if (!LanHostResponseCodec.isCanonicalUUID(roomId) || createdAt !in 1..MAX_SAFE_INTEGER ||
            port !in 49152..65535 || endpoint != "0.0.0.0:$port" ||
            journalFormatVersion != 1L || journalSequence !in 1..MAX_SAFE_INTEGER
        ) {
            return null
        }
        roomId
    } catch (_: RuntimeException) {
        null
    }
}

internal object LanHostResponseCodec {
    private const val MAX_JSON_BYTES = 64 * 1024
    private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
    private val STATUS_FIELDS = setOf(
        "schemaVersion",
        "state",
        "roomId",
        "port",
        "gameRevision",
        "endpointChanged",
    )
    private val LAUNCH_FIELDS = setOf(
        "schemaVersion",
        "matchId",
        "gameId",
        "launchTicket",
        "wsUrl",
        "expiresAt",
    )
    private val STATES = setOf("waiting", "active", "finished", "cancelled", "corrupt")

    fun status(json: String, privateAddress: String?): Map<String, Any?> {
        require(privateAddress == null || isPrivateIPv4(privateAddress))
        val decoded = FlatJsonParser(json, MAX_JSON_BYTES).parse()
        require(decoded["schemaVersion"] == 1L)
        val state = decoded["state"] as? String ?: throw IllegalArgumentException("invalid status")
        if (state == "empty") {
            require(decoded.keys == setOf("schemaVersion", "state"))
            return linkedMapOf(
                "schemaVersion" to 1,
                "state" to "empty",
                "roomId" to null,
                "port" to 0,
                "gameRevision" to 0L,
                "endpointChanged" to false,
                "endpoint" to null,
            )
        }
        require(state in STATES && decoded.keys == STATUS_FIELDS)
        val rawRoomId = decoded["roomId"] as? String ?: throw IllegalArgumentException("invalid room id")
        val portLong = decoded["port"] as? Long ?: throw IllegalArgumentException("invalid port")
        val revision = decoded["gameRevision"] as? Long ?: throw IllegalArgumentException("invalid revision")
        val endpointChanged = decoded["endpointChanged"] as? Boolean
            ?: throw IllegalArgumentException("invalid endpoint flag")
        require(revision in 0..MAX_SAFE_INTEGER)
        if (state == "corrupt") {
            require(isCanonicalUUID(rawRoomId) && portLong == 0L && revision == 0L && !endpointChanged)
        } else {
            require(UUID.fromString(rawRoomId).toString() == rawRoomId)
            require(portLong in 49152..65535)
        }
        val port = portLong.toInt()
        return linkedMapOf(
            "schemaVersion" to 1,
            "state" to state,
            "roomId" to rawRoomId,
            "port" to port,
            "gameRevision" to revision,
            "endpointChanged" to endpointChanged,
            "endpoint" to if (privateAddress != null && port != 0) "$privateAddress:$port" else null,
        )
    }

    fun launch(json: String): Map<String, Any?> {
        val decoded = FlatJsonParser(json, MAX_JSON_BYTES).parse()
        require(decoded.keys == LAUNCH_FIELDS && decoded["schemaVersion"] == 1L)
        val matchId = decoded["matchId"] as? String ?: throw IllegalArgumentException("invalid match id")
        require(UUID.fromString(matchId).toString() == matchId)
        val gameId = decoded["gameId"] as? String
        val ticket = decoded["launchTicket"] as? String
        val wsUrl = decoded["wsUrl"] as? String
        val expiresAt = decoded["expiresAt"] as? Long
        require(gameId == "gomoku")
        require(ticket != null && isCanonicalCredential(ticket))
        require(wsUrl != null && isCanonicalLoopbackWS(wsUrl))
        require(expiresAt != null && expiresAt in 1..MAX_SAFE_INTEGER)
        return linkedMapOf(
            "schemaVersion" to 1,
            "matchId" to matchId,
            "gameId" to gameId,
            "launchTicket" to ticket,
            "wsUrl" to wsUrl,
            "expiresAt" to expiresAt,
        )
    }

    internal fun isCanonicalLoopbackWS(value: String): Boolean = try {
        val uri = URI(value)
        uri.scheme == "ws" && uri.host == "127.0.0.1" && uri.userInfo == null &&
            uri.port in 49152..65535 && uri.path == "/lan/v1/ws" &&
            uri.rawQuery == null && uri.rawFragment == null &&
            value == "ws://127.0.0.1:${uri.port}/lan/v1/ws"
    } catch (_: IllegalArgumentException) {
        false
    }

    internal fun isCanonicalCredential(value: String): Boolean =
        value.length == 43 && value.take(42).all { it.isBase64URL() } &&
            value.last() in "AEIMQUYcgkosw048"

    internal fun isCanonicalUUID(value: String): Boolean = try {
        UUID.fromString(value).toString() == value
    } catch (_: IllegalArgumentException) {
        false
    }

    internal fun isPrivateIPv4(value: String): Boolean {
        val octets = value.split('.')
        if (octets.size != 4) return false
        val numbers = octets.map { octet ->
            if (octet.isEmpty() || (octet.length > 1 && octet.startsWith('0')) || octet.any { !it.isDigit() }) {
                return false
            }
            octet.toIntOrNull()?.takeIf { it in 0..255 } ?: return false
        }
        return numbers[0] == 10 ||
            (numbers[0] == 172 && numbers[1] in 16..31) ||
            (numbers[0] == 192 && numbers[1] == 168)
    }

    private fun Char.isBase64URL(): Boolean =
        this in 'A'..'Z' || this in 'a'..'z' || this in '0'..'9' || this == '-' || this == '_'
}

private class FlatJsonParser(
    private val input: String,
    maximumBytes: Int,
) {
    private var index = 0

    init {
        require(input.isNotEmpty() && input.toByteArray(Charsets.UTF_8).size <= maximumBytes)
    }

    fun parse(): Map<String, Any?> {
        skipWhitespace()
        require(take() == '{')
        val result = linkedMapOf<String, Any?>()
        skipWhitespace()
        if (peek() == '}') {
            index++
        } else {
            while (true) {
                skipWhitespace()
                val key = parseString()
                require(!result.containsKey(key))
                skipWhitespace()
                require(take() == ':')
                skipWhitespace()
                result[key] = parseValue()
                skipWhitespace()
                when (take()) {
                    '}' -> break
                    ',' -> Unit
                    else -> throw IllegalArgumentException("invalid JSON object")
                }
            }
        }
        skipWhitespace()
        require(index == input.length)
        return result
    }

    private fun parseValue(): Any? = when (peek()) {
        '"' -> parseString()
        't' -> parseLiteral("true", true)
        'f' -> parseLiteral("false", false)
        'n' -> parseLiteral("null", null)
        in '0'..'9' -> parseInteger()
        else -> throw IllegalArgumentException("invalid JSON value")
    }

    private fun parseInteger(): Long {
        val start = index
        if (peek() == '0') {
            index++
            require(index == input.length || input[index] !in '0'..'9')
        } else {
            while (index < input.length && input[index] in '0'..'9') index++
        }
        return input.substring(start, index).toLongOrNull()
            ?: throw IllegalArgumentException("invalid JSON integer")
    }

    private fun parseString(): String {
        require(take() == '"')
        val result = StringBuilder()
        while (index < input.length) {
            val character = take()
            when {
                character == '"' -> return result.toString()
                character == '\\' -> {
                    when (val escaped = take()) {
                        '"', '\\', '/' -> result.append(escaped)
                        'b' -> result.append('\b')
                        'f' -> result.append('\u000c')
                        'n' -> result.append('\n')
                        'r' -> result.append('\r')
                        't' -> result.append('\t')
                        'u' -> {
                            require(index + 4 <= input.length)
                            val code = input.substring(index, index + 4).toIntOrNull(16)
                                ?: throw IllegalArgumentException("invalid JSON escape")
                            result.append(code.toChar())
                            index += 4
                        }
                        else -> throw IllegalArgumentException("invalid JSON escape")
                    }
                }
                character < ' ' -> throw IllegalArgumentException("invalid JSON string")
                else -> result.append(character)
            }
        }
        throw IllegalArgumentException("unterminated JSON string")
    }

    private fun <T> parseLiteral(text: String, value: T): T {
        require(input.regionMatches(index, text, 0, text.length))
        index += text.length
        return value
    }

    private fun skipWhitespace() {
        while (index < input.length && input[index] in listOf(' ', '\t', '\n', '\r')) index++
    }

    private fun peek(): Char = input.getOrNull(index) ?: throw IllegalArgumentException("unexpected end")

    private fun take(): Char = peek().also { index++ }
}
