package android.app

open class Service
class ApplicationExitInfo(val pid: Int, val reason: Int) {
    companion object { const val REASON_CRASH_NATIVE = 5 }
}
class ActivityManager {
    fun getHistoricalProcessExitReasons(
        @Suppress("UNUSED_PARAMETER") packageName: String?,
        @Suppress("UNUSED_PARAMETER") pid: Int,
        @Suppress("UNUSED_PARAMETER") count: Int,
    ): List<ApplicationExitInfo> = emptyList()
}
