package me.zqydev.gamebox

internal enum class KeyboardVisibility {
    SHOWN,
    HIDDEN,
    UNKNOWN,
}

private val keyboardVisibilityPattern = Regex("mInputShown=(true|false)\\b")

internal fun parseKeyboardVisibility(dump: String): KeyboardVisibility {
    return when (keyboardVisibilityPattern.find(dump)?.groupValues?.get(1)) {
        "true" -> KeyboardVisibility.SHOWN
        "false" -> KeyboardVisibility.HIDDEN
        else -> KeyboardVisibility.UNKNOWN
    }
}
