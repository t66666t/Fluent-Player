package com.example.video_player_app

import java.io.ByteArrayOutputStream
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

/** A bounded version probe using only process APIs available on Android 7+. */
internal object ProcessVersionProbe {
    fun readVersion(process: Process, timeoutMillis: Long = 20_000): String? {
        require(timeoutMillis > 0)
        val started = System.nanoTime()
        val budget = TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        // Drain concurrently: reading before waiting makes a silent/hung CLI
        // unbounded, while waiting before reading can fill its output pipe.
        val output = FutureTask {
            process.inputStream.use { input ->
                val prefix = ByteArrayOutputStream()
                val buffer = ByteArray(4096)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    val retained = minOf(count, (65_536 - prefix.size()).coerceAtLeast(0))
                    if (retained > 0) prefix.write(buffer, 0, retained)
                }
                prefix.toString("UTF-8")
            }
        }
        Thread(output, "binary-version-output").apply { isDaemon = true }.start()
        var completed = false
        try {
            val text = output.get(budget, TimeUnit.NANOSECONDS)
            while (true) {
                try {
                    process.exitValue()
                    completed = true
                    return text.lineSequence().firstOrNull { it.isNotBlank() }?.trim()
                } catch (_: IllegalThreadStateException) {
                    val remaining = budget - (System.nanoTime() - started)
                    if (remaining <= 0) return null
                    TimeUnit.NANOSECONDS.sleep(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(10)))
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return null
        } catch (_: Exception) {
            return null
        } finally {
            if (!completed) {
                // destroyForcibly and timed Process.waitFor both need API 26.
                // Never wait indefinitely for a misbehaving version command.
                runCatching { process.destroy() }
                output.cancel(true)
            }
            runCatching { process.outputStream.close() }
        }
    }
}
