package com.example.video_player_app

import android.os.Handler

/** Snapshot-only observer. Deadlines and original callback bodies are unchanged. */
object ResourceAuditCounters {
    private data class Entry(val handler: Handler, val wrapped: Runnable, val label: String)
    private val pending = java.util.IdentityHashMap<Runnable, Entry>()
    @Synchronized fun postDelayed(handler: Handler, label: String, action: Runnable, delay: Long): Boolean {
        val wrapped = Runnable { synchronized(this) { pending.remove(action) }; action.run() }
        pending[action] = Entry(handler, wrapped, label)
        return handler.postDelayed(wrapped, delay)
    }
    @Synchronized fun removeCallbacks(handler: Handler, action: Runnable) {
        val entry = pending.remove(action)
        handler.removeCallbacks(entry?.wrapped ?: action)
    }
    @Synchronized fun stats(): Map<String, Int> = pending.values.groupingBy { it.label }.eachCount()
    fun fireOne(label: String): Boolean {
        val entry = synchronized(this) { pending.entries.firstOrNull { it.value.label == label }?.let {
            val selected = it.key to it.value
            pending.remove(selected.first)
            selected
        } } ?: return false
        entry.second.handler.removeCallbacks(entry.second.wrapped)
        entry.first.run()
        return true
    }
}
