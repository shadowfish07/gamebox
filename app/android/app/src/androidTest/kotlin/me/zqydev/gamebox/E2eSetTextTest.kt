package me.zqydev.gamebox

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Process
import android.os.PersistableBundle
import android.system.Os
import android.system.OsConstants
import android.view.KeyEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileInputStream

@RunWith(AndroidJUnit4::class)
class E2eSetTextTest {
    @Test
    fun setApprovedFieldFromPrivateInputWithoutEchoingValue() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val arguments = InstrumentationRegistry.getArguments()
        val target = arguments.getString(ARG_TARGET)
            ?: throw IllegalArgumentException("Missing E2E text target")
        require(target in APPROVED_TARGETS) { "Unsupported E2E text target" }

        val inputName = arguments.getString(ARG_INPUT_NAME)
            ?: throw IllegalArgumentException("Missing E2E private input")
        val decoded = consumePrivateInput(instrumentation.context.dataDir, inputName)
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
        // On short screens the open keyboard can push the just-filled field
        // below the visible viewport (the submit footer stays pinned), hiding
        // it from the accessibility tree and breaking the round-trip re-find.
        // Dismiss the keyboard first so the field returns to view.
        val keyboardShown = device.executeShellCommand("dumpsys input_method")
            .lineSequence()
            .any { it.contains("mInputShown=true") }
        if (keyboardShown) {
            device.pressBack()
            device.waitForIdle()
        }
        val refreshed = device.wait(
            Until.findObject(By.res(target)),
            SELECTOR_TIMEOUT_MS,
        )
        val refreshedEditable = refreshed?.children?.singleOrNull()
            ?.takeIf { child -> child.className == EDIT_TEXT_CLASS }
        if (refreshedEditable?.text != decoded) {
            throw AssertionError("E2E text field did not round-trip")
        }
    }

    @Test
    fun clearClipboardWithoutReadingIt() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.context.getSystemService(ClipboardManager::class.java).clearPrimaryClip()
    }

    private fun consumePrivateInput(dataDir: File, inputName: String): String {
        require(PRIVATE_INPUT_NAME.matches(inputName)) { "Invalid E2E private input" }
        val input = File(dataDir, inputName)
        var unlinked = false
        try {
            val pathStat = Os.lstat(input.path)
            require(OsConstants.S_ISREG(pathStat.st_mode)) { "Invalid E2E private input" }
            require(pathStat.st_uid == Process.myUid()) { "Invalid E2E private input" }
            require(pathStat.st_mode and FILE_MODE_MASK == PRIVATE_FILE_MODE) {
                "Invalid E2E private input"
            }
            FileInputStream(input).use { stream ->
                val descriptorStat = Os.fstat(stream.fd)
                require(OsConstants.S_ISREG(descriptorStat.st_mode)) { "Invalid E2E private input" }
                require(descriptorStat.st_uid == Process.myUid()) { "Invalid E2E private input" }
                require(descriptorStat.st_mode and FILE_MODE_MASK == PRIVATE_FILE_MODE) {
                    "Invalid E2E private input"
                }
                Os.remove(input.path)
                unlinked = true
                val bytes = ByteArray(MAX_DECODED_LENGTH + 1)
                var size = 0
                while (size < bytes.size) {
                    val read = stream.read(bytes, size, bytes.size - size)
                    if (read < 0) break
                    size += read
                }
                require(size in 1..MAX_DECODED_LENGTH) { "Invalid E2E private input" }
                require(bytes.copyOf(size).all(::isApprovedByte)) { "Invalid E2E private input" }
                return String(bytes, 0, size, Charsets.US_ASCII)
            }
        } finally {
            if (!unlinked) {
                try {
                    Os.remove(input.path)
                } catch (_: Exception) {
                    // The host performs a second exact-path cleanup even if this process is killed.
                }
            }
        }
    }

    private fun isApprovedByte(value: Byte): Boolean = isApprovedCharacter(value.toInt().toChar())

    private fun isApprovedCharacter(character: Char): Boolean =
        character in 'A'..'Z' || character in 'a'..'z' || character in '0'..'9' ||
            character == '-' || character == '_'

    private companion object {
        const val ARG_TARGET = "gameboxTextTarget"
        const val ARG_INPUT_NAME = "gameboxTextInputName"
        const val MAX_DECODED_LENGTH = 96
        const val SELECTOR_TIMEOUT_MS = 10_000L
        const val EDIT_TEXT_CLASS = "android.widget.EditText"
        const val FILE_MODE_MASK = 0x1ff
        const val PRIVATE_FILE_MODE = 0x180
        val PRIVATE_INPUT_NAME = Regex("gamebox-e2e-input-[A-Za-z0-9_.-]{8,96}")
        val APPROVED_TARGETS = setOf("invite-code", "nickname")
    }
}
