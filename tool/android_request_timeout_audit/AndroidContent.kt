package android.content

import android.os.IBinder
import java.io.File

open class Context {
    open val applicationContext: Context get() = this
    open val filesDir: File get() = error("Host filesDir not configured")
    open val cacheDir: File get() = filesDir
    open val codeCacheDir: File get() = filesDir
    open val externalCacheDir: File? get() = null
    open val applicationInfo = HostApplicationInfo()
    open fun getExternalFilesDir(@Suppress("UNUSED_PARAMETER") kind: String?): File? = null
    open fun bindService(intent: Intent, connection: ServiceConnection, flags: Int): Boolean = error("Host binding not configured")
    open fun unbindService(connection: ServiceConnection) {}
    open fun getSystemService(name: String): Any = error("Host service not configured")
    companion object {
        const val BIND_AUTO_CREATE = 1
        const val ACTIVITY_SERVICE = "activity"
    }
}

class HostApplicationInfo { val sourceDir = "."; val nativeLibraryDir = "." }
class Intent(@Suppress("UNUSED_PARAMETER") context: Context, val service: Class<*>)
class ComponentName
interface ServiceConnection {
    fun onServiceConnected(name: ComponentName, binder: IBinder)
    fun onServiceDisconnected(name: ComponentName)
    fun onBindingDied(name: ComponentName)
    fun onNullBinding(name: ComponentName)
}
