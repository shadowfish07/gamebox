package me.zqydev.gamebox

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GameResultBridgeTest {
    @Test
    fun durableResultRemainsIdempotentAcrossStoreRecreationAndPendingOrder() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val committedDirectory = File(context.filesDir, "game_results_test")
        val pendingDirectory = File(context.filesDir, "pending_game_results_test")
        committedDirectory.deleteRecursively()
        pendingDirectory.deleteRecursively()
        try {
            val parsed = GameLaunchArgs.fromNative(
                mapOf(
                    "gameId" to "gomoku",
                    "matchId" to MATCH_ID,
                    "launchTicket" to "opaque-ticket",
                    "wsUrl" to "ws://192.168.1.2:49152/v1/ws",
                    "source" to "lan",
                    "resumeToken" to "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA",
                    "localUserId" to "22222222-2222-4222-8222-222222222222",
                ),
            ) as GameLaunchArgs.ParseResult.Success
            val pending = PendingGameResultStore(pendingDirectory)
            assertTrue(pending.persist(parsed.args))
            assertEquals(MATCH_ID, pending.list().single().matchId)

            val committed = AtomicResultStore(committedDirectory)
            assertTrue(committed.persist(VALID))
            assertTrue(committed.persist(VALID))
            assertFalse(committed.persist(VALID.replace("\"Host\"", "\"Conflict\"")))
            assertEquals(MATCH_ID, pending.list().single().matchId)

            val reopened = AtomicResultStore(committedDirectory).get(MATCH_ID)
            assertNotNull(reopened)
            assertTrue(reopened!!.sha256.matches(Regex("^[0-9a-f]{64}$")))
            assertEquals(VALID, reopened.raw)
            assertTrue(pending.remove(MATCH_ID))
            assertTrue(PendingGameResultStore(pendingDirectory).list().isEmpty())
        } finally {
            committedDirectory.deleteRecursively()
            pendingDirectory.deleteRecursively()
        }
    }

    private companion object {
        const val MATCH_ID = "11111111-1111-4111-8111-111111111111"
        const val VALID = """{"schemaVersion":1,"matchId":"$MATCH_ID","gameId":"gomoku","players":[{"userId":"22222222-2222-4222-8222-222222222222","nickname":"Host","seat":0,"color":"black"},{"userId":"33333333-3333-4333-8333-333333333333","nickname":"Guest","seat":1,"color":"white"}],"winnerUserId":"22222222-2222-4222-8222-222222222222","result":"resignation","startedAt":1000,"finishedAt":2000,"finalRevision":1,"events":[{"revision":1,"type":"gomoku.resigned","actionId":"44444444-4444-4444-8444-444444444444","actorId":"33333333-3333-4333-8333-333333333333","payload":{},"committedAt":2000}]}"""
    }
}
