package com.example.app_network

/** Stable routing facts only: Wi-Fi signal and estimated bandwidth are not routes. */
internal data class NetworkRouteSnapshot(
    val networkHandle: Long?,
    val interfaceName: String? = null,
    val addresses: List<String> = emptyList(),
    val dnsServers: List<String> = emptyList(),
    val routes: List<String> = emptyList(),
    val proxy: String? = null,
    val privateDnsServer: String? = null,
)

internal class NetworkRouteChangeTracker {
    private var previous: NetworkRouteSnapshot? = null

    fun reset(snapshot: NetworkRouteSnapshot? = null) {
        previous = snapshot
    }

    fun changed(snapshot: NetworkRouteSnapshot): Boolean {
        val last = previous
        previous = snapshot
        return last != null && last != snapshot
    }
}
