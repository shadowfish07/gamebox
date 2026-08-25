package me.zqydev.gamebox

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class E2eKeyboardVisibilityTest {
    @Test
    fun parsesAnExplicitlyShownKeyboard() {
        assertEquals(
            E2eKeyboardVisibility.SHOWN,
            parseE2eKeyboardVisibility("mInputShown=true\n"),
        )
    }

    @Test
    fun parsesAnExplicitlyHiddenKeyboard() {
        assertEquals(
            E2eKeyboardVisibility.HIDDEN,
            parseE2eKeyboardVisibility("mInputShown=false\n"),
        )
    }

    @Test
    fun reportsUnknownWhenTheDumpFieldIsAbsent() {
        assertEquals(
            E2eKeyboardVisibility.UNKNOWN,
            parseE2eKeyboardVisibility("InputMethodService state without the legacy field\n"),
        )
    }
}
