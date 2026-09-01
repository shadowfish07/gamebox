package me.zqydev.gamebox

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanHostAarSmokeTest {
    @Test
    fun realAarMoveSurvivesServiceStopAndRestartBeforeExplicitCleanup() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.POST_NOTIFICATIONS,
        )
        val notifications = context.getSystemService(NotificationManager::class.java)
        val initial = start(context)
        val created = initial.createRoom("Host")
        val roomId = requireNotNull(created["roomId"] as? String)
        val port = requireNotNull(created["port"] as? Int)
        val secrets = requireNotNull(LanSecretStore(context).load())
        assertEquals(roomId, secrets.roomId)
        waitUntil { notificationPresent(notifications) }

        val guestResume = canonicalToken()
        val join = httpJSON(
            port,
            "POST",
            "/lan/v1/rooms/$roomId/join",
            JSONObject()
                .put("roomId", roomId)
                .put("nickname", "Guest")
                .put("joinAttemptId", UUID.randomUUID().toString())
                .put("candidateResumeToken", guestResume)
                .put("roomKey", secrets.roomKey),
        )
        val hostLaunch = JSONObject(initial.issueHostLaunch())
        val initialHostTicket = hostLaunch.getString("launchTicket")
        val host = RawWebSocket.connect(
            port,
            initialHostTicket,
            secrets.hostResumeToken,
        )
        val guest = RawWebSocket.connect(port, join.getString("launchTicket"), guestResume)
        try {
            val hostSnapshot = host.readEnvelope("platform.snapshot")
            val guestSnapshot = guest.readEnvelope("platform.snapshot")
            assertEquals(0L, hostSnapshot.getLong("revision"))
            assertEquals(0L, guestSnapshot.getLong("revision"))
            val blackPlayerId = guestSnapshot.getJSONObject("payload").getString("blackUserId")
            val actor = if (blackPlayerId == join.getString("playerId")) guest else host
            actor.writeJSON(
                JSONObject()
                    .put("protocolVersion", 1)
                    .put("gameId", "gomoku")
                    .put("matchId", roomId)
                    .put("expectedRevision", 0)
                    .put("type", "gomoku.move.requested")
                    .put("actionId", UUID.randomUUID().toString())
                    .put("payload", JSONObject().put("x", 7).put("y", 7)),
            )
            for (peer in listOf(host, guest)) {
                val committed = peer.readEnvelope("gomoku.move.accepted")
                assertEquals(1L, committed.getLong("revision"))
            }
            host.writeJSON(snapshotRequest(roomId, 0))
            val committedSnapshot = host.readEnvelope("platform.snapshot")
            assertEquals(1L, committedSnapshot.getLong("revision"))
            val expectedBoard = committedSnapshot.getJSONObject("payload").getJSONArray("board").toString()
            assertTrue(committedSnapshot.getJSONObject("payload").getJSONArray("board").getInt(7 * 15 + 7) != 0)

            stopForRecovery(context, initial)
            host.assertClosed()
            guest.assertClosed()
            waitUntil { !canConnect(port) }
            val restored = start(context)
            val restoredStatus = restored.getStatus()
            assertEquals(roomId, restoredStatus["roomId"])
            assertEquals(1L, restoredStatus["gameRevision"])
            waitUntil { notificationPresent(notifications) }
            val restoredLaunch = JSONObject(restored.issueHostLaunch())
            assertTrue(restoredLaunch.getString("launchTicket") != initialHostTicket)
            RawWebSocket.connect(
                restoredStatus["port"] as Int,
                restoredLaunch.getString("launchTicket"),
                secrets.hostResumeToken,
            ).use { recoveredHost ->
                val recoveredSnapshot = recoveredHost.readEnvelope("platform.snapshot")
                assertEquals(1L, recoveredSnapshot.getLong("revision"))
                assertEquals(
                    expectedBoard,
                    recoveredSnapshot.getJSONObject("payload").getJSONArray("board").toString(),
                )
            }

            val finished = restored.closeRoom("resign")
            assertEquals("finished", finished["state"])
            val recoveredPort = restoredStatus["port"] as Int
            val result = httpJSON(
                recoveredPort,
                "GET",
                "/lan/v1/rooms/$roomId/result",
                JSONObject().put("resumeToken", secrets.hostResumeToken),
            )
            httpJSON(
                recoveredPort,
                "POST",
                "/lan/v1/rooms/$roomId/result-ack",
                JSONObject()
                    .put("resumeToken", secrets.hostResumeToken)
                    .put("resultHash", result.getString("resultHash")),
            )
            restored.stopCompletedRoom(true)
            waitUntil { !notificationPresent(notifications) }
            assertFalse(LanSecretStore(context).hasStoredBlob())
            Log.i("LanHostAarSmoke", "LAN_AAR_SMOKE roomId=$roomId revision=1 state=active")
        } finally {
            host.close()
            guest.close()
        }
    }

    private fun start(context: Context): LanHostCommands {
        LanHostService.serviceReady.prepareStart()
        ContextCompat.startForegroundService(context, LanHostService.commandIntent(context))
        return requireNotNull(LanHostService.serviceReady.await(10_000))
    }

    private fun stopForRecovery(context: Context, commands: LanHostCommands) {
        assertTrue(context.stopService(Intent(context, LanHostService::class.java)))
        waitUntil { LanHostService.serviceReady.current() !== commands }
    }

    private fun notificationPresent(manager: NotificationManager): Boolean =
        manager.activeNotifications.any { it.id == LanHostService.NOTIFICATION_ID }

    private fun canConnect(port: Int): Boolean = try {
        Socket().use { socket -> socket.connect(java.net.InetSocketAddress("127.0.0.1", port), 100) }
        true
    } catch (_: Exception) {
        false
    }

    private fun waitUntil(predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!predicate() && System.nanoTime() < deadline) Thread.yield()
        assertTrue(predicate())
    }

    private fun canonicalToken(): String =
        Base64.encodeToString(ByteArray(32).also(SecureRandom()::nextBytes), Base64.NO_WRAP or Base64.URL_SAFE or Base64.NO_PADDING)

    private fun snapshotRequest(roomId: String, revision: Int): JSONObject =
        JSONObject()
            .put("protocolVersion", 1)
            .put("gameId", "gomoku")
            .put("matchId", roomId)
            .put("type", "platform.snapshot.requested")
            .put("payload", JSONObject().put("currentRevision", revision))

    private fun httpJSON(port: Int, method: String, path: String, body: JSONObject): JSONObject {
        val encoded = body.toString().toByteArray(StandardCharsets.UTF_8)
        Socket("127.0.0.1", port).use { socket ->
            socket.soTimeout = 5_000
            val output = BufferedOutputStream(socket.getOutputStream())
            val headers = "$method $path HTTP/1.1\r\n" +
                "Host: 127.0.0.1:$port\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: ${encoded.size}\r\n" +
                "Connection: close\r\n\r\n"
            output.write(headers.toByteArray(StandardCharsets.US_ASCII))
            output.write(encoded)
            output.flush()
            val response = readBounded(BufferedInputStream(socket.getInputStream()), 64 * 1024)
            val split = response.indexOfSubsequence("\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
            check(split > 0)
            val headersText = response.copyOfRange(0, split).toString(StandardCharsets.US_ASCII)
            check(headersText.startsWith("HTTP/1.1 200 "))
            return JSONObject(response.copyOfRange(split + 4, response.size).toString(StandardCharsets.UTF_8))
        }
    }

    private fun readBounded(input: BufferedInputStream, maximum: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(4096)
        while (output.size() <= maximum) {
            val read = input.read(buffer)
            if (read < 0) break
            output.write(buffer, 0, read)
        }
        check(output.size() <= maximum)
        return output.toByteArray()
    }

    private fun ByteArray.indexOfSubsequence(needle: ByteArray): Int {
        for (index in 0..size - needle.size) {
            if (needle.indices.all { this[index + it] == needle[it] }) return index
        }
        return -1
    }

    private class RawWebSocket private constructor(private val socket: Socket) : AutoCloseable {
        private val input = BufferedInputStream(socket.getInputStream())
        private val output = BufferedOutputStream(socket.getOutputStream())
        private val random = SecureRandom()

        fun writeJSON(value: JSONObject) {
            writeFrame(0x1, value.toString().toByteArray(StandardCharsets.UTF_8))
        }

        fun readEnvelope(expectedType: String): JSONObject {
            while (true) {
                val (opcode, payload) = readFrame()
                if (opcode == 0x9) {
                    writeFrame(0xA, payload)
                    continue
                }
                check(opcode == 0x1)
                val envelope = JSONObject(payload.toString(StandardCharsets.UTF_8))
                check(envelope.getString("type") == expectedType)
                return envelope
            }
        }

        fun assertClosed() {
            val closed = runCatching {
                val (opcode, _) = readFrame()
                opcode == 0x8
            }.getOrDefault(true)
            check(closed)
        }

        override fun close() {
            runCatching { socket.close() }
        }

        private fun writeFrame(opcode: Int, payload: ByteArray) {
            check(payload.size <= 64 * 1024)
            output.write(0x80 or opcode)
            when {
                payload.size < 126 -> output.write(0x80 or payload.size)
                payload.size <= 0xffff -> {
                    output.write(0x80 or 126)
                    output.write(payload.size ushr 8)
                    output.write(payload.size)
                }
                else -> {
                    output.write(0x80 or 127)
                    output.write(ByteBuffer.allocate(8).putLong(payload.size.toLong()).array())
                }
            }
            val mask = ByteArray(4).also(random::nextBytes)
            output.write(mask)
            payload.forEachIndexed { index, byte -> output.write(byte.toInt() xor mask[index % 4].toInt()) }
            output.flush()
        }

        private fun readFrame(): Pair<Int, ByteArray> {
            val first = input.read()
            val second = input.read()
            check(first >= 0 && second >= 0 && first and 0x80 != 0 && second and 0x80 == 0)
            val length = when (val compact = second and 0x7f) {
                126 -> (input.read() shl 8) or input.read()
                127 -> {
                    val bytes = readExact(8)
                    val value = ByteBuffer.wrap(bytes).long
                    check(value in 0..64 * 1024L)
                    value.toInt()
                }
                else -> compact
            }
            check(length in 0..64 * 1024)
            return (first and 0xf) to readExact(length)
        }

        private fun readExact(size: Int): ByteArray {
            val result = ByteArray(size)
            var offset = 0
            while (offset < size) {
                val read = input.read(result, offset, size - offset)
                check(read > 0)
                offset += read
            }
            return result
        }

        companion object {
            fun connect(port: Int, launchTicket: String, resumeToken: String): RawWebSocket {
                val socket = Socket("127.0.0.1", port).apply { soTimeout = 5_000 }
                val webSocket = RawWebSocket(socket)
                val key = Base64.encodeToString(
                    ByteArray(16).also(SecureRandom()::nextBytes),
                    Base64.NO_WRAP,
                )
                val request = "GET /lan/v1/ws HTTP/1.1\r\n" +
                    "Host: 127.0.0.1:$port\r\n" +
                    "Upgrade: websocket\r\n" +
                    "Connection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: $key\r\n" +
                    "Sec-WebSocket-Version: 13\r\n\r\n"
                webSocket.output.write(request.toByteArray(StandardCharsets.US_ASCII))
                webSocket.output.flush()
                val headerBytes = ByteArrayOutputStream()
                var matched = 0
                val terminator = byteArrayOf(13, 10, 13, 10)
                while (matched < terminator.size && headerBytes.size() < 8192) {
                    val byte = webSocket.input.read()
                    check(byte >= 0)
                    headerBytes.write(byte)
                    matched = if (byte == terminator[matched].toInt()) matched + 1 else if (byte == 13) 1 else 0
                }
                val headers = headerBytes.toString(StandardCharsets.US_ASCII.name())
                check(headers.startsWith("HTTP/1.1 101 "))
                val expectedAccept = Base64.encodeToString(
                    MessageDigest.getInstance("SHA-1")
                        .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").toByteArray(StandardCharsets.US_ASCII)),
                    Base64.NO_WRAP,
                )
                check(headers.lineSequence().any {
                    it.substringBefore(':').equals("Sec-WebSocket-Accept", ignoreCase = true) &&
                        it.substringAfter(':').trim() == expectedAccept
                })
                webSocket.writeJSON(
                    JSONObject()
                        .put("protocolVersion", 1)
                        .put("type", "platform.connect")
                        .put(
                            "payload",
                            JSONObject()
                                .put("launchTicket", launchTicket)
                                .put("resumeToken", resumeToken),
                        ),
                )
                webSocket.readEnvelope("platform.connected")
                return webSocket
            }
        }
    }
}
