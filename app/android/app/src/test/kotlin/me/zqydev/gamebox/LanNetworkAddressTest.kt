package me.zqydev.gamebox

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LanNetworkAddressTest {
    @Test
    fun `selects only site-local IPv4 from active WiFi or hotspot`() {
        val candidates = listOf(
            candidate("wlan0", "fe80::1"),
            candidate("lo", "127.0.0.1", loopback = true),
            candidate("wlan0", "169.254.2.3"),
            candidate("wlan0", "8.8.8.8"),
            candidate("wlan0", "192.168.43.12"),
        )

        assertEquals("192.168.43.12", LanNetworkAddress.select(candidates))
    }

    @Test
    fun `accepts each RFC1918 range boundary`() {
        listOf("10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254", "192.168.0.1").forEach { address ->
            assertEquals(address, LanNetworkAddress.select(listOf(candidate("wlan0", address))))
        }
    }

    @Test
    fun `rejects inactive loopback point-to-point cellular public and IPv6 addresses`() {
        val rejected = listOf(
            candidate("wlan0", "192.168.1.4", up = false),
            candidate("wlan0", "192.168.1.4", loopback = true),
            candidate("pdp_ip0", "10.1.2.3", pointToPoint = true),
            candidate("rmnet_data0", "10.1.2.3"),
            candidate("wlan0", "172.15.255.255"),
            candidate("wlan0", "172.32.0.1"),
            candidate("wlan0", "100.64.0.1"),
            candidate("wlan0", "::1"),
        )

        rejected.forEach { candidate ->
            assertNull(candidate.toString(), LanNetworkAddress.select(listOf(candidate)))
        }
        assertNull(LanNetworkAddress.select(emptyList()))
    }

    private fun candidate(
        name: String,
        address: String,
        up: Boolean = true,
        loopback: Boolean = false,
        pointToPoint: Boolean = false,
    ) = LanAddressCandidate(
        interfaceName = name,
        address = InetAddress.getByName(address),
        isUp = up,
        isLoopbackInterface = loopback,
        isPointToPoint = pointToPoint,
    )
}
