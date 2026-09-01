package me.zqydev.gamebox

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GameResultStoreTest {
    @Test
    fun `validator accepts canonical result and rejects duplicate or unknown fields`() {
        assertEquals(MATCH_ID, GameResultValidator.validate(VALID)?.matchId)
        assertFalse(GameResultValidator.validate(VALID.replace("\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1")) != null)
        assertFalse(GameResultValidator.validate(VALID.dropLast(1) + ",\"source\":\"lan\"}") != null)
    }

    @Test
    fun `committed store replaces atomically and filters corrupt files`() {
        val directory = Files.createTempDirectory("game-results").toFile()
        var directorySyncs = 0
        val store = AtomicResultStore(directory, ResultDirectorySync { directorySyncs += 1 })

        assertTrue(store.persist(VALID))
        assertTrue(store.persist(VALID))
        assertFalse(store.persist(VALID.replace("\"Alice\"", "\"Conflict\"")))
        directory.resolve("corrupt.json").writeText("not-json")

        assertEquals(listOf(VALID), store.list().map(StoredGameResult::raw))
        assertEquals(1, directorySyncs)
        assertFalse(directory.listFiles().orEmpty().any { it.extension == "tmp" })
    }

    @Test
    fun `pending marker is durable before result and only exact hash can complete`() {
        val root = Files.createTempDirectory("pending-results").toFile()
        val syncs = mutableListOf<String>()
        val pending = PendingGameResultStore(root.resolve("pending"), ResultDirectorySync { syncs += it.name })
        val committed = AtomicResultStore(root.resolve("committed"), ResultDirectorySync { syncs += it.name })
        val parsed = GameLaunchArgs.fromNative(
            mapOf(
                "gameId" to "gomoku",
                "matchId" to MATCH_ID,
                "launchTicket" to "ticket",
                "wsUrl" to "ws://192.168.1.2:49152/v1/ws",
                "source" to "lan",
                "resumeToken" to "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA",
                "localUserId" to "22222222-2222-4222-8222-222222222222",
            ),
        ) as GameLaunchArgs.ParseResult.Success

        assertTrue(pending.persist(parsed.args))
        assertTrue(committed.persist(VALID))
        assertEquals(listOf(root.name, "pending", root.name, "committed"), syncs)
        assertTrue(pending.list().single().matchId == MATCH_ID)
        assertEquals("22222222-2222-4222-8222-222222222222", pending.list().single().localUserId)
        assertFalse(pending.remove("../escape"))
        assertTrue(committed.get(MATCH_ID)?.sha256?.matches(Regex("^[0-9a-f]{64}$")) == true)
        assertTrue(pending.remove(MATCH_ID))
        assertEquals(listOf(root.name, "pending", root.name, "committed", "pending"), syncs)
    }

    @Test
    fun `pending store reads legacy version one markers without a local identity`() {
        val directory = Files.createTempDirectory("pending-results-v1").toFile()
        directory.resolve("$MATCH_ID.json").writeText(
            """{"schemaVersion":1,"matchId":"$MATCH_ID","gameId":"gomoku","source":"lan","endpointKind":"lan"}""",
        )

        val item = PendingGameResultStore(directory).list().single()

        assertEquals(MATCH_ID, item.matchId)
        assertEquals(null, item.localUserId)
    }

    private companion object {
        const val MATCH_ID = "11111111-1111-4111-8111-111111111111"
        const val VALID = """{"schemaVersion":1,"matchId":"$MATCH_ID","gameId":"gomoku","players":[{"userId":"22222222-2222-4222-8222-222222222222","nickname":"Alice","seat":0,"color":"black"},{"userId":"33333333-3333-4333-8333-333333333333","nickname":"Bob","seat":1,"color":"white"}],"winnerUserId":"22222222-2222-4222-8222-222222222222","result":"resignation","startedAt":1000,"finishedAt":2000,"finalRevision":1,"events":[{"revision":1,"type":"gomoku.resigned","actionId":"44444444-4444-4444-8444-444444444444","actorId":"33333333-3333-4333-8333-333333333333","payload":{},"committedAt":2000}]}"""
    }
}
