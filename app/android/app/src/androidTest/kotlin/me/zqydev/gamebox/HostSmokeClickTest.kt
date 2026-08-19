package me.zqydev.gamebox

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HostSmokeClickTest {
    @Test
    fun clickHostSmokeLaunchByAccessibilityDescription() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val button = device.wait(
            Until.findObject(By.desc(HOST_SMOKE_DESCRIPTION)),
            SELECTOR_TIMEOUT_MS,
        )

        assertNotNull("Missing accessibility selector: $HOST_SMOKE_DESCRIPTION", button)
        button.click()
        device.waitForIdle()
    }

    private companion object {
        const val HOST_SMOKE_DESCRIPTION = "host-smoke.launch"
        const val SELECTOR_TIMEOUT_MS = 20_000L
    }
}
