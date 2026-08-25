package me.zqydev.gamebox

import android.os.Process
import android.content.pm.ApplicationInfo
import android.system.Os
import android.system.OsConstants
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanE2eInputTest {
    @Test
    fun consumePrivateLanPayloadIntoManualField() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(instrumentation.targetContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            "LAN E2E injection is debug-only"
        }
        assertEquals("${instrumentation.targetContext.packageName}.test", instrumentation.context.packageName)
        val inputName = InstrumentationRegistry.getArguments().getString(ARG_INPUT)
            ?: error("Missing private LAN input")
        require(INPUT_NAME.matches(inputName))
        val payload = consume(File(instrumentation.context.dataDir, inputName))
        require(payload.startsWith("gamebox-lan://join?") || payload.startsWith("gamebox-lan://resume?"))
        require(payload.length <= 2048 && payload.all { it.code in 0x21..0x7e })

        val device = UiDevice.getInstance(instrumentation)
        val field = device.wait(Until.findObject(By.res("lan-manual-input")), 10_000)
            ?: error("LAN manual input was not found")
        val editable = field.findObject(By.clazz("android.widget.EditText"))
            ?: error("LAN manual input was not editable")
        editable.click()
        editable.text = payload
        device.waitForIdle()
        check(editable.text == payload) { "LAN payload did not round-trip" }
        val hash = MessageDigest.getInstance("SHA-256").digest(payload.toByteArray())
            .joinToString("") { "%02x".format(it) }
        android.util.Log.i("LanE2eInput", "LAN_INPUT_READY sha256=$hash")
    }

    private fun consume(input: File): String {
        var unlinked = false
        try {
            val stat = Os.lstat(input.path)
            require(OsConstants.S_ISREG(stat.st_mode) && stat.st_uid == Process.myUid())
            require(stat.st_mode and 0x1ff == 0x180)
            FileInputStream(input).use { stream ->
                val descriptor = Os.fstat(stream.fd)
                require(OsConstants.S_ISREG(descriptor.st_mode) && descriptor.st_uid == Process.myUid())
                Os.remove(input.path)
                unlinked = true
                val bytes = ByteArray(2049)
                var size = 0
                while (size < bytes.size) {
                    val read = stream.read(bytes, size, bytes.size - size)
                    if (read < 0) break
                    size += read
                }
                require(size in 1..2048)
                return String(bytes, 0, size, Charsets.US_ASCII)
            }
        } finally {
            if (!unlinked) runCatching { Os.remove(input.path) }
        }
    }

    private companion object {
        const val ARG_INPUT = "gameboxLanInputName"
        val INPUT_NAME = Regex("gamebox-lan-e2e-[A-Za-z0-9_.-]{8,96}")
    }
}
