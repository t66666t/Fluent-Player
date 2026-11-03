package com.example.video_player_app

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CancellationException
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeNoException
import org.junit.Test

class ModelImportStagingTest {
    private val cache = Files.createTempDirectory("model-import-staging-").toFile()
    private val imports get() = File(cache, "offline_model_imports")
    private val payload = "prepared model bytes".toByteArray()

    @After fun cleanup() { cache.deleteRecursively() }

    private fun request(
        path: String = "nested/model.onnx",
        candidates: List<String> = listOf("bundle/model.onnx", "model.onnx"),
        size: Long = payload.size.toLong(),
    ) = ModelImportFileRequest(path, candidates, size)

    private fun source(bytes: ByteArray = payload, knownSize: Long? = bytes.size.toLong()) =
        ModelImportSource(knownSize) { ByteArrayInputStream(bytes) }

    private fun assertNoStages() { assertTrue(imports.listFiles().orEmpty().isEmpty()) }

    @Test fun stagesOnlyRequestedNestedFilesAndPreservesProviderOriginals() {
        val original = File(cache, "provider-original.onnx").apply { writeBytes(payload) }
        val tokens = "token vocabulary".toByteArray()
        val visited = mutableListOf<String>()
        val result = ModelImportStaging.stage(cache, listOf(
            request(), request("tokens.txt", listOf("tokens.txt"), tokens.size.toLong()),
        )) { candidate ->
            visited += candidate
            when (candidate) {
                "bundle/model.onnx" -> ModelImportSource(original.length()) { original.inputStream() }
                "tokens.txt" -> source(tokens)
                else -> error("Unrequested candidate: $candidate")
            }
        }
        assertEquals(File(imports, result.token).canonicalFile, result.directory.canonicalFile)
        assertEquals(listOf("bundle/model.onnx", "tokens.txt"), visited)
        assertArrayEquals(payload, File(result.directory, "nested/model.onnx").readBytes())
        assertArrayEquals(tokens, File(result.directory, "tokens.txt").readBytes())
        assertEquals(2, result.directory.walkTopDown().count { it.isFile })
        assertArrayEquals(payload, original.readBytes())
    }

    @Test fun missingAndTruncatedCandidatesFallBackOnlyToListedNames() {
        val visited = mutableListOf<String>()
        val result = ModelImportStaging.stage(cache, listOf(request(candidates = listOf(
            "missing/model.onnx", "short/model.onnx", "valid/model.onnx", "unused/model.onnx",
        )))) { name ->
            visited += name
            when (name) {
                "missing/model.onnx" -> null
                "short/model.onnx" -> source(payload.copyOf(3), knownSize = null)
                "valid/model.onnx" -> source()
                else -> error("Must stop at the first valid candidate")
            }
        }
        assertEquals(listOf("missing/model.onnx", "short/model.onnx", "valid/model.onnx"), visited)
        assertArrayEquals(payload, File(result.directory, "nested/model.onnx").readBytes())
        assertEquals(1, result.directory.walkTopDown().count { it.isFile })
    }

    @Test fun knownSizeMismatchDoesNotOpenProviderStream() {
        var opens = 0
        val result = ModelImportStaging.stage(cache, listOf(request())) { name ->
            if (name == "bundle/model.onnx") ModelImportSource(payload.size + 1L) {
                opens += 1
                error("Mismatching metadata must be rejected before opening")
            } else source()
        }
        assertEquals(0, opens)
        assertArrayEquals(payload, File(result.directory, "nested/model.onnx").readBytes())
    }

    @Test fun nullAndNegativeProviderSizeStillRequireExactCatalogLength() {
        for (size in listOf(null, -1L)) {
            val result = ModelImportStaging.stage(cache, listOf(request())) { source(knownSize = size) }
            assertArrayEquals(payload, File(result.directory, "nested/model.onnx").readBytes())
        }
    }

    @Test fun aMultiBufferFileIsCopiedWithoutPartialArtifacts() {
        val bytes = ByteArray(1024 * 1024 + 17) { (it % 251).toByte() }
        val result = ModelImportStaging.stage(cache, listOf(request(size = bytes.size.toLong()))) {
            source(bytes, knownSize = null)
        }
        assertArrayEquals(bytes, File(result.directory, "nested/model.onnx").readBytes())
        assertEquals(1, result.directory.walkTopDown().count { it.isFile })
    }

    @Test fun zeroReturningProviderStreamStillMakesProgress() {
        val result = ModelImportStaging.stage(cache, listOf(request(candidates = listOf("model")))) {
            ModelImportSource(null) {
                object : ByteArrayInputStream(payload) {
                    override fun read(bytes: ByteArray, offset: Int, count: Int): Int = 0
                }
            }
        }
        assertArrayEquals(payload, File(result.directory, "nested/model.onnx").readBytes())
    }

    @Test fun missingFilesRollBackAlreadyCopiedFilesAndPreserveOtherStages() {
        val previous = ModelImportStaging.stage(cache, listOf(request())) { source() }
        assertThrows(IOException::class.java) {
            ModelImportStaging.stage(cache, listOf(request(), request("missing.onnx", listOf("missing")))) {
                if (it == "missing") null else source()
            }
        }
        assertEquals(listOf(previous.directory), imports.listFiles().orEmpty().toList())
        assertArrayEquals(payload, File(previous.directory, "nested/model.onnx").readBytes())
    }

    @Test fun truncatedAndOversizedStreamsNeverPublishAStage() {
        for (bytes in listOf(byteArrayOf(), payload.copyOf(3), payload + byteArrayOf(7))) {
            assertThrows(IOException::class.java) {
                ModelImportStaging.stage(cache, listOf(request(candidates = listOf("model")))) {
                    source(bytes, knownSize = null)
                }
            }
            assertNoStages()
        }
    }

    @Test fun oversizedStreamIsBoundedToCatalogLengthPlusOneByteAndCloses() {
        var consumed = 0
        var closed = false
        assertThrows(IOException::class.java) {
            ModelImportStaging.stage(cache, listOf(request(candidates = listOf("model"), size = 5))) {
                ModelImportSource(null) {
                    object : InputStream() {
                        override fun read(): Int { consumed += 1; return 42 }
                        override fun close() { closed = true }
                    }
                }
            }
        }
        assertEquals(6, consumed)
        assertTrue(closed)
        assertNoStages()
    }

    @Test fun providerFailureClosesStreamAndDoesNotChangeOriginal() {
        val original = File(cache, "original.onnx").apply { writeBytes(payload) }
        var closed = false
        assertThrows(IOException::class.java) {
            ModelImportStaging.stage(cache, listOf(request(candidates = listOf("model")))) {
                ModelImportSource(null) {
                    object : InputStream() {
                        override fun read(): Int = throw IOException("provider disconnected")
                        override fun close() { closed = true }
                    }
                }
            }
        }
        assertTrue(closed)
        assertArrayEquals(payload, original.readBytes())
        assertNoStages()
    }

    @Test fun deniedAndNullStreamsLeaveNoStage() {
        for (denied in listOf(false, true)) {
            assertThrows(IOException::class.java) {
                ModelImportStaging.stage(cache, listOf(request(candidates = listOf("model")))) {
                    ModelImportSource(null) { if (denied) throw SecurityException("revoked") else null }
                }
            }
            assertNoStages()
        }
    }

    @Test fun cancellationDuringCopyClosesAndRollsBackOnlyThisStage() {
        val previous = ModelImportStaging.stage(cache, listOf(request())) { source() }
        var cancelled = false
        var closed = false
        assertThrows(CancellationException::class.java) {
            ModelImportStaging.stage(cache, listOf(request(candidates = listOf("model"))), { cancelled }) {
                ModelImportSource(null) {
                    object : ByteArrayInputStream(payload) {
                        override fun read(bytes: ByteArray, offset: Int, count: Int): Int {
                            cancelled = true
                            return super.read(bytes, offset, count)
                        }
                        override fun close() { closed = true }
                    }
                }
            }
        }
        assertTrue(closed)
        assertEquals(listOf(previous.directory), imports.listFiles().orEmpty().toList())
        assertArrayEquals(payload, File(previous.directory, "nested/model.onnx").readBytes())
    }

    @Test fun preCancelledRequestDoesNotContactProviderOrCreateStorage() {
        assertThrows(CancellationException::class.java) {
            ModelImportStaging.stage(cache, listOf(request()), { true }) { error("No provider access") }
        }
        assertFalse(imports.exists())
    }

    @Test fun cancellationAfterLastFilePublicationPreventsReturningStage() {
        var sawPublishedFile = false
        assertThrows(CancellationException::class.java) {
            ModelImportStaging.stage(cache, listOf(request()), {
                imports.walkTopDown().any { it.isFile && it.name == "model.onnx" }.also {
                    if (it) sawPublishedFile = true
                }
            }) { source() }
        }
        assertTrue(sawPublishedFile)
        assertNoStages()
    }

    @Test fun invalidTargetsAndCandidatesAreRejectedBeforeIo() {
        val paths = listOf("", "/absolute.onnx", "C:/model.onnx", "C:model.onnx", "../model.onnx",
            "nested/../model", "nested/./model", "nested//model", "nested/model/", "\\network\\model",
            "nested\\model", "null\u0000model", "x".repeat(256), "汉".repeat(86), List(33) { "nested" }.joinToString("/"),
            List(17) { "x".repeat(255) }.joinToString("/"))
        for (path in paths) {
            for (invalid in listOf(request(path), request(candidates = listOf(path)))) {
                assertThrows("Invalid path: $path", IllegalArgumentException::class.java) {
                    ModelImportStaging.stage(cache, listOf(invalid)) { error("No provider access") }
                }
            }
        }
        assertFalse(imports.exists())
    }

    @Test fun invalidCountsSizesAndTargetCollisionsAreRejectedBeforeIo() {
        val invalid = listOf(emptyList(), List(129) { request("model-$it") },
            listOf(request(candidates = emptyList())), listOf(request(candidates = List(33) { "model-$it" })),
            List(5) { request("model-$it", candidates = List(32) { "candidate-$it" }) },
            listOf(request(size = 0)), listOf(request(size = -1)), listOf(request(), request()),
            listOf(request("nested"), request("nested/model.onnx")))
        for (requests in invalid) {
            assertThrows(IllegalArgumentException::class.java) {
                ModelImportStaging.validateRequests(requests)
            }
            assertThrows(IllegalArgumentException::class.java) {
                ModelImportStaging.stage(cache, requests) { error("No provider access") }
            }
        }
        assertFalse(imports.exists())
    }

    @Test fun cleanupRemovesOnlyItsTokenAndIsIdempotent() {
        val first = ModelImportStaging.stage(cache, listOf(request())) { source() }
        val neighbor = ModelImportStaging.stage(cache, listOf(request())) { source() }
        assertTrue(ModelImportStaging.cleanup(cache, first.token))
        assertTrue(ModelImportStaging.cleanup(cache, first.token))
        assertFalse(first.directory.exists())
        assertArrayEquals(payload, File(neighbor.directory, "nested/model.onnx").readBytes())
    }

    @Test fun invalidCleanupTokensPreserveNeighborAndOriginal() {
        val neighbor = ModelImportStaging.stage(cache, listOf(request())) { source() }
        val original = File(cache, "original.onnx").apply { writeBytes(payload) }
        for (token in listOf("", ".", "..", "../${neighbor.token}", neighbor.directory.absolutePath,
            "${neighbor.token}/../${neighbor.token}", neighbor.token.uppercase(), "1-1-1-1-1", "bad\u0000token")) {
            assertFalse(ModelImportStaging.cleanup(cache, token))
        }
        assertArrayEquals(payload, original.readBytes())
        assertArrayEquals(payload, File(neighbor.directory, "nested/model.onnx").readBytes())
    }

    @Test fun cleanupRefusesATokenLinkToAnotherDirectory() {
        val neighbor = ModelImportStaging.stage(cache, listOf(request())) { source() }
        val token = UUID.randomUUID().toString()
        val link = File(imports, token)
        try { Files.createSymbolicLink(link.toPath(), neighbor.directory.toPath()) }
        catch (error: Exception) { assumeNoException("Host does not permit symbolic links", error); return }
        try {
            assertFalse(ModelImportStaging.cleanup(cache, token))
            assertArrayEquals(payload, File(neighbor.directory, "nested/model.onnx").readBytes())
        } finally { Files.deleteIfExists(link.toPath()) }
    }
}
