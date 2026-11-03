package com.example.video_player_app

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.Assume.assumeNoException

class MediaImportFilesTest {
    private val root = Files.createTempDirectory("media-import-test-").toFile()
    private val bytes = "provider media bytes".toByteArray()

    @After fun cleanup() { root.deleteRecursively() }

    private fun copy(name: String = "视频.mp4", size: Long? = bytes.size.toLong()): File =
        MediaImportFiles.copyToCache(root, name, size) { ByteArrayInputStream(bytes) }

    private fun assertNoCopies() {
        assertTrue(File(root, "picked_media").walkTopDown().none { it.isFile })
        assertTrue(File(root, "picked_media").listFiles().orEmpty().isEmpty())
    }

    @Test fun providerWithoutRawPathUsesReadableCopy() {
        val selected = MediaImportFiles.resolve(null) { copy() }
        assertTrue(selected.ownedCopy)
        assertEquals("视频.mp4", selected.file.name)
        assertArrayEquals(bytes, selected.file.readBytes())
    }

    @Test fun readableOriginalIsNeverCopiedOrDeleted() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        val selected = MediaImportFiles.resolve(original.path) { error("Must retain readable original") }
        assertFalse(selected.ownedCopy)
        selected.discardCopy()
        assertArrayEquals(bytes, original.readBytes())
    }

    @Test fun nonexistentRawPathFallsBackToProvider() {
        val selected = MediaImportFiles.resolve(File(root, "missing.mp4").path) { copy() }
        assertTrue(selected.ownedCopy)
        assertArrayEquals(bytes, selected.file.readBytes())
    }

    @Test fun directoryIsNotAnImportableRawFile() {
        val selected = MediaImportFiles.resolve(root.path) { copy() }
        assertTrue(selected.ownedCopy)
    }

    @Test fun unknownProviderSizeStillCopiesCompleteStream() {
        assertArrayEquals(bytes, copy(size = null).readBytes())
        assertArrayEquals(bytes, copy(size = -1).readBytes())
    }

    @Test fun failedStreamDeletesPartialAndNeverTouchesOriginal() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        assertThrows(IOException::class.java) {
            MediaImportFiles.copyToCache(root, original.name, null) {
                object : InputStream() {
                    var read = 0
                    override fun read(): Int {
                        if (++read > 3) throw IOException("provider disconnected")
                        return 42
                    }
                }
            }
        }
        assertNoCopies()
        assertArrayEquals(bytes, original.readBytes())
    }

    @Test fun deniedOrNullStreamLeavesNoCopy() {
        assertThrows(SecurityException::class.java) {
            MediaImportFiles.copyToCache(root, "denied.mp4", null) { throw SecurityException("grant revoked") }
        }
        assertThrows(IOException::class.java) {
            MediaImportFiles.copyToCache(root, "null.mp4", null) { null }
        }
        assertNoCopies()
    }

    @Test fun earlyEofAndEmptyMediaAreNotPublishedAsComplete() {
        assertThrows(IOException::class.java) { copy(size = bytes.size + 10L) }
        assertThrows(IOException::class.java) {
            MediaImportFiles.copyToCache(root, "empty.mp4", 0L) { ByteArrayInputStream(byteArrayOf()) }
        }
        assertNoCopies()
    }

    @Test fun failedBatchRollsBackOnlyItsOwnedCopies() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        val previousSelection = copy("previous.mp4")
        var owned: File? = null
        assertThrows(IOException::class.java) {
            MediaImportFiles.resolveSelection(listOf("raw", "copy", "failed")) { item ->
                when (item) {
                    "raw" -> MediaImportFiles.resolve(original.path) { error("Not copied") }
                    "copy" -> MediaImportFiles.resolve(null) { copy().also { owned = it } }
                    else -> null
                }
            }
        }
        val ownedCopy = requireNotNull(owned)
        assertFalse(ownedCopy.exists())
        assertFalse(ownedCopy.parentFile.exists())
        assertArrayEquals(bytes, original.readBytes())
        assertArrayEquals(bytes, previousSelection.readBytes())
    }

    @Test fun sameNameConcurrentCopiesAreIsolatedAndKeepTheirTitles() {
        val executor = Executors.newFixedThreadPool(4)
        try {
            val paths = executor.invokeAll((1..8).map { n -> Callable {
                val payload = "media-$n".toByteArray()
                MediaImportFiles.copyToCache(root, "同名.mp4", payload.size.toLong()) {
                    ByteArrayInputStream(payload)
                }
            }}).map { it.get() }
            assertEquals(8, paths.map { it.absolutePath }.distinct().size)
            paths.forEachIndexed { index, file ->
                assertEquals("同名.mp4", file.name)
                assertEquals("media-${index + 1}", file.readText())
            }
        } finally { executor.shutdownNow() }
    }

    @Test fun successfulBatchPreservesSelectionOrderAndEmptySelectionDoesNoIo() {
        val copies = mutableListOf<File>()
        val paths = MediaImportFiles.resolveSelection(listOf("second.mp4", "first.mp4")) { name ->
            MediaImportFiles.resolve(null) { copy(name).also { copies.add(it) } }
        }
        assertEquals(copies.map { it.absolutePath }, paths)
        assertEquals(listOf("second.mp4", "first.mp4"), paths.map { File(it).name })
        assertTrue(MediaImportFiles.resolveSelection(emptyList<String>()) { error("Cancelled selection") }.isEmpty())
    }

    @Test fun destinationCannotEscapeItsOwnedDirectory() {
        assertThrows(IllegalArgumentException::class.java) { copy("../outside.mp4") }
        assertNoCopies()
    }

    @Test fun contentUriWithReadableRawFileStillUsesOwnedProviderBytes() {
        val original = File(root, "original.mp4").apply { writeText("raw original sentinel") }
        val selected = MediaImportFiles.resolveUri("content", { original.path }) { copy() }
        assertTrue("A content grant must not be replaced by a broad-permission raw path", selected.ownedCopy)
        assertNotEquals(original.absolutePath, selected.file.absolutePath)
        assertArrayEquals(bytes, selected.file.readBytes())
        selected.discardCopy()
        assertEquals("raw original sentinel", original.readText())
        assertNoCopies()
    }

    @Test fun contentGrantFailureCannotFallBackToBroadlyReadableRawFile() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        assertThrows(SecurityException::class.java) {
            MediaImportFiles.resolveUri("content", { original.path }) {
                MediaImportFiles.copyToCache(root, original.name, null) { throw SecurityException("grant revoked") }
            }
        }
        assertArrayEquals(bytes, original.readBytes())
        assertNoCopies()
    }

    @Test fun contentTruncatedStreamCannotBeMaskedByReadableRawFile() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        assertThrows(IOException::class.java) {
            MediaImportFiles.resolveUri("content", { original.path }) { copy(size = bytes.size + 1L) }
        }
        assertArrayEquals(bytes, original.readBytes())
        assertNoCopies()
    }

    @Test fun failedContentBatchDiscardsOnlyThisSelectionsOwnedCopies() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        val previous = copy("previous.mp4")
        var copied: File? = null
        assertThrows(IOException::class.java) {
            MediaImportFiles.resolveSelection(listOf(1, 2)) { index ->
                MediaImportFiles.resolveUri("content", { original.path }) {
                    if (index == 1) copy().also { copied = it }
                    else throw IOException("second stream interrupted")
                }
            }
        }
        assertNotNull(copied)
        assertFalse(copied!!.exists())
        assertArrayEquals(bytes, original.readBytes())
        assertArrayEquals(bytes, previous.readBytes())
    }

    @Test fun contentSelectionsWithSameRawCandidateHaveIndependentOwnedCopies() {
        val original = File(root, "same.mp4").apply { writeBytes(bytes) }
        val selected = (1..2).map { index ->
            MediaImportFiles.resolveUri("content", { original.path }) {
                val payload = "provider-$index".toByteArray()
                MediaImportFiles.copyToCache(root, original.name, payload.size.toLong()) { ByteArrayInputStream(payload) }
            }
        }
        assertTrue(selected.all { it.ownedCopy })
        assertEquals(2, selected.map { it.file.absolutePath }.distinct().size)
        assertEquals(listOf("provider-1", "provider-2"), selected.map { it.file.readText() })
        selected.forEach { it.discardCopy() }
        assertArrayEquals(bytes, original.readBytes())
        assertNoCopies()
    }

    @Test fun fileUriRetainsReadableOriginalAndNeverOwnsIt() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        val selected = MediaImportFiles.resolveUri("file", { original.path }) { error("File URI should retain its original") }
        assertFalse(selected.ownedCopy)
        selected.discardCopy()
        assertArrayEquals(bytes, original.readBytes())
        assertNoCopies()
    }

    @Test fun contentNeverQueriesTheDirectPathEvenWhenItWouldBeReadable() {
        val selected = MediaImportFiles.resolveUri("content", { error("A content URI must not resolve a direct _data path") }) { copy() }
        assertTrue(selected.ownedCopy)
        assertNull(selected.sourcePathHint)
        selected.discardCopy()
        assertNoCopies()
    }

    @Test fun successfulContentCopyHasImmutableReadOnlySidecarHint() {
        val original = File(root, "movie.mp4").apply { writeBytes(bytes) }
        val subtitle = File(root, "movie.srt").apply { writeText("subtitle original sentinel") }
        var currentHint = original.path
        val selected = MediaImportFiles.resolveUri("content", { error("No direct path") }, {
            MediaImportFiles.readableExternalDocumentHint(
                "com.android.externalstorage.documents", "primary:${File(currentHint).name}", root, null,
            )
        }) { copy() }
        currentHint = File(root, "other.mp4").path
        assertTrue(selected.ownedCopy)
        assertEquals(original.canonicalPath, selected.sourcePathHint)
        selected.discardCopy()
        assertArrayEquals(bytes, original.readBytes())
        assertEquals("subtitle original sentinel", subtitle.readText())
        assertNoCopies()
    }

    @Test fun failedCopyNeverResolvesOrExposesASidecarHint() {
        var hintRead = false
        assertThrows(IOException::class.java) {
            MediaImportFiles.resolveUri("content", { error("No direct path") }, {
                hintRead = true
                null
            }) { copy(size = bytes.size + 1L) }
        }
        assertFalse(hintRead)
        assertNoCopies()
    }

    @Test fun hintFailureDoesNotDiscardSuccessfullyStagedMedia() {
        val selected = MediaImportFiles.resolveUri("content", { error("No direct path") }, {
            throw SecurityException("No adjacent-directory grant")
        }) { copy() }
        assertTrue(selected.ownedCopy)
        assertNull(selected.sourcePathHint)
        assertArrayEquals(bytes, selected.file.readBytes())
    }

    @Test fun untrustedProviderCannotSupplyARawHintButStillImportsItsStream() {
        val original = File(root, "movie.mp4").apply { writeBytes(bytes) }
        val selected = MediaImportFiles.resolveUri("content", { error("Untrusted _data must never be queried") }, {
            MediaImportFiles.readableExternalDocumentHint("untrusted.provider", "primary:movie.mp4", root, null)
        }) { copy() }
        assertTrue(selected.ownedCopy)
        assertNull(selected.sourcePathHint)
        assertArrayEquals(bytes, selected.file.readBytes())
        selected.discardCopy()
        assertArrayEquals(bytes, original.readBytes())
    }

    @Test fun trustedHintRejectsTraversalAbsoluteUrisMissingFilesAndDirectories() {
        File(root, "movie.mp4").writeBytes(bytes)
        File(root, "folder").mkdir()
        val invalid = listOf("primary:../movie.mp4", "primary:/movie.mp4", "primary:./movie.mp4",
            "primary:folder/../movie.mp4", "primary:folder//movie.mp4", "primary:folder\\movie.mp4",
            "primary:content://provider/movie.mp4", "primary:file:///movie.mp4", "primary:https://host/movie.mp4",
            "primary:missing.mp4", "primary:folder", "primary:", "primary", ":movie.mp4")
        for (documentId in invalid) {
            assertNull(documentId, MediaImportFiles.readableExternalDocumentHint(
                "com.android.externalstorage.documents", documentId, root, null,
            ))
        }
        assertEquals(File(root, "movie.mp4").canonicalPath, MediaImportFiles.readableExternalDocumentHint(
            "com.android.externalstorage.documents", "primary:movie.mp4", root, null,
        ))
    }

    @Test fun trustedSecondaryHintMustMatchAnExistingUuidVolumeRoot() {
        val volume = File(root, "A1B2-C3D4").apply { mkdir() }
        val original = File(volume, "movie.mp4").apply { writeBytes(bytes) }
        assertEquals(original.canonicalPath, MediaImportFiles.readableExternalDocumentHint(
            "com.android.externalstorage.documents", "a1b2-c3d4:movie.mp4", root, volume,
        ))
        for (documentId in listOf("DEAD-BEEF:movie.mp4", "unverified:movie.mp4", "A1B2-C3D4:../movie.mp4")) {
            assertNull(MediaImportFiles.readableExternalDocumentHint(
                "com.android.externalstorage.documents", documentId, root, volume,
            ))
        }
        assertNull(MediaImportFiles.readableExternalDocumentHint(
            "com.android.externalstorage.documents", "A1B2-C3D4:movie.mp4", root, null,
        ))
    }

    @Test fun trustedHintRejectsLeafSymlinkEvenWhenItsTargetIsInsideTheRoot() {
        val original = File(root, "movie.mp4").apply { writeBytes(bytes) }
        val link = File(root, "alias.mp4")
        try {
            Files.createSymbolicLink(link.toPath(), original.toPath())
        } catch (error: Exception) {
            System.err.println("SYMLINK_FIXTURE_UNAVAILABLE: " + error.javaClass.simpleName)
            assumeNoException(error)
        }
        assertNull(MediaImportFiles.readableExternalDocumentHint(
            "com.android.externalstorage.documents", "primary:alias.mp4", root, null,
        ))
        assertArrayEquals(bytes, original.readBytes())
    }

    @Test fun optInPayloadHintsBelongOnlyToItsSuccessfullyOwnedSelection() {
        val firstOriginal = File(root, "first.mp4").apply { writeBytes(bytes) }
        val secondOriginal = File(root, "second.mp4").apply { writeBytes(bytes) }
        fun select(original: File): Map<*, *> = MediaImportFiles.resolveSelectionPayload(listOf(original), true) {
            MediaImportFiles.resolveUri("content", { error("No direct path") }, { it.canonicalPath }) { copy(it.name) }
        } as Map<*, *>
        val first = select(firstOriginal)
        val firstPaths = first["paths"] as List<*>
        val firstHints = first["sourcePathHints"] as Map<*, *>
        assertEquals(mapOf(firstPaths.single() to firstOriginal.canonicalPath), firstHints)
        val second = select(secondOriginal)
        val secondPaths = second["paths"] as List<*>
        assertEquals(mapOf(secondPaths.single() to secondOriginal.canonicalPath), second["sourcePathHints"])
        assertFalse((second["sourcePathHints"] as Map<*, *>).containsKey(firstPaths.single()))
        assertEquals(mapOf(firstPaths.single() to firstOriginal.canonicalPath), firstHints)
        val direct = MediaImportFiles.resolveSelectionPayload(listOf(firstOriginal), true) {
            ImportableMediaFile(it, false, secondOriginal.path)
        } as Map<*, *>
        assertEquals(emptyMap<String, String>(), direct["sourcePathHints"])
    }

    @Test fun legacyPayloadRemainsAPathListAndCancelledOptInDoesNoIo() {
        val original = File(root, "original.mp4").apply { writeBytes(bytes) }
        val legacy = MediaImportFiles.resolveSelectionPayload(listOf(original), false) {
            MediaImportFiles.resolveUri("file", { it.path }) { error("No copy") }
        }
        assertEquals(listOf(original.absolutePath), legacy)
        val empty = MediaImportFiles.resolveSelectionPayload(emptyList<File>(), true) { error("No IO") } as Map<*, *>
        assertEquals(emptyList<String>(), empty["paths"])
        assertEquals(emptyMap<String, String>(), empty["sourcePathHints"])
    }

    @Test fun officialMediaStoreDocumentsKeepOnlyCanonicalSharedStorageHints() {
        val original = File(root, "movie.mp4").apply { writeBytes(bytes) }
        assertEquals(original.canonicalPath, MediaImportFiles.readableMediaStoreHint(
            "com.android.providers.media.documents", "video:42", original.path, root, null,
        ))
        assertEquals(original.canonicalPath, MediaImportFiles.readableMediaStoreHint(
            "media", "/external_primary/audio/media/42", original.path, root, null,
        ))
        for (source in listOf("video:../42", "image:42", "video:42/other", "video:-42")) {
            assertNull(MediaImportFiles.readableMediaStoreHint(
                "com.android.providers.media.documents", source, original.path, root, null,
            ))
        }
        for (source in listOf("/internal/video/media/42", "/external/file/42", "/external/video/media/42/../43")) {
            assertNull(MediaImportFiles.readableMediaStoreHint("media", source, original.path, root, null))
        }
        assertNull(MediaImportFiles.readableMediaStoreHint("evil.provider", "video:42", original.path, root, null))
        assertNull(MediaImportFiles.readableMediaStoreHint("media", "/external/video/media/42", "relative.mp4", root, null))
        assertNull(MediaImportFiles.readableMediaStoreHint("media", "/external/video/media/42", root.path, root, null))
    }

    @Test fun officialMediaStoreCannotHintAnUnrelatedRootOrSymlink() {
        val primary = File(root, "primary").apply { mkdir() }
        val unrelated = File(root, "unrelated.mp4").apply { writeBytes(bytes) }
        assertNull(MediaImportFiles.readableMediaStoreHint(
            "com.android.providers.media.documents", "video:42", unrelated.path, primary, null,
        ))
        val original = File(primary, "movie.mp4").apply { writeBytes(bytes) }
        val link = File(primary, "alias.mp4")
        try { Files.createSymbolicLink(link.toPath(), original.toPath()) }
        catch (error: Exception) {
            System.err.println("SYMLINK_FIXTURE_UNAVAILABLE: " + error.javaClass.simpleName)
            assumeNoException(error)
        }
        assertNull(MediaImportFiles.readableMediaStoreHint(
            "com.android.providers.media.documents", "video:42", link.path, primary, null,
        ))
    }

    @Test fun explicitMediaStoreVolumeCannotBorrowAnotherVolumesHint() {
        val primary = File(root, "primary").apply { mkdir() }
        val secondary = File(root, "A1B2-C3D4").apply { mkdir() }
        val original = File(secondary, "movie.mp4").apply { writeBytes(bytes) }
        assertEquals(original.canonicalPath, MediaImportFiles.readableMediaStoreHint(
            "media", "/A1B2-C3D4/video/media/42", original.path, primary, secondary,
        ))
        assertNull(MediaImportFiles.readableMediaStoreHint(
            "media", "/DEAD-BEEF/video/media/42", original.path, primary, secondary,
        ))
        assertNull(MediaImportFiles.readableMediaStoreHint(
            "media", "/external_primary/video/media/42", original.path, primary, secondary,
        ))
        assertArrayEquals(bytes, original.readBytes())
    }
}
