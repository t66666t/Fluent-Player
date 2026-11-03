package com.example.video_player_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

class ProcessVersionProbeTest {
    private fun start(mode: String): Process = ProcessBuilder(
        File(System.getProperty("java.home"), "bin/java").absolutePath,
        "-cp", System.getProperty("java.class.path"), VersionProbeChild::class.java.name, mode,
    ).redirectErrorStream(true).start()

    @Test fun readsFirstNonemptyVersionLine() {
        assertEquals("ffmpeg fixture 1.0", ProcessVersionProbe.readVersion(start("version"), 5000))
    }

    @Test fun drainsOutputLargerThanPipeWithoutDeadlock() {
        assertEquals("ffmpeg fixture 1.0", ProcessVersionProbe.readVersion(start("large"), 5000))
    }

    @Test fun emptyOutputIsNotAVersion() {
        assertNull(ProcessVersionProbe.readVersion(start("empty"), 5000))
    }

    @Test fun silentProcessHasABoundedDeadlineAndIsDestroyed() {
        val process = start("silent")
        val started = System.nanoTime()
        assertNull(ProcessVersionProbe.readVersion(process, 500))
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 3000)
        // The test JVM has this API; production code deliberately does not.
        assertTrue(process.waitFor(3, TimeUnit.SECONDS))
    }

    @Test fun outputBeforeAHangStillHonorsDeadline() {
        val process = start("printThenHang")
        val started = System.nanoTime()
        assertNull(ProcessVersionProbe.readVersion(process, 500))
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 3000)
        assertTrue(process.waitFor(3, TimeUnit.SECONDS))
    }
}

object VersionProbeChild {
    @JvmStatic fun main(args: Array<String>) {
        when (args.single()) {
            "version" -> println("\n  ffmpeg fixture 1.0  \nconfiguration: fixture")
            "large" -> {
                println("ffmpeg fixture 1.0")
                repeat(1024) { println("x".repeat(1024)) }
            }
            "empty" -> Unit
            "silent" -> Thread.sleep(30_000)
            "printThenHang" -> {
                println("ffmpeg fixture 1.0")
                Thread.sleep(30_000)
            }
        }
    }
}
