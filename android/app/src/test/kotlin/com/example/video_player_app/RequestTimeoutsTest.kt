package com.example.video_player_app

import org.junit.Assert.*
import org.junit.Test

class RequestTimeoutsTest {
    private class Scheduler {
        val queued = linkedMapOf<Runnable, Long>()
        var now = 0L
        val timeouts = RequestTimeouts(
            postDelayed = { task, delay -> queued[task] = now + delay },
            removeCallbacks = { queued.remove(it) },
        )
        fun advance(milliseconds: Long) {
            now += milliseconds
            while (true) {
                val due = queued.entries.firstOrNull { it.value <= now }?.key ?: return
                queued.remove(due)
                due.run()
            }
        }
    }

    @Test fun cancellationRemovesTheQueuedCallbackAndItsCapturedWork() {
        val scheduler = Scheduler()
        var calls = 0
        scheduler.timeouts.schedule(1, 60_000) { calls++ }
        scheduler.timeouts.cancel(1)
        assertTrue(scheduler.queued.isEmpty())
        scheduler.advance(60_000)
        assertEquals(0, calls)
    }

    @Test fun staleDequeuedCallbackCannotReplaceOrCancelAReusedId() {
        val scheduler = Scheduler()
        val events = mutableListOf<String>()
        scheduler.timeouts.schedule(1, 10) { events.add("old") }
        val old = scheduler.queued.keys.single()
        scheduler.timeouts.schedule(1, 20) { events.add("new") }
        old.run()
        assertTrue(events.isEmpty())
        assertEquals(1, scheduler.queued.size)
        scheduler.advance(20)
        assertEquals(listOf("new"), events)
    }

    @Test fun firingRemovesItsRegistrationBeforeReentrantScheduling() {
        val scheduler = Scheduler()
        val events = mutableListOf<String>()
        scheduler.timeouts.schedule(1, 10) {
            events.add("first")
            scheduler.timeouts.schedule(1, 10) { events.add("second") }
        }
        scheduler.advance(10)
        assertEquals(listOf("first"), events)
        assertEquals(1, scheduler.queued.size)
        scheduler.advance(10)
        assertEquals(listOf("first", "second"), events)
        assertTrue(scheduler.queued.isEmpty())
    }

    @Test fun clearOnlyCancelsTheSnapshotAndRepeatedCancellationIsSafe() {
        val tasks = mutableListOf<Runnable>()
        lateinit var timeouts: RequestTimeouts
        var reentered = false
        timeouts = RequestTimeouts(
            postDelayed = { task, _ -> tasks.add(task) },
            removeCallbacks = { task ->
                tasks.remove(task)
                if (!reentered) {
                    reentered = true
                    timeouts.schedule(3, 10) {}
                }
            },
        )
        timeouts.schedule(1, 10) {}
        timeouts.schedule(2, 10) {}
        timeouts.clear()
        assertEquals(1, tasks.size)
        timeouts.cancel(1)
        timeouts.cancel(2)
        assertEquals(1, tasks.size)
        timeouts.cancel(3)
        assertTrue(tasks.isEmpty())
    }
}
