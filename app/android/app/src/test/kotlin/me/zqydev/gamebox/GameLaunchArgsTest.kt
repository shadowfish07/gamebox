package me.zqydev.gamebox

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class GameLaunchArgsTest {
    private val ticket = "opaque-secret-ticket"

    @Test
    fun `normal launch builds exact Godot user arguments`() {
        val result = GameLaunchArgs.fromNative(
            mapOf(
                "gameId" to "gomoku",
                "matchId" to "550e8400-e29b-41d4-a716-446655440000",
                "launchTicket" to ticket,
                "wsUrl" to "wss://gamebox.example.com/matches/550e8400",
            ),
        )

        assertTrue(result is GameLaunchArgs.ParseResult.Success)
        assertArrayEquals(
            arrayOf(
                "--",
                "--game-id",
                "gomoku",
                "--match-id",
                "550e8400-e29b-41d4-a716-446655440000",
                "--launch-ticket",
                ticket,
                "--ws-url",
                "wss://gamebox.example.com/matches/550e8400",
            ),
            (result as GameLaunchArgs.ParseResult.Success).args.commandLineParams,
        )
    }

    @Test
    fun `host smoke builds exact Godot user arguments`() {
        assertArrayEquals(
            arrayOf("--", "--host-smoke", "--auto-exit-ms", "800"),
            GameLaunchArgs.hostSmoke().commandLineParams,
        )
    }

    @Test
    fun `invalid null blank and extra native fields are safely rejected`() {
        val valid = mapOf(
            "gameId" to "gomoku",
            "matchId" to "550e8400-e29b-41d4-a716-446655440000",
            "launchTicket" to ticket,
            "wsUrl" to "wss://gamebox.example.com",
        )
        val invalidInputs = listOf<Any?>(
            null,
            "not-a-map",
            valid - "gameId",
            valid + ("extra" to "value"),
            valid + ("gameId" to ""),
            valid + ("matchId" to "   "),
            valid + ("launchTicket" to null),
            valid + ("wsUrl" to 42),
        )

        invalidInputs.forEach { input ->
            val result = runCatching { GameLaunchArgs.fromNative(input) }
            assertTrue("native validation must not throw", result.isSuccess)
            assertSame(GameLaunchArgs.ParseResult.Invalid, result.getOrNull())
            assertFalse(result.toString().contains(ticket))
            assertFalse(result.exceptionOrNull()?.message.orEmpty().contains(ticket))
        }
    }

    @Test
    fun `builder result and launch args strings never expose ticket`() {
        val result = GameLaunchArgs.fromNative(
            mapOf(
                "gameId" to "gomoku",
                "matchId" to "550e8400-e29b-41d4-a716-446655440000",
                "launchTicket" to ticket,
                "wsUrl" to "wss://gamebox.example.com",
            ),
        )

        assertFalse(result.toString().contains(ticket))
        val args = (result as GameLaunchArgs.ParseResult.Success).args
        assertFalse(args.toString().contains(ticket))
    }

    @Test
    fun `command line reads are defensive clones`() {
        val args = GameLaunchArgs.hostSmoke()
        val firstRead = args.commandLineParams

        firstRead[1] = "mutated"

        assertArrayEquals(
            arrayOf("--", "--host-smoke", "--auto-exit-ms", "800"),
            args.commandLineParams,
        )
    }
}
