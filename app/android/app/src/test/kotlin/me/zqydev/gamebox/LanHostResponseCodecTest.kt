package me.zqydev.gamebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class LanHostResponseCodecTest {
    @Test
    fun `status normalizes empty and running Go responses to one exact map`() {
        assertEquals(
            linkedMapOf<String, Any?>(
                "schemaVersion" to 1,
                "state" to "empty",
                "roomId" to null,
                "port" to 0,
                "gameRevision" to 0L,
                "endpointChanged" to false,
                "endpoint" to null,
            ),
            LanHostResponseCodec.status("{\"schemaVersion\":1,\"state\":\"empty\"}", "192.168.1.4"),
        )
        assertEquals(
            "192.168.1.4:50000",
            LanHostResponseCodec.status(
                "{\"schemaVersion\":1,\"state\":\"waiting\",\"roomId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\",\"port\":50000,\"gameRevision\":0,\"endpointChanged\":false}",
                "192.168.1.4",
            )["endpoint"],
        )
        assertNull(
            LanHostResponseCodec.status(
                "{\"schemaVersion\":1,\"state\":\"waiting\",\"roomId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\",\"port\":50000,\"gameRevision\":0,\"endpointChanged\":false}",
                null,
            )["endpoint"],
        )
        assertEquals(
            linkedMapOf<String, Any?>(
                "schemaVersion" to 1,
                "state" to "corrupt",
                "roomId" to "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "port" to 0,
                "gameRevision" to 0L,
                "endpointChanged" to false,
                "endpoint" to null,
            ),
            LanHostResponseCodec.status(
                "{\"schemaVersion\":1,\"state\":\"corrupt\",\"roomId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\",\"port\":0,\"gameRevision\":0,\"endpointChanged\":false}",
                null,
            ),
        )
    }

    @Test
    fun `launch response stays exact and credential values are not formatted`() {
        val ticket = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        val result = LanHostResponseCodec.launch(
            "{\"schemaVersion\":1,\"matchId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\",\"gameId\":\"gomoku\",\"launchTicket\":\"$ticket\",\"wsUrl\":\"ws://127.0.0.1:50000/lan/v1/ws\",\"expiresAt\":60000}",
        )

        assertEquals(
            setOf("schemaVersion", "matchId", "gameId", "launchTicket", "wsUrl", "expiresAt"),
            result.keys,
        )
        assertEquals(ticket, result["launchTicket"])
    }

    @Test
    fun `launch accepts exact loopback high-port boundaries and canonical raw base64url`() {
        listOf(49152, 49199, 65535).forEach { port ->
            assertEquals(
                "ws://127.0.0.1:$port/lan/v1/ws",
                LanHostResponseCodec.launch(
                    "{\"schemaVersion\":1,\"matchId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"," +
                        "\"gameId\":\"gomoku\",\"launchTicket\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"," +
                        "\"wsUrl\":\"ws://127.0.0.1:$port/lan/v1/ws\",\"expiresAt\":60000}",
                )["wsUrl"],
            )
        }
        "AEIMQUYcgkosw048".forEach { ending ->
            assertEquals(
                ending,
                (LanHostResponseCodec.launch(
                    "{\"schemaVersion\":1,\"matchId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"," +
                        "\"gameId\":\"gomoku\",\"launchTicket\":\"${"A".repeat(42)}$ending\"," +
                        "\"wsUrl\":\"ws://127.0.0.1:50000/lan/v1/ws\",\"expiresAt\":60000}",
                )["launchTicket"] as String).last(),
            )
        }
    }

    @Test
    fun `launch rejects noncanonical credentials and nonloopback URLs`() {
        val urls = listOf(
            "ws://127.0.0.1:49151/lan/v1/ws",
            "ws://127.0.0.1:65536/lan/v1/ws",
            "ws://localhost:50000/lan/v1/ws",
            "ws://192.168.1.2:50000/lan/v1/ws",
            "ws://user@127.0.0.1:50000/lan/v1/ws",
            "ws://127.0.0.1:50000/lan/v1/ws?ticket=x",
        )
        urls.forEach { url ->
            assertThrows(IllegalArgumentException::class.java) {
                launch(url, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
            }
        }
        listOf(
            "A".repeat(42),
            "A".repeat(44),
            "A".repeat(42) + "=",
            "A".repeat(42) + "+",
            "A".repeat(42) + "/",
            "A".repeat(42) + "\n",
        ).forEach { ticket ->
            assertThrows(IllegalArgumentException::class.java) {
                launch("ws://127.0.0.1:50000/lan/v1/ws", ticket)
            }
        }
    }

    @Test
    fun `status rejects any advertised address outside RFC1918 IPv4`() {
        listOf("127.0.0.1", "169.254.1.1", "8.8.8.8", "100.64.0.1", "::1", "192.168.1.2:1").forEach { address ->
            assertThrows(IllegalArgumentException::class.java) {
                LanHostResponseCodec.status(
                    "{\"schemaVersion\":1,\"state\":\"waiting\",\"roomId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\",\"port\":50000,\"gameRevision\":0,\"endpointChanged\":false}",
                    address,
                )
            }
        }
    }

    @Test
    fun `flat decoder rejects duplicates unknown fields trailing values floats and oversize`() {
        val invalid = listOf(
            "{\"schemaVersion\":1,\"state\":\"empty\",\"state\":\"empty\"}",
            "{\"schemaVersion\":1,\"state\":\"empty\",\"extra\":true}",
            "{\"schemaVersion\":1.0,\"state\":\"empty\"}",
            "{\"schemaVersion\":1,\"state\":\"empty\"}{}",
            "{\"schemaVersion\":1,\"state\":\"unknown\"}",
            "x".repeat(64 * 1024 + 1),
        )

        invalid.forEach { json ->
            assertThrows(IllegalArgumentException::class.java) {
                LanHostResponseCodec.status(json, null)
            }
        }
    }

    private fun launch(url: String, ticket: String) = LanHostResponseCodec.launch(
        "{\"schemaVersion\":1,\"matchId\":\"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\"," +
            "\"gameId\":\"gomoku\",\"launchTicket\":\"$ticket\",\"wsUrl\":\"$url\",\"expiresAt\":60000}",
    )
}
