package me.zqydev.gamebox

import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface

internal data class LanAddressCandidate(
    val interfaceName: String,
    val address: InetAddress,
    val isUp: Boolean,
    val isLoopbackInterface: Boolean,
    val isPointToPoint: Boolean,
)

internal object LanNetworkAddress {
    fun current(): String? = select(enumerate())

    internal fun select(candidates: List<LanAddressCandidate>): String? = candidates
        .asSequence()
        .filter { it.isUp && !it.isLoopbackInterface && !it.isPointToPoint }
        .filterNot { isCellularInterface(it.interfaceName) }
        .filter { it.address is Inet4Address }
        .filterNot {
            it.address.isAnyLocalAddress ||
                it.address.isLoopbackAddress ||
                it.address.isLinkLocalAddress ||
                it.address.isMulticastAddress
        }
        .filter { isPrivateIPv4(it.address.address) }
        .sortedWith(compareBy<LanAddressCandidate>({ it.interfaceName }, { it.address.hostAddress }))
        .mapNotNull { it.address.hostAddress }
        .firstOrNull()

    private fun enumerate(): List<LanAddressCandidate> {
        val result = mutableListOf<LanAddressCandidate>()
        val interfaces = runCatching { NetworkInterface.getNetworkInterfaces() }.getOrNull() ?: return result
        while (interfaces.hasMoreElements()) {
            val networkInterface = interfaces.nextElement()
            val properties = runCatching {
                Triple(networkInterface.isUp, networkInterface.isLoopback, networkInterface.isPointToPoint)
            }.getOrNull() ?: continue
            val addresses = networkInterface.inetAddresses
            while (addresses.hasMoreElements()) {
                result += LanAddressCandidate(
                    interfaceName = networkInterface.name.orEmpty(),
                    address = addresses.nextElement(),
                    isUp = properties.first,
                    isLoopbackInterface = properties.second,
                    isPointToPoint = properties.third,
                )
            }
        }
        return result
    }

    private fun isCellularInterface(name: String): Boolean {
        val normalized = name.lowercase()
        return CELLULAR_PREFIXES.any(normalized::startsWith)
    }

    private fun isPrivateIPv4(bytes: ByteArray): Boolean {
        if (bytes.size != 4) return false
        val first = bytes[0].toInt() and 0xff
        val second = bytes[1].toInt() and 0xff
        return first == 10 ||
            (first == 172 && second in 16..31) ||
            (first == 192 && second == 168)
    }

    private val CELLULAR_PREFIXES = listOf(
        "rmnet",
        "ccmni",
        "pdp_ip",
        "wwan",
        "cellular",
    )
}
