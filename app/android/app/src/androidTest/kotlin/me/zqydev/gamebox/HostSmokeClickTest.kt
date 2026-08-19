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
        val button = findLaunchButton(device)

        assertNotNull("Missing accessibility selector: $HOST_SMOKE_DESCRIPTION", button)
        button.click()
    }

    @Test
    fun clickNormalLaunchCanaryByAccessibilityDescription() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val button = device.wait(
            Until.findObject(By.pkg(APP_PACKAGE).desc(NORMAL_CANARY_DESCRIPTION)),
            SELECTOR_TIMEOUT_MS,
        )

        assertNotNull("Missing accessibility selector: $NORMAL_CANARY_DESCRIPTION", button)
        button.click()
    }

    @Test
    fun clickCollisionLaunchCanaryByAccessibilityDescription() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val button = device.wait(
            Until.findObject(By.pkg(APP_PACKAGE).desc(COLLISION_CANARY_DESCRIPTION)),
            SELECTOR_TIMEOUT_MS,
        )

        assertNotNull("Missing accessibility selector: $COLLISION_CANARY_DESCRIPTION", button)
        button.click()
    }

    @Test
    fun clickHostSmokeAndExpectActiveLaunchRejection() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val button = findLaunchButton(device)

        assertNotNull("Missing accessibility selector: $HOST_SMOKE_DESCRIPTION", button)
        button.click()
        val error = device.wait(
            Until.findObject(By.pkg(APP_PACKAGE).desc(HOST_SMOKE_ERROR_DESCRIPTION)),
            SELECTOR_TIMEOUT_MS,
        )
        assertNotNull("Missing deterministic active-launch rejection", error)
    }

    @Test
    fun pressBackToActiveGame() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

        device.pressBack()
        device.waitForIdle()
    }

    private fun findLaunchButton(device: UiDevice) = device.wait(
        Until.findObject(By.pkg(APP_PACKAGE).desc(HOST_SMOKE_DESCRIPTION)),
        SELECTOR_TIMEOUT_MS,
    )

    private companion object {
        const val APP_PACKAGE = "me.zqydev.gamebox"
        const val HOST_SMOKE_DESCRIPTION = "host-smoke.launch"
        const val NORMAL_CANARY_DESCRIPTION = "host-smoke.normal-canary"
        const val COLLISION_CANARY_DESCRIPTION = "host-smoke.collision-canary"
        const val HOST_SMOKE_ERROR_DESCRIPTION = "host-smoke.error"
        const val SELECTOR_TIMEOUT_MS = 20_000L
    }
}
