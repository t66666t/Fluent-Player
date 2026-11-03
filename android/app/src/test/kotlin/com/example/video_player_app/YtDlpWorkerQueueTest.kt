package com.example.video_player_app

import org.junit.Assert.*
import org.junit.Test

class YtDlpWorkerQueueTest {
    private class Fixture {
        val events = mutableListOf<String>()
        val queue = YtDlpWorkerQueue(
            launch = { id, request -> events.add("start:$id:$request") },
            stop = { id, action -> events.add("stop:$id:$action") },
            release = { events.add("release") },
            stopped = { id, action -> events.add("stopped:$id:$action") },
            failed = { id, _ -> events.add("failed:$id") },
        )
    }

    @Test fun rapidStartsWaitForActualCompletion() {
        val f = Fixture()
        f.queue.enqueue("a", "first")
        f.queue.enqueue("b", "second")
        f.queue.enqueue("c", "third")
        assertEquals(listOf("start:a:first"), f.events)
        f.queue.finished("a")
        assertEquals(listOf("start:a:first", "release", "start:b:second"), f.events)
        f.queue.finished("b")
        assertEquals("start:c:third", f.events.last())
    }

    @Test fun immediateResumeWaitsForCooperativePauseConfirmation() {
        val f = Fixture()
        f.queue.enqueue("video__run_1", "partial")
        assertTrue(f.queue.requestStop("video__run_1", "pause"))
        f.queue.enqueue("video__run_2", "resume")
        assertEquals(listOf("start:video__run_1:partial", "stop:video__run_1:pause"), f.events)
        f.queue.finished("video__run_1")
        assertEquals("start:video__run_2:resume", f.events.last())
    }

    @Test fun forcedPauseWaitsForBinderDeathAndReleasesOldBindingFirst() {
        val f = Fixture()
        f.queue.enqueue("a", "partial")
        f.queue.requestStop("a", "pause")
        f.queue.enqueue("b", "next")
        assertEquals(2, f.events.size)
        f.queue.disconnected()
        assertEquals(listOf(
            "start:a:partial", "stop:a:pause", "release", "stopped:a:pause", "start:b:next",
        ), f.events)
    }

    @Test fun forcedCancelConfirmsBeforeNextTask() {
        val f = Fixture()
        f.queue.enqueue("a", "download")
        f.queue.requestStop("a", "cancel")
        f.queue.enqueue("b", "next")
        f.queue.disconnected()
        assertEquals("stopped:a:cancel", f.events[3])
        assertEquals("start:b:next", f.events[4])
    }

    @Test fun pendingTasksCanBePausedOrCancelledWithoutStoppingActiveWorker() {
        for (action in listOf("pause", "cancel")) {
            val f = Fixture()
            f.queue.enqueue("a", "active")
            f.queue.enqueue("b", "pending")
            assertTrue(f.queue.requestStop("b", action))
            assertEquals(listOf("start:a:active", "stopped:b:$action"), f.events)
            f.queue.finished("b") // Terminal callback for the pending task.
            assertEquals("a", f.queue.activeTaskId)
            f.queue.finished("a")
            assertNull(f.queue.activeTaskId)
            assertEquals("release", f.events.last())
        }
    }

    @Test fun duplicateStartsAndStopRequestsAreIdempotent() {
        val f = Fixture()
        f.queue.enqueue("a", "active")
        f.queue.enqueue("a", "duplicate")
        f.queue.enqueue("b", "pending")
        f.queue.enqueue("b", "duplicate")
        f.queue.requestStop("a", "pause")
        f.queue.requestStop("a", "pause")
        assertEquals(listOf("start:a:active", "stop:a:pause"), f.events)
        f.queue.finished("a")
        assertEquals("start:b:pending", f.events.last())
    }

    @Test fun staleTerminalEventCannotReleaseNewExecution() {
        val f = Fixture()
        f.queue.enqueue("video__run_1", "first")
        f.queue.enqueue("video__run_2", "second")
        f.queue.finished("video__run_1")
        val before = f.events.toList()
        f.queue.finished("video__run_1")
        assertEquals(before, f.events)
        assertEquals("video__run_2", f.queue.activeTaskId)
    }

    @Test fun unexpectedDeathFailsActiveTaskAndContinuesQueue() {
        val f = Fixture()
        f.queue.enqueue("a", "active")
        f.queue.enqueue("b", "pending")
        f.queue.disconnected()
        assertEquals(listOf("start:a:active", "release", "failed:a", "start:b:pending"), f.events)
    }

    @Test fun closingDoesNotStartPendingWorkOrAcceptNewWork() {
        val f = Fixture()
        f.queue.enqueue("a", "active")
        f.queue.enqueue("b", "pending")
        f.queue.close()
        val before = f.events.toList()
        f.queue.finished("a")
        f.queue.disconnected()
        f.queue.enqueue("c", "late")
        assertFalse(f.queue.requestStop("c", "pause"))
        assertEquals(listOf("start:a:active", "stop:a:cancel", "release"), before)
        assertEquals(before, f.events)
    }

    @Test fun rejectedStopDoesNotTurnLaterProcessDeathIntoSuccessfulPause() {
        val events = mutableListOf<String>()
        val queue = YtDlpWorkerQueue(
            launch = { _, _ -> },
            stop = { _, _ -> false },
            release = { },
            stopped = { _, _ -> events.add("paused") },
            failed = { _, _ -> events.add("failed") },
        )
        queue.enqueue("a", "active")
        assertFalse(queue.requestStop("a", "pause"))
        assertNull(queue.stopAction)
        queue.disconnected()
        assertEquals(listOf("failed"), events)
    }
}
