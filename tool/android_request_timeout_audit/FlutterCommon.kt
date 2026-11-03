package io.flutter.plugin.common

interface BinaryMessenger
class MethodCall(val method: String, val arguments: Any?)
class MethodChannel(@Suppress("UNUSED_PARAMETER") messenger: BinaryMessenger, val name: String) {
    interface Result {
        fun success(result: Any?)
        fun error(code: String, message: String?, details: Any?)
        fun notImplemented()
    }
    private var handler: ((MethodCall, Result) -> Unit)? = null
    init { channels[name] = this }
    fun setMethodCallHandler(value: ((MethodCall, Result) -> Unit)?) { handler = value }
    fun call(method: String, arguments: Any?, result: Result) = handler!!(MethodCall(method, arguments), result)
    companion object { val channels = mutableMapOf<String, MethodChannel>() }
}
