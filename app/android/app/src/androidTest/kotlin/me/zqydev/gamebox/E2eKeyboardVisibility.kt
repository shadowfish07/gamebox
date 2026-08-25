package me.zqydev.gamebox

internal enum class E2eKeyboardVisibility {
    SHOWN,
    HIDDEN,
    UNKNOWN,
}

private val e2eKeyboardVisibilityPattern = Regex("mInputShown=(true|false)\\b")

internal fun parseE2eKeyboardVisibility(dump: String): E2eKeyboardVisibility {
    return when (e2eKeyboardVisibilityPattern.find(dump)?.groupValues?.get(1)) {
        "true" -> E2eKeyboardVisibility.SHOWN
        "false" -> E2eKeyboardVisibility.HIDDEN
        else -> E2eKeyboardVisibility.UNKNOWN
    }
}
