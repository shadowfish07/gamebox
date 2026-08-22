package me.zqydev.gamebox

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LanLocalNetworkPermissionPolicyTest {
    @Test
    fun `runtime permission is absent through target 36 and required from 37`() {
        assertNull(LanLocalNetworkPermissionPolicy.permissionToRequest(36, granted = false))
        assertEquals(
            "android.permission.ACCESS_LOCAL_NETWORK",
            LanLocalNetworkPermissionPolicy.permissionToRequest(37, granted = false),
        )
        assertEquals(
            "android.permission.ACCESS_LOCAL_NETWORK",
            LanLocalNetworkPermissionPolicy.permissionToRequest(99, granted = false),
        )
        assertNull(LanLocalNetworkPermissionPolicy.permissionToRequest(37, granted = true))
    }
}
