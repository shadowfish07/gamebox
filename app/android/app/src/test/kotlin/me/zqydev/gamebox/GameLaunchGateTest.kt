package me.zqydev.gamebox

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GameLaunchGateTest {
    @Test
    fun `overlap is rejected until a real return`() {
        val gate = GameLaunchGate()

        assertTrue(gate.tryBeginLaunch(gameProcessRunning = false))
        assertFalse(gate.tryBeginLaunch(gameProcessRunning = false))
        assertTrue(gate.isActive)

        gate.onHostResumed(gameProcessRunning = true)
        assertFalse(gate.tryBeginLaunch(gameProcessRunning = true))

        gate.onHostResumed(gameProcessRunning = false)
        assertTrue(gate.tryBeginLaunch(gameProcessRunning = false))
    }

    @Test
    fun `failed start releases launch gate`() {
        val gate = GameLaunchGate()

        assertTrue(gate.tryBeginLaunch(gameProcessRunning = false))
        gate.onLaunchFailed()

        assertFalse(gate.isActive)
        assertTrue(gate.tryBeginLaunch(gameProcessRunning = false))
    }

    @Test
    fun `host resume synchronizes active state after main process recreation`() {
        val recreatedGate = GameLaunchGate()

        recreatedGate.onHostResumed(gameProcessRunning = true)

        assertTrue(recreatedGate.isActive)
        assertFalse(recreatedGate.tryBeginLaunch(gameProcessRunning = true))
    }

    @Test
    fun `stale active state refreshes after the lease has ended`() {
        val gate = GameLaunchGate()
        gate.onHostResumed(gameProcessRunning = true)

        assertTrue(gate.tryBeginLaunch(gameProcessRunning = false))
    }
}
