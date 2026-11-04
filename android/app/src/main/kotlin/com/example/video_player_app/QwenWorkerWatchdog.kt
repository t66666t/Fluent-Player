package com.example.video_player_app

internal fun qwenRequestTimeoutMillis(operation: String?, gpuAudio: Boolean): Long =
    when {
        operation == "load" -> 300_000L
        gpuAudio -> 120_000L
        else -> 720_000L
    }

/** Process-wide identity for delayed cancellation of a private Qwen owner. */
internal class QwenWorkerWatchdog {
    var generation = 0L
        private set

    fun renew() { generation++ }

    fun shouldStop(token: Long, idle: Boolean, drained: Boolean): Boolean =
        token == generation && idle && !drained
}
