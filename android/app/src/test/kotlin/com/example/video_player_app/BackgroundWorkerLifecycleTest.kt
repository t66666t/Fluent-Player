package com.example.video_player_app

import org.junit.Assert.*
import org.junit.Test

class BackgroundWorkerLifecycleTest {
    private class Fixture {
        val events = mutableListOf<String>()
        val worker = BackgroundWorkerLifecycle(
            stop = { events.add("stop") },
            unbind = { events.add("unbind") },
            failPending = { events.add("fail-pending") },
        )
        fun close(label: String = "closed") = worker.close { events.add("$label:$it") }
    }

    @Test fun probeCloseWaitsForBinderDeathBeforeRecognitionCanRebind() {
        val f = Fixture()
        f.worker.bindingStarted()
        f.worker.connected()
        f.worker.close { stopped ->
            assertTrue(stopped)
            f.events.add("start-recognition")
        }
        assertEquals(listOf("fail-pending", "stop", "unbind"), f.events)
        assertFalse(f.worker.terminated)
        f.worker.disconnected()
        assertEquals("start-recognition", f.events.last())
        assertTrue(f.worker.terminated)
    }

    @Test fun cancellationWhileBindingWaitsForTheLateConnectionAndItsDeath() {
        val f = Fixture()
        f.worker.bindingStarted()
        f.close()
        assertEquals(listOf("fail-pending"), f.events)
        assertTrue(f.worker.binding)
        f.worker.connected()
        assertEquals(listOf("fail-pending", "stop", "unbind"), f.events)
        assertFalse(f.worker.terminated)
        f.worker.disconnected()
        assertEquals("closed:true", f.events.last())
    }

    @Test fun concurrentClosesShareTheSameShutdownAndWaitForDeath() {
        val f = Fixture()
        f.worker.bindingStarted()
        f.worker.connected()
        f.close("first")
        f.close("second")
        assertEquals(listOf("fail-pending", "stop", "unbind"), f.events)
        f.worker.disconnected()
        assertEquals(listOf("first:true", "second:true"), f.events.takeLast(2))
        f.worker.disconnected()
        f.worker.connected() // A callback queued before the old process died.
        assertEquals(5, f.events.size)
    }

    @Test fun shutdownTimeoutDoesNotClaimThatTheProcessExited() {
        val f = Fixture()
        f.worker.bindingStarted()
        f.worker.connected()
        f.close()
        f.worker.closeTimedOut()
        assertEquals("closed:false", f.events.last())
        assertTrue(f.worker.closed)
        assertFalse(f.worker.terminated)
        f.close("retry")
        f.worker.disconnected()
        assertEquals("retry:true", f.events.last())
        assertEquals(1, f.events.count { it == "stop" })
    }

    @Test fun timeoutDuringBindingStillStopsTheLateServiceBeforeReusingIt() {
        val f = Fixture()
        f.worker.bindingStarted()
        f.close()
        f.worker.closeTimedOut()
        assertFalse(f.worker.terminated)
        f.worker.connected()
        assertEquals(listOf("stop", "unbind"), f.events.takeLast(2))
        assertFalse(f.worker.terminated)
        f.worker.disconnected()
        assertTrue(f.worker.terminated)
    }

    @Test fun unexpectedDeathReleasesBindingAndFailsPendingRequestsOnce() {
        val f = Fixture()
        f.worker.bindingStarted()
        f.worker.connected()
        f.worker.disconnected()
        f.worker.disconnected()
        f.close()
        assertEquals(listOf("unbind", "fail-pending", "closed:true"), f.events)
    }

    @Test fun unusedSlotsCloseImmediatelyWithoutStoppingAnyProcess() {
        val f = Fixture()
        f.close()
        assertEquals(listOf("fail-pending", "closed:true"), f.events)
    }

    @Test fun synchronousDeathDuringShutdownCannotUnbindTwice() {
        val events = mutableListOf<String>()
        lateinit var worker: BackgroundWorkerLifecycle
        worker = BackgroundWorkerLifecycle(
            stop = { worker.disconnected() },
            unbind = { events.add("unbind") },
            failPending = { events.add("fail") },
        )
        worker.bindingStarted()
        worker.connected()
        worker.close { events.add("closed:$it") }
        assertEquals(listOf("fail", "unbind", "closed:true"), events)
    }
}
