package com.example.video_player_app

import org.junit.Assert.*
import org.junit.Test

class QwenWorkerWatchdogTest {
    @Test fun gpuAudioHasABoundedDeadlineWithoutShorteningCpuOrLoad() {
        assertEquals(120_000L, qwenRequestTimeoutMillis("align", true))
        assertEquals(120_000L, qwenRequestTimeoutMillis("decode", true))
        assertEquals(720_000L, qwenRequestTimeoutMillis("align", false))
        assertEquals(300_000L, qwenRequestTimeoutMillis("load", false))
    }
    @Test fun completedCloseCannotKillTheFollowingPipelineBatch() {
        val guard = QwenWorkerWatchdog()
        guard.renew()
        val old = guard.generation
        assertFalse(guard.shouldStop(old, idle = true, drained = true))
        guard.renew() // A new Service in the same still-cached process.
        assertFalse(guard.shouldStop(old, idle = true, drained = false))
    }

    @Test fun stuckLastOwnerStillStopsAfterCancellation() {
        val guard = QwenWorkerWatchdog()
        guard.renew()
        assertTrue(guard.shouldStop(guard.generation, idle = true, drained = false))
        assertFalse(guard.shouldStop(guard.generation, idle = false, drained = false))
    }

    @Test fun staleOwnerTimeoutCannotKillAnotherOwnersNativeContext() {
        val guard = QwenWorkerWatchdog()
        guard.renew()
        val closing = guard.generation
        guard.renew() // Another ASR / alignment owner.
        assertFalse(guard.shouldStop(closing, idle = false, drained = false))
        assertFalse(guard.shouldStop(closing, idle = true, drained = false))
    }
}
