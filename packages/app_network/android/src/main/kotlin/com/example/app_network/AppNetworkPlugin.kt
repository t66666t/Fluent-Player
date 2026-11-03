package com.example.app_network

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.net.Proxy as AndroidProxy
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.URI
import java.util.concurrent.Executors

class AppNetworkPlugin : FlutterPlugin, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var context: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var listening = false
    private val connectivity by lazy { context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager }
    private val routeChanges = NetworkRouteChangeTracker()
    private fun routeSnapshot(): NetworkRouteSnapshot {
        val network = connectivity.activeNetwork
        val properties = network?.let(connectivity::getLinkProperties)
        return NetworkRouteSnapshot(
            networkHandle = network?.networkHandle,
            interfaceName = properties?.interfaceName,
            addresses = properties?.linkAddresses?.map { it.toString() }?.sorted().orEmpty(),
            dnsServers = properties?.dnsServers?.mapNotNull { it.hostAddress }?.sorted().orEmpty(),
            routes = properties?.routes?.map { it.toString() }?.sorted().orEmpty(),
            proxy = connectivity.defaultProxy?.toString(),
            privateDnsServer = if (Build.VERSION.SDK_INT >= 28) properties?.privateDnsServerName else null,
        )
    }
    private fun changed() {
        main.post {
            if (listening && routeChanges.changed(routeSnapshot())) sink?.success(true)
        }
    }
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = changed()
        override fun onLost(network: Network) = changed()
        // Signal strength, Wi-Fi link speed, bandwidth estimates and validation
        // probes change during healthy transfers. They must not restart them.
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = changed()
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = changed()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "com.example.video_player_app/network")
        events = EventChannel(binding.binaryMessenger, "com.example.video_player_app/network_events")
        events.setStreamHandler(this)
        methods.setMethodCallHandler { call, result ->
            if (call.method != "resolveProxy") { result.notImplemented(); return@setMethodCallHandler }
            val url = call.argument<String>("url")
            if (url == null) { result.error("INVALID_URL", "缺少网址", null); return@setMethodCallHandler }
            worker.execute {
                try {
                    val proxies = ProxySelector.getDefault()?.select(URI(url))
                        ?: listOf(Proxy.NO_PROXY)
                    val values = proxies.map { proxy ->
                        if (proxy.type() == Proxy.Type.DIRECT) "DIRECT" else {
                            val address = proxy.address() as? InetSocketAddress
                                ?: error("Unsupported system proxy")
                            URI(if (proxy.type() == Proxy.Type.SOCKS) "socks5" else "http",
                                null, address.hostString, address.port, null, null, null).toASCIIString()
                        }
                    }
                    main.post { result.success(values) }
                } catch (_: Exception) {
                    main.post { result.error("PROXY_RESOLUTION_FAILED", "无法读取系统代理", null) }
                }
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        if (listening) return
        routeChanges.reset(routeSnapshot())
        connectivity.registerDefaultNetworkCallback(callback)
        val filter = IntentFilter(AndroidProxy.PROXY_CHANGE_ACTION)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") context.registerReceiver(receiver, filter)
        listening = true
    }
    override fun onCancel(arguments: Any?) {
        sink = null
        if (!listening) return
        connectivity.unregisterNetworkCallback(callback)
        context.unregisterReceiver(receiver)
        listening = false
        routeChanges.reset()
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onCancel(null)
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        worker.shutdown()
    }
}
