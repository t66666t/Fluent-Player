package com.example.video_player_app

/** A service slot stays occupied until Binder reports that its old process died. */
internal class BackgroundWorkerLifecycle(
    private val stop: () -> Unit,
    private val unbind: () -> Unit,
    private val failPending: () -> Unit,
) {
    var binding = false
        private set
    var closed = false
        private set
    var terminated = false
        private set
    private var connected = false
    private var stopping = false
    private val waiters = mutableListOf<(Boolean) -> Unit>()

    fun bindingStarted() {
        check(!closed)
        binding = true
    }

    fun connected() {
        if (terminated) return
        connected = true
        if (closed) stopConnected()
    }

    fun close(done: ((Boolean) -> Unit)? = null) {
        if (terminated) {
            done?.invoke(true)
            return
        }
        done?.let { waiters.add(it) }
        if (!closed) {
            closed = true
            failPending()
        }
        if (!binding && !connected) disconnected()
        else if (connected) stopConnected()
    }

    // A timeout is a failed close, never permission to bind a replacement to
    // the same still-dying service. Keep listening for its eventual death.
    fun closeTimedOut() = notifyWaiters(false)

    fun disconnected() {
        if (terminated) return
        terminated = true
        connected = false
        val wasClosed = closed
        closed = true
        releaseBinding()
        if (!wasClosed) failPending()
        notifyWaiters(true)
    }

    private fun stopConnected() {
        if (stopping) return
        stopping = true
        stop()
        releaseBinding()
        // unbindService does not report process termination. A death recipient
        // remains installed even after this binding has been released.
    }

    private fun releaseBinding() {
        if (!binding) return
        binding = false
        unbind()
    }

    private fun notifyWaiters(terminated: Boolean) {
        val callbacks = waiters.toList()
        waiters.clear()
        callbacks.forEach { it(terminated) }
    }
}
