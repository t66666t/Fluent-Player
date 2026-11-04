package com.example.video_player_app

/** Main-thread callbacks owned by live Binder requests, never completed work. */
internal class RequestTimeouts(
    private val postDelayed: (Runnable, Long) -> Unit,
    private val removeCallbacks: (Runnable) -> Unit,
) {
    private val callbacks = mutableMapOf<Int, Runnable>()

    fun schedule(id: Int, delayMillis: Long, action: () -> Unit) {
        cancel(id)
        lateinit var callback: Runnable
        callback = Runnable {
            // removeCallbacks cannot revoke a callback already dequeued by a
            // scheduler. It must not act on a cancelled/replaced request ID.
            if (callbacks[id] !== callback) return@Runnable
            callbacks.remove(id)
            action()
        }
        callbacks[id] = callback
        postDelayed(callback, delayMillis)
    }

    fun cancel(id: Int) {
        callbacks.remove(id)?.let(removeCallbacks)
    }

    fun clear() {
        val retired = callbacks.values.toList()
        callbacks.clear()
        retired.forEach(removeCallbacks)
    }
}
