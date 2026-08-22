package me.zqydev.gamebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GameLaunchGateTest {
    @Test
    fun `running game is resumed without starting a second engine`() {
        val gate = GameLaunchGate()

        assertEquals(
            GameLaunchGate.Decision.START_NEW,
            gate.requestLaunch(gameProcessRunning = false),
        )
        assertEquals(
            GameLaunchGate.Decision.REJECT,
            gate.requestLaunch(gameProcessRunning = false),
        )
        assertTrue(gate.isActive)

        gate.onHostResumed(gameProcessRunning = true)
        assertEquals(
            GameLaunchGate.Decision.RESUME_ACTIVE,
            gate.requestLaunch(gameProcessRunning = true),
        )

        gate.onHostResumed(gameProcessRunning = false)
        assertEquals(
            GameLaunchGate.Decision.START_NEW,
            gate.requestLaunch(gameProcessRunning = false),
        )
    }

    @Test
    fun `failed start releases launch gate`() {
        val gate = GameLaunchGate()

        assertEquals(
            GameLaunchGate.Decision.START_NEW,
            gate.requestLaunch(gameProcessRunning = false),
        )
        gate.onLaunchFailed()

        assertFalse(gate.isActive)
        assertEquals(
            GameLaunchGate.Decision.START_NEW,
            gate.requestLaunch(gameProcessRunning = false),
        )
    }

    @Test
    fun `host resume synchronizes active state after main process recreation`() {
        val recreatedGate = GameLaunchGate()

        recreatedGate.onHostResumed(gameProcessRunning = true)

        assertTrue(recreatedGate.isActive)
        assertEquals(
            GameLaunchGate.Decision.RESUME_ACTIVE,
            recreatedGate.requestLaunch(gameProcessRunning = true),
        )
    }

    @Test
    fun `stale active state refreshes after the lease has ended`() {
        val gate = GameLaunchGate()
        gate.onHostResumed(gameProcessRunning = true)

        assertEquals(
            GameLaunchGate.Decision.START_NEW,
            gate.requestLaunch(gameProcessRunning = false),
        )
    }
}
