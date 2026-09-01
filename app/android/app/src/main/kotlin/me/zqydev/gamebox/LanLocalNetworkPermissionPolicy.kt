package me.zqydev.gamebox

internal object LanLocalNetworkPermissionPolicy {
    internal const val ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
    internal const val MIN_TARGET_SDK = 37

    fun permissionToRequest(targetSdk: Int, granted: Boolean): String? {
        require(targetSdk > 0)
        return ACCESS_LOCAL_NETWORK.takeIf { targetSdk >= MIN_TARGET_SDK && !granted }
    }
}
