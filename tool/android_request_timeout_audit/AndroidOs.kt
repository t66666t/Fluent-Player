package android.os

import java.io.File
import java.io.FileNotFoundException

/** Host-only deterministic main Looper. Never included in Android sources. */
class Looper private constructor() {
    companion object {
        private val main = Looper()
        fun getMainLooper() = main
    }
}

object HostMainLoop {
    data class Scheduled(val runnable: Runnable, val due: Long, val order: Long)
    private val queue = mutableListOf<Scheduled>()
    var now = 0L
        private set
    var dispatched = 0
        private set
    private var order = 0L
    val scheduled: List<Scheduled> get() = queue.toList()
    fun reset() { queue.clear(); now = 0; dispatched = 0; order = 0 }
    fun post(task: Runnable, delay: Long) { queue.add(Scheduled(task, now + delay, order++)) }
    fun remove(task: Runnable) { queue.removeAll { it.runnable === task } }
    fun elapseWithoutDispatch(milliseconds: Long) { now += milliseconds }
    fun current() = advance(0)
    fun advance(milliseconds: Long) {
        val target = now + milliseconds
        var count = 0
        while (true) {
            val next = queue.filter { it.due <= target }.minWithOrNull(compareBy({ it.due }, { it.order })) ?: break
            queue.remove(next)
            now = maxOf(now, next.due)
            dispatched++
            check(++count < 100_000) { "Host loop did not settle" }
            next.runnable.run()
        }
        now = maxOf(now, target)
    }
}

class Handler(@Suppress("UNUSED_PARAMETER") looper: Looper,
              private val callback: ((Message) -> Boolean)? = null) {
    fun postDelayed(task: Runnable, delay: Long): Boolean { HostMainLoop.post(task, delay); return true }
    fun post(task: Runnable): Boolean = postDelayed(task, 0)
    fun removeCallbacks(task: Runnable) = HostMainLoop.remove(task)
    fun dispatch(message: Message) { callback?.invoke(message) }
}

interface IBinder {
    val isBinderAlive: Boolean
    fun send(message: Message)
}

class Messenger(val binder: IBinder) {
    constructor(handler: Handler) : this(object : IBinder {
        override val isBinderAlive = true
        override fun send(message: Message) { handler.post { handler.dispatch(message) } }
    })
    fun send(message: Message) = binder.send(message)
}

class Message(var what: Int) {
    var arg1 = 0
    var replyTo: Messenger? = null
    var data = Bundle()
    companion object {
        fun obtain(@Suppress("UNUSED_PARAMETER") unused: Any?, what: Int) = Message(what)
    }
}

class Bundle {
    private val values = mutableMapOf<String, Any?>()
    fun putString(key: String, value: String?) { values[key] = value }
    fun getString(key: String): String? = values[key] as? String
    fun putParcelable(key: String, value: Any) { values[key] = value }
}

open class RemoteException(message: String = "host remote failure") : Exception(message)
class DeadObjectException : RemoteException()

class ParcelFileDescriptor private constructor() {
    fun close() {}
    companion object {
        const val MODE_READ_ONLY = 0
        fun open(file: File, @Suppress("UNUSED_PARAMETER") mode: Int): ParcelFileDescriptor {
            if (!file.isFile) throw FileNotFoundException()
            return ParcelFileDescriptor()
        }
    }
}

object Build {
    const val FINGERPRINT = "host-main-loop-test"
    val SUPPORTED_ABIS = arrayOf("arm64-v8a")
    object VERSION { var SDK_INT = 35 }
}

object Process {
    val killed = mutableListOf<Int>()
    fun killProcess(pid: Int) { killed.add(pid) }
}
