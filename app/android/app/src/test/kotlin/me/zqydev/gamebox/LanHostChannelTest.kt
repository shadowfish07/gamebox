package me.zqydev.gamebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LanHostChannelTest {
    @Test
    fun `six exact methods validate arguments and preserve versioned maps`() {
        val commands = FakeCommands()
        var starts = 0
        val dispatcher = LanHostCommandDispatcher({ commands }) { starts++ }

        assertSuccess(dispatcher.dispatch("getStatus", null), statusMap())
        assertSuccess(dispatcher.dispatch("createRoom", mapOf("nickname" to "Host")), createMap())
        assertSuccess(dispatcher.dispatch("issueHostLaunch", null), launchMap())
        assertSuccess(dispatcher.dispatch("refreshEndpoint", null), statusMap())
        assertSuccess(dispatcher.dispatch("closeRoom", mapOf("mode" to "cancel")), statusMap("cancelled"))
        assertSuccess(
            dispatcher.dispatch("stopCompletedRoom", mapOf("allowMissingGuestAck" to true)),
            statusMap("finished"),
        )
        assertEquals(3, starts)
        assertEquals(listOf("Host"), commands.nicknames)
        assertEquals(listOf("cancel"), commands.closeModes)
        assertEquals(listOf(true), commands.cleanupPolicies)
    }

    @Test
    fun `missing extra blank wrong-type and unknown calls are rejected`() {
        val dispatcher = LanHostCommandDispatcher({ FakeCommands() }) {}
        val invalid = listOf(
            "getStatus" to emptyMap<String, Any>(),
            "createRoom" to null,
            "createRoom" to emptyMap<String, Any>(),
            "createRoom" to mapOf("nickname" to "  "),
            "createRoom" to mapOf("nickname" to "Host", "extra" to true),
            "closeRoom" to mapOf("mode" to "discard"),
            "closeRoom" to mapOf("mode" to "resign", "extra" to true),
            "stopCompletedRoom" to mapOf("allowMissingGuestAck" to 1),
        )
        invalid.forEach { (method, arguments) ->
            assertEquals("invalid_arguments", (dispatcher.dispatch(method, arguments) as LanChannelReply.Failure).code)
        }
        assertTrue(dispatcher.dispatch("unknown", null) is LanChannelReply.NotImplemented)
    }

    @Test
    fun `invalid command result and exceptions never expose credentials`() {
        val credential = "private-room-key-canary"
        val badSchema = FakeCommands().apply { statusResult = statusMap() + ("extra" to credential) }
        val invalid = LanHostCommandDispatcher({ badSchema }) {}.dispatch("getStatus", null)
        assertEquals("invalid_response", (invalid as LanChannelReply.Failure).code)
        assertFalse(invalid.toString().contains(credential))

        val throwing = FakeCommands().apply { error = IllegalStateException("failed with $credential") }
        val failed = LanHostCommandDispatcher({ throwing }) {}.dispatch("getStatus", null)
        assertEquals("internal_error", (failed as LanChannelReply.Failure).code)
        assertFalse(failed.toString().contains(credential))
    }

    @Test
    fun `strict response unions reject wrong types noncanonical values and unsafe endpoints`() {
        val valid = statusMap()
        val invalidStatuses = listOf(
            valid + ("schemaVersion" to 1L),
            valid + ("state" to "unknown"),
            valid + ("roomId" to "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"),
            valid + ("port" to 50000L),
            valid + ("gameRevision" to 0),
            valid + ("endpointChanged" to 0),
            valid + ("endpoint" to "8.8.8.8:50000"),
            valid + ("endpoint" to "192.168.1.4:50001"),
            statusMap("empty") + ("roomId" to "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
            statusMap("corrupt") + ("roomId" to null),
            statusMap("corrupt") + ("port" to 50000),
        )
        invalidStatuses.forEach { response ->
            val commands = FakeCommands().apply { statusResult = response }
            assertEquals(
                "invalid_response",
                (LanHostCommandDispatcher({ commands }) {}.dispatch("getStatus", null) as LanChannelReply.Failure).code,
            )
        }

        val badLaunches = listOf(
            launchMap() + ("launchTicket" to "A".repeat(42)),
            launchMap() + ("wsUrl" to "ws://192.168.1.4:50000/lan/v1/ws"),
            launchMap() + ("expiresAt" to 60_000),
        )
        badLaunches.forEach { response ->
            val commands = FakeCommands().apply { launchResult = response }
            assertEquals(
                "invalid_response",
                (LanHostCommandDispatcher({ commands }) {}.dispatch("issueHostLaunch", null) as LanChannelReply.Failure).code,
            )
        }
    }

    @Test
    fun `unbound service has a stable credential-free failure`() {
        val reply = LanHostCommandDispatcher({ null }) {}.dispatch("getStatus", null)

        assertEquals("service_unavailable", (reply as LanChannelReply.Failure).code)
        assertEquals(null, reply.details)
    }

    private fun assertSuccess(reply: LanChannelReply, expected: Map<String, Any?>) {
        assertEquals(expected, (reply as LanChannelReply.Success).value)
    }

    private fun statusMap(state: String = "waiting") = if (state == "empty") {
        linkedMapOf<String, Any?>(
            "schemaVersion" to 1,
            "state" to state,
            "roomId" to null,
            "port" to 0,
            "gameRevision" to 0L,
            "endpointChanged" to false,
            "endpoint" to null,
        )
    } else if (state == "corrupt") {
        linkedMapOf(
            "schemaVersion" to 1,
            "state" to state,
            "roomId" to "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "port" to 0,
            "gameRevision" to 0L,
            "endpointChanged" to false,
            "endpoint" to null,
        )
    } else {
        linkedMapOf(
            "schemaVersion" to 1,
            "state" to state,
            "roomId" to "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "port" to 50000,
            "gameRevision" to if (state == "waiting") 0L else 2L,
            "endpointChanged" to false,
            "endpoint" to "192.168.1.4:50000",
        )
    }

    private fun createMap() = statusMap() + mapOf(
        "roomKey" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "joinExpiresAt" to 601_000L,
    )

    private fun launchMap() = linkedMapOf<String, Any?>(
        "schemaVersion" to 1,
        "matchId" to "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "gameId" to "gomoku",
        "launchTicket" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "wsUrl" to "ws://127.0.0.1:50000/lan/v1/ws",
        "expiresAt" to 60_000L,
    )

    private inner class FakeCommands : LanHostCommands {
        var statusResult: Map<String, Any?> = statusMap()
        var launchResult: Map<String, Any?> = launchMap()
        var error: RuntimeException? = null
        val nicknames = mutableListOf<String>()
        val closeModes = mutableListOf<String>()
        val cleanupPolicies = mutableListOf<Boolean>()

        override fun getStatus(): Map<String, Any?> = result(statusResult)

        override fun createRoom(nickname: String): Map<String, Any?> {
            nicknames += nickname
            return result(createMap())
        }

        override fun issueHostLaunch(): Map<String, Any?> = result(launchResult)

        override fun refreshEndpoint(): Map<String, Any?> = result(statusResult)

        override fun closeRoom(mode: String): Map<String, Any?> {
            closeModes += mode
            return result(statusMap("cancelled"))
        }

        override fun stopCompletedRoom(allowMissingGuestAck: Boolean): Map<String, Any?> {
            cleanupPolicies += allowMissingGuestAck
            return result(statusMap("finished"))
        }

        private fun result(value: Map<String, Any?>): Map<String, Any?> {
            error?.let { throw it }
            return value
        }
    }
}
