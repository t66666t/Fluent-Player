package com.example.app_network

/** Host-only regression checks; no Android device or network requests. */
fun main() {
    val wifi = NetworkRouteSnapshot(
        networkHandle = 100,
        interfaceName = "wlan0",
        addresses = listOf("192.0.2.10/24"),
        dnsServers = listOf("192.0.2.1"),
        routes = listOf("0.0.0.0/0 via 192.0.2.1 wlan0"),
    )
    val tracker = NetworkRouteChangeTracker()
    check(!tracker.changed(wifi)) { "Initial observer attachment must not interrupt existing work" }
    repeat(100) {
        check(!tracker.changed(wifi.copy())) { "Repeated properties must not look like a route switch" }
    }
    for (next in listOf(
        wifi.copy(networkHandle = 101),
        wifi.copy(addresses = listOf("192.0.2.11/24")),
        wifi.copy(dnsServers = listOf("198.51.100.1")),
        wifi.copy(routes = listOf("0.0.0.0/0 via 192.0.2.2 wlan0")),
        wifi.copy(proxy = "http://127.0.0.1:7890"),
        wifi.copy(privateDnsServer = "dns.example.invalid"),
        NetworkRouteSnapshot(networkHandle = null),
    )) {
        tracker.reset(wifi)
        check(tracker.changed(next)) { "Actual routing edits must still be reported" }
        check(!tracker.changed(next)) { "Duplicate callbacks must be suppressed" }
    }
    tracker.reset(wifi)
    val mobile = wifi.copy(networkHandle = 102, interfaceName = "rmnet0")
    check(tracker.changed(mobile))
    // A delayed callback for the old Wi-Fi network re-reads the current route.
    check(!tracker.changed(mobile))
    tracker.reset()
    check(!tracker.changed(mobile)) { "Re-attaching starts with a new baseline" }
    println("PASS: initial attach, 100 repeated notifications, route/proxy/DNS edits, disconnect and re-attach")
}
