package me.zqydev.gamebox

import android.system.Os
import android.content.pm.ApplicationInfo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LanE2eHostExportTest {
    @Test
    fun exportExistingRoomThroughPrivateOneShotFile() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        check(instrumentation.context.packageName == "${instrumentation.targetContext.packageName}.test")
        val context = instrumentation.targetContext
        check(context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            "LAN E2E export is debug-only"
        }
        val commands = LanHostService.serviceReady.current()
            ?: LanHostService.serviceReady.await(10_000)
            ?: error("LAN host service is unavailable")
        val status = commands.getStatus()
        check(status["state"] == "waiting")
        val secrets = requireNotNull(LanSecretStore(context).load())
        val handoff = File(context.filesDir, "lan-e2e-handoff.json")
        handoff.writeText(
            JSONObject()
                .put("roomId", status["roomId"])
                .put("port", status["port"])
                .put("roomKey", secrets.roomKey)
                .put("joinExpiresAt", System.currentTimeMillis() + 5 * 60 * 1000)
                .toString(),
        )
        Os.chmod(handoff.path, 0x180)
        android.util.Log.i("LanE2eHostExport", "LAN_HOST_EXPORT_READY roomId=${status["roomId"]}")
    }
}
