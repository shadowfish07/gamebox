package me.zqydev.gamebox

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.PersistableBundle
import android.util.Base64
import android.view.KeyEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class E2eSetTextTest {
    @Test
    fun setApprovedFieldFromBase64WithoutEchoingValue() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val target = arguments.getString(ARG_TARGET)
            ?: throw IllegalArgumentException("Missing E2E text target")
        require(target in APPROVED_TARGETS) { "Unsupported E2E text target" }

        val encoded = arguments.getString(ARG_VALUE_BASE64)
            ?: throw IllegalArgumentException("Missing E2E text payload")
        require(encoded.isNotEmpty() && encoded.length <= MAX_ENCODED_LENGTH) {
            "Invalid E2E text payload"
        }
        val decoded = try {
            Base64.decode(encoded, Base64.NO_WRAP).toString(Charsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            throw IllegalArgumentException("Invalid E2E text payload")
        }
        require(decoded.length in 1..MAX_DECODED_LENGTH && decoded.all(::isApprovedCharacter)) {
            "Invalid E2E text value"
        }

        val device = UiDevice.getInstance(instrumentation)
        val field = device.wait(
            // Flutter exposes Semantics.identifier as the exact raw Android
            // resource-id, not an aapt resource owned by an Android package.
            Until.findObject(By.res(target)),
            SELECTOR_TIMEOUT_MS,
        ) ?: throw AssertionError("Approved E2E text field was not found")
        val editable = field.children.singleOrNull()
            ?.takeIf { child -> child.className == EDIT_TEXT_CLASS }
            ?: throw AssertionError("Approved E2E text field structure was invalid")
        val clipboard = instrumentation.context.getSystemService(ClipboardManager::class.java)
        val clip = ClipData.newPlainText("", decoded).also { sensitiveClip ->
            sensitiveClip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        try {
            clipboard.setPrimaryClip(clip)
            editable.click()
            device.waitForIdle()
            device.pressKeyCode(KeyEvent.KEYCODE_A, KeyEvent.META_CTRL_ON)
            device.pressKeyCode(KeyEvent.KEYCODE_V, KeyEvent.META_CTRL_ON)
            device.waitForIdle()
        } finally {
            clipboard.clearPrimaryClip()
        }
        val refreshed = device.findObject(By.res(target))
        val refreshedEditable = refreshed?.children?.singleOrNull()
            ?.takeIf { child -> child.className == EDIT_TEXT_CLASS }
        if (refreshedEditable?.text != decoded) {
            throw AssertionError("E2E text field did not round-trip")
        }
    }

    private fun isApprovedCharacter(character: Char): Boolean =
        character in 'A'..'Z' || character in 'a'..'z' || character in '0'..'9' ||
            character == '-' || character == '_'

    private companion object {
        const val ARG_TARGET = "gameboxTextTarget"
        const val ARG_VALUE_BASE64 = "gameboxTextValueBase64"
        const val MAX_ENCODED_LENGTH = 192
        const val MAX_DECODED_LENGTH = 96
        const val SELECTOR_TIMEOUT_MS = 10_000L
        const val EDIT_TEXT_CLASS = "android.widget.EditText"
        val APPROVED_TARGETS = setOf("invite-code", "nickname")
    }
}
