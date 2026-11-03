package com.example.video_player_app

import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Compiles the actual production bridges; only Android/Flutter transports are host substitutes. */
class RequestBridgeTimeoutTest {
    private enum class Kind { ASR, QWEN }
    private class Outcome(val completed: ((Any?) -> Unit)? = null) : MethodChannel.Result {
        val values = mutableListOf<Any?>()
        override fun success(result: Any?) { values.add(result); completed?.invoke(result) }
        override fun error(code: String, message: String?, details: Any?) = error("Unexpected platform error $code: $message")
        override fun notImplemented() = error("Unexpected missing method")
    }
    private class Remote : IBinder {
        override val isBinderAlive = true
        val messages = mutableListOf<Message>()
        var failNext = false
        var sendCost = 0L
        override fun send(message: Message) {
            HostMainLoop.elapseWithoutDispatch(sendCost)
            if (failNext) { failNext = false; throw RemoteException() }
            messages.add(message)
        }
    }
    private class App(val directory: File) : Context() {
        override val filesDir = File(directory, "files").apply { mkdirs() }
        val remote = Remote()
        var connection: ServiceConnection? = null
        var bindSucceeds = true
        var bindFailure: RuntimeException? = null
        var bindFatal: Error? = null
        var unbinds = 0
        override fun bindService(intent: Intent, connection: ServiceConnection, flags: Int): Boolean {
            bindFatal?.let { throw it }
            bindFailure?.let { throw it }
            if (!bindSucceeds) return false
            this.connection = connection
            Handler(Looper.getMainLooper()).post { connection.onServiceConnected(ComponentName(), remote) }
            return true
        }
        override fun unbindService(connection: ServiceConnection) { unbinds++ }
        override fun getSystemService(name: String): Any = ActivityManager()
    }
    private class Fixture(val kind: Kind, val app: App) {
        private val messenger = object : BinaryMessenger {}
        val bridge: Any = when (kind) {
            Kind.ASR -> AsrAccelerationBridge(app, messenger)
            Kind.QWEN -> QwenAsrBridge(app, messenger)
        }
        val channel: MethodChannel get() = MethodChannel.channels.getValue(
            "com.example.video_player_app/" + if (kind == Kind.ASR) "asr_acceleration" else "qwen_asr",
        )
        fun request(owner: String = "owner", operation: String = "open",
                    extra: Map<String, Any?> = emptyMap(), result: Outcome = Outcome()): Outcome {
            channel.call("request", mapOf("owner" to owner, "op" to operation) + extra, result)
            HostMainLoop.current()
            return result
        }
        fun close(owner: String = "owner", result: Outcome = Outcome()): Outcome {
            channel.call("close", mapOf("owner" to owner), result)
            HostMainLoop.current()
            return result
        }
        fun lastRequest() = app.remote.messages.last { it.what == 1 }
        fun lastClose() = app.remote.messages.last { it.what == 2 }
        fun reply(message: Message, malformed: Boolean = false) {
            message.replyTo!!.send(Message.obtain(null, 1).apply {
                arg1 = message.arg1
                data.putString("json", if (malformed) "malformed" else JSONObject(mapOf("ok" to true, "workerPid" to 777)).toString())
            })
            HostMainLoop.current()
        }
        fun disconnect() { app.connection!!.onServiceDisconnected(ComponentName()); HostMainLoop.current() }
        fun reconnect() { app.connection!!.onServiceConnected(ComponentName(), app.remote); HostMainLoop.current() }
        fun privateSize(name: String): Int {
            val value = bridge.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(bridge)
            return when (value) { is Map<*, *> -> value.size; is Collection<*> -> value.size; else -> error(name) }
        }
        fun audio(): String = File(app.filesDir, "input.pcm").apply { writeBytes(byteArrayOf(0, 0)) }.canonicalPath
    }
    private val apps = mutableListOf<App>()
    private fun fixture(kind: Kind): Fixture {
        HostMainLoop.reset(); MethodChannel.channels.clear(); JSONObject.reset(); Process.killed.clear()
        val root = File(System.getProperty("request.timeout.test.temp")).canonicalFile.apply { mkdirs() }
        val directory = Files.createTempDirectory(root.toPath(), "bridge-").toFile().canonicalFile
        check(directory.toPath().startsWith(root.toPath()) && directory != root)
        val app = App(directory)
        apps.add(app)
        return Fixture(kind, app)
    }
    @After fun cleanup() {
        val root = File(System.getProperty("request.timeout.test.temp")).canonicalFile
        for (app in apps) {
            val directory = app.directory.canonicalFile
            check(directory.toPath().startsWith(root.toPath()) && directory != root)
            check(directory.deleteRecursively())
        }
    }
    private fun assertFailed(result: Outcome) {
        assertEquals(1, result.values.size)
        assertEquals(false, (result.values.single() as Map<*, *>)["ok"])
    }
    private fun assertNoTimeouts() = assertTrue("Completed work retained scheduled callbacks: ${HostMainLoop.scheduled.map { it.due }}", HostMainLoop.scheduled.isEmpty())

    @Test fun completedAsrRequestsLeaveNoWatchdogsOrLaterDispatch() = completedBatch(Kind.ASR)
    @Test fun completedQwenRequestsLeaveNoWatchdogsOrLaterDispatch() = completedBatch(Kind.QWEN)
    private fun completedBatch(kind: Kind) {
        val f = fixture(kind)
        repeat(1000) {
            val result = f.request()
            f.reply(f.lastRequest())
            assertEquals(1, result.values.size)
        }
        assertNoTimeouts()
        val dispatched = HostMainLoop.dispatched
        HostMainLoop.advance(720_000)
        assertEquals(dispatched, HostMainLoop.dispatched)
    }

    @Test fun malformedRepliesStillRetireTheirTimeouts() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            val result = f.request()
            f.reply(f.lastRequest(), malformed = true)
            assertFailed(result)
            assertNoTimeouts()
        }
    }

    @Test fun sendFailureRetiresAnAlreadyArmedRequest() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            f.app.remote.failNext = true
            assertFailed(f.request())
            assertEquals(0, f.privateSize("pending"))
            assertNoTimeouts()
        }
    }

    @Test fun falseBindingDoesNotArmAnAlreadyFailedRequest() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            f.app.bindSucceeds = false
            assertFailed(f.request())
            assertEquals(0, f.privateSize("queued"))
            assertNoTimeouts()
        }
    }

    @Test fun thrownBindingFailureCompletesAndReleasesTheRequest() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            f.app.bindFailure = SecurityException("denied")
            val result = Outcome()
            val thrown = runCatching { f.request(result = result) }.exceptionOrNull()
            assertNull("bindService exception escaped without terminal cleanup", thrown)
            assertFailed(result)
            assertEquals(0, f.privateSize("pending"))
            assertEquals(0, f.privateSize("queued"))
            assertNoTimeouts()
        }
    }

    @Test fun fatalBindingErrorsAreNotConvertedIntoOrdinaryFailure() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            val fatal = AssertionError("fatal test sentinel")
            f.app.bindFatal = fatal
            assertSame(fatal, runCatching { f.request() }.exceptionOrNull())
        }
    }

    @Test fun asrCloseAndDisconnectCancelAllOutstandingRequestCallbacks() {
        for (disconnect in listOf(false, true)) {
            val f = fixture(Kind.ASR)
            val first = f.request()
            val second = f.request(operation = "load")
            if (disconnect) f.disconnect() else f.close()
            assertFailed(first); assertFailed(second)
            assertNoTimeouts()
        }
    }

    @Test fun qwenOwnerCloseKeepsOtherOwnerAliveAndCancelsItsOwnRequests() {
        val f = fixture(Kind.QWEN)
        f.request("a"); f.reply(f.lastRequest())
        f.request("b"); f.reply(f.lastRequest())
        val first = f.request("a")
        val second = f.request("b")
        val secondMessage = f.lastRequest()
        val closed = f.close("a")
        assertFailed(first)
        assertTrue(second.values.isEmpty()); assertTrue(closed.values.isEmpty())
        assertEquals(2, HostMainLoop.scheduled.size) // Owner b request + real close acknowledgement deadline.
        f.reply(f.lastClose())
        assertEquals(1, closed.values.size)
        assertEquals(1, HostMainLoop.scheduled.size)
        assertEquals(0, f.app.unbinds)
        f.reply(secondMessage)
        assertEquals(1, second.values.size)
        assertNoTimeouts()
    }

    @Test fun qwenCloseReplyRemovesItsFourSecondFallback() {
        val f = fixture(Kind.QWEN)
        f.request(); f.reply(f.lastRequest())
        val result = f.close()
        assertEquals(1, HostMainLoop.scheduled.size)
        f.reply(f.lastClose())
        assertEquals(1, result.values.size)
        assertEquals(1, f.app.unbinds)
        assertNoTimeouts()
        HostMainLoop.advance(4_000)
        assertEquals(1, result.values.size)
    }

    @Test fun qwenImmediateCloseDoesNotCreateAnOrphanFallback() {
        val f = fixture(Kind.QWEN)
        val result = f.close()
        assertEquals(1, result.values.size)
        assertNoTimeouts()
    }

    @Test fun qwenFailedCloseSendUsesImmediateCompletionWithoutOrphanFallback() {
        val f = fixture(Kind.QWEN)
        f.request(); f.reply(f.lastRequest())
        f.app.remote.failNext = true
        val result = f.close()
        assertEquals(1, result.values.size)
        assertNoTimeouts()
    }

    @Test fun qwenUnacknowledgedCloseStillCompletesAtFourSecondsOnlyOnce() {
        val f = fixture(Kind.QWEN)
        f.request(); f.reply(f.lastRequest())
        val result = f.close()
        val closing = f.lastClose()
        HostMainLoop.advance(3_999)
        assertTrue(result.values.isEmpty())
        HostMainLoop.advance(1)
        assertEquals(1, result.values.size)
        f.reply(closing)
        assertEquals(1, result.values.size)
        assertNoTimeouts()
    }

    @Test fun disconnectClearDoesNotCancelAReentrantReplacementRequest() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            val replacement = Outcome()
            val first = Outcome { f.request("replacement", result = replacement) }
            f.request(result = first)
            val stale = f.lastRequest()
            f.disconnect()
            assertFailed(first)
            assertEquals(1, f.privateSize("pending"))
            assertEquals(1, HostMainLoop.scheduled.size)
            f.reply(stale) // A late reply must not retire the replacement's deadline.
            assertEquals(1, HostMainLoop.scheduled.size)
            f.reconnect()
            f.reply(f.lastRequest())
            assertEquals(1, replacement.values.size)
            assertNoTimeouts()
        }
    }

    @Test fun replyCompletionCannotCancelAReentrantReplacementDeadline() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            val replacement = Outcome()
            val first = Outcome { f.request("replacement", result = replacement) }
            f.request(result = first)
            f.reply(f.lastRequest())
            assertEquals(1, first.values.size)
            assertTrue(replacement.values.isEmpty())
            assertEquals(1, f.privateSize("pending"))
            assertEquals(1, HostMainLoop.scheduled.size)
            f.reply(f.lastRequest())
            assertEquals(1, replacement.values.size)
            assertNoTimeouts()
        }
    }

    @Test fun qwenDisconnectCannotFinishACloseCreatedByAReentrantResult() {
        val f = fixture(Kind.QWEN)
        val replacementClose = Outcome()
        val first = Outcome {
            f.reconnect()
            f.close("owner", replacementClose)
        }
        f.request(result = first)
        f.disconnect()
        assertFailed(first)
        assertTrue("failAll prematurely completed a newly created close", replacementClose.values.isEmpty())
        assertEquals(1, f.privateSize("closing"))
        assertEquals(1, HostMainLoop.scheduled.size)
        f.reply(f.lastClose())
        assertEquals(1, replacementClose.values.size)
        assertNoTimeouts()
    }

    @Test fun qwenDisconnectClearsRequestsAndCloseFallbacks() {
        val f = fixture(Kind.QWEN)
        f.request("a"); f.reply(f.lastRequest())
        val closed = f.close("a")
        val pending = f.request("b")
        f.disconnect()
        assertEquals(1, closed.values.size)
        assertFailed(pending)
        assertNoTimeouts()
    }

    @Test fun requestDeadlinesStartAfterSynchronousDispatchAsBefore() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            f.request(); f.reply(f.lastRequest())
            f.app.remote.sendCost = 73
            f.request(operation = "load", extra = mapOf("backend" to "cpu"))
            val delay = if (kind == Kind.ASR) 120_000L else 300_000L
            assertEquals(73L, HostMainLoop.now)
            assertEquals(listOf(73 + delay), HostMainLoop.scheduled.map { it.due })
        }
    }

    @Test fun activeAsrRequestStillTimesOutAtItsOriginalDeadline() {
        for ((operation, delay) in listOf("open" to 60_000L, "load" to 120_000L)) {
            val f = fixture(Kind.ASR)
            val result = f.request(operation = operation)
            HostMainLoop.advance(delay - 1)
            assertTrue(result.values.isEmpty())
            HostMainLoop.advance(1)
            assertFailed(result)
            assertEquals(2, f.app.remote.messages.last().what)
            assertNoTimeouts()
        }
    }

    @Test fun activeQwenCpuAndLoadDeadlinesPreserveTheCloseFence() {
        for ((operation, delay) in listOf("open" to 720_000L, "load" to 300_000L)) {
            val f = fixture(Kind.QWEN)
            val result = f.request(operation = operation, extra = mapOf("backend" to "cpu"))
            HostMainLoop.advance(delay - 1)
            assertTrue(result.values.isEmpty())
            HostMainLoop.advance(1)
            assertFailed(result)
            assertEquals(2, f.app.remote.messages.last().what)
            assertEquals(1, HostMainLoop.scheduled.size)
            HostMainLoop.advance(4_000)
            assertNoTimeouts()
        }
    }

    @Test fun gpuTimeoutStillWaitsForBinderDeathAndAcceptsAPendingLateReply() {
        val f = fixture(Kind.QWEN)
        f.request(); f.reply(f.lastRequest())
        f.request(operation = "load", extra = mapOf("backend" to "vulkan")); f.reply(f.lastRequest())
        val result = f.request(operation = "decode", extra = mapOf("path" to f.audio()))
        val decode = f.lastRequest()
        HostMainLoop.advance(119_999)
        assertTrue(Process.killed.isEmpty()); assertTrue(result.values.isEmpty())
        HostMainLoop.advance(1)
        assertEquals(listOf(777), Process.killed)
        assertTrue(result.values.isEmpty())
        assertEquals(1, f.privateSize("pending"))
        f.reply(decode)
        assertEquals(1, result.values.size)
        assertNoTimeouts()
    }

    @Test fun cancelledAlreadyDequeuedWatchdogCannotAffectNewRequests() {
        for (kind in Kind.entries) {
            val f = fixture(kind)
            f.request()
            val stale = HostMainLoop.scheduled.single().runnable
            f.reply(f.lastRequest())
            val next = f.request("new-owner")
            stale.run()
            assertTrue(next.values.isEmpty())
            assertEquals(1, f.privateSize("pending"))
            f.reply(f.lastRequest())
            assertEquals(1, next.values.size)
            assertNoTimeouts()
        }
    }
}
