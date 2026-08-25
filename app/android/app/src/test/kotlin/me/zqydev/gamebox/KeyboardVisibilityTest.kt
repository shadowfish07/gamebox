package me.zqydev.gamebox

import org.junit.Assert.assertEquals
import org.junit.Test

class KeyboardVisibilityTest {
    @Test
    fun `parses an explicitly shown keyboard`() {
        assertEquals(
            KeyboardVisibility.SHOWN,
            parseKeyboardVisibility("mInputShown=true\n"),
        )
    }

    @Test
    fun `parses an explicitly hidden keyboard`() {
        assertEquals(
            KeyboardVisibility.HIDDEN,
            parseKeyboardVisibility("mInputShown=false\n"),
        )
    }

    @Test
    fun `reports an unknown keyboard state when the dump field is absent`() {
        assertEquals(
            KeyboardVisibility.UNKNOWN,
            parseKeyboardVisibility("InputMethodService state without the legacy field\n"),
        )
    }
}
