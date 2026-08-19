package me.zqydev.gamebox

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GameLaunchGateTest {
    @Test
    fun `overlap is rejected until a real return`() {
        val gate = GameLaunchGate()

        assertTrue(gate.tryBeginLaunch())
        assertFalse(gate.tryBeginLaunch())
        assertTrue(gate.isActive)

        gate.onHostResumed(gameProcessRunning = true)
        assertFalse(gate.tryBeginLaunch())

        gate.onHostResumed(gameProcessRunning = false)
        assertTrue(gate.tryBeginLaunch())
    }

    @Test
    fun `failed start releases launch gate`() {
        val gate = GameLaunchGate()

        assertTrue(gate.tryBeginLaunch())
        gate.onLaunchFailed()

        assertFalse(gate.isActive)
        assertTrue(gate.tryBeginLaunch())
    }
}
