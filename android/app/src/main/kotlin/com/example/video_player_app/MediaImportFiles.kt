package com.example.video_player_app

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.UUID

/** Ownership applies only to copies made for this selection, never originals. */
internal data class ImportableMediaFile(
    val file: File,
    val ownedCopy: Boolean,
    val sourcePathHint: String? = null,
) {
    fun discardCopy() {
        if (!ownedCopy) return
        file.delete()
        // Each copy owns a unique directory containing no other selection.
        file.parentFile?.delete()
    }
}

internal object MediaImportFiles {
    fun readablePath(candidate: String?): String? =
        candidate?.let(::File)?.takeIf { it.isFile && it.canRead() }?.absolutePath

    fun resolve(candidate: String?, copy: () -> File): ImportableMediaFile {
        val direct = readablePath(candidate)
        return if (direct != null) ImportableMediaFile(File(direct), false)
        else ImportableMediaFile(copy(), true)
    }

    fun resolveUri(
        sourceScheme: String?,
        directPath: () -> String?,
        sourcePathHint: () -> String? = { null },
        copy: () -> File,
    ): ImportableMediaFile {
        if (!sourceScheme.equals("content", ignoreCase = true)) return resolve(directPath(), copy)
        // A URI grant authorizes the provider stream, not a separately resolved
        // filesystem path. Always finish the owned copy before exposing a hint.
        val staged = copy()
        val hint = try { readablePath(sourcePathHint()) } catch (_: Exception) { null }
        return ImportableMediaFile(staged, true, hint)
    }

    /** Only known local document mappings may supply an optional sidecar hint. */
    fun readableExternalDocumentHint(
        authority: String?,
        documentId: String?,
        primaryRoot: File,
        secondaryRoot: File?,
    ): String? {
        if (authority != "com.android.externalstorage.documents" || documentId == null) return null
        val separator = documentId.indexOf(':')
        if (separator <= 0) return null
        val volume = documentId.substring(0, separator)
        val relative = documentId.substring(separator + 1)
        if (relative.isBlank() || relative.startsWith('/') || relative.contains('\\') ||
            relative.split('/').any { it == "." || it == ".." || it.isEmpty() }) return null
        val root = if (volume.equals("primary", ignoreCase = true)) primaryRoot else {
            // Reuse only the previously supported SECONDARY_STORAGE first root;
            // do not guess that an arbitrary document volume belongs to it.
            val validUuid = Regex("(?i)([0-9a-f]{4}-[0-9a-f]{4}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")
            secondaryRoot?.takeIf { validUuid.matches(volume) && it.name.equals(volume, ignoreCase = true) }
                ?: return null
        }
        return try {
            val canonicalRoot = root.canonicalFile
            val candidate = File(canonicalRoot, relative).absoluteFile.normalize()
            val canonical = candidate.canonicalFile
            if (canonical.path != candidate.path ||
                !canonical.path.startsWith(canonicalRoot.path + File.separator)) return null
            readablePath(canonical.path)
        } catch (_: Exception) { null }
    }

    fun isTrustedMediaStoreSource(authority: String?, sourceId: String?): Boolean =
        when (authority) {
            "com.android.providers.media.documents" -> sourceId?.matches(Regex("(video|audio):[0-9]+")) == true
            "media" -> sourceId?.matches(Regex("/(external|external_primary|[0-9a-fA-F]{4}-[0-9a-fA-F]{4}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/(video|audio)/media/[0-9]+")) == true
            else -> false
        }

    /** Official MediaStore mappings only; arbitrary provider _data is never a hint. */
    fun readableMediaStoreHint(
        authority: String?,
        sourceId: String?,
        candidate: String?,
        primaryRoot: File,
        secondaryRoot: File?,
    ): String? {
        if (!isTrustedMediaStoreSource(authority, sourceId) || candidate == null) return null
        return try {
            val file = File(candidate)
            if (!file.isAbsolute || file.path != file.absoluteFile.normalize().path) return null
            val canonical = file.canonicalFile
            if (canonical.path != file.absolutePath) return null
            val secondary = secondaryRoot?.takeIf {
                it.name.matches(Regex("(?i)([0-9a-f]{4}-[0-9a-f]{4}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"))
            }
            val mediaVolume = if (authority == "media") sourceId?.split('/')?.getOrNull(1) else null
            val roots = when {
                mediaVolume == "external_primary" -> listOf(primaryRoot)
                mediaVolume != null && mediaVolume != "external" ->
                    listOfNotNull(secondary?.takeIf { it.name.equals(mediaVolume, ignoreCase = true) })
                else -> listOfNotNull(primaryRoot, secondary)
            }
            if (roots.none { canonical.path.startsWith(it.canonicalPath + File.separator) }) return null
            readablePath(canonical.path)
        } catch (_: Exception) { null }
    }

    fun <T> resolveSelection(items: List<T>, resolve: (T) -> ImportableMediaFile?): List<String> {
        return resolveSelectionFiles(items, resolve).map { it.file.absolutePath }
    }

    fun <T> resolveSelectionPayload(
        items: List<T>,
        includeSourceHints: Boolean,
        resolve: (T) -> ImportableMediaFile?,
    ): Any {
        val files = resolveSelectionFiles(items, resolve)
        val paths = files.map { it.file.absolutePath }
        if (!includeSourceHints) return paths
        val hints = files.filter { it.ownedCopy && it.sourcePathHint != null }
            .associate { it.file.absolutePath to requireNotNull(it.sourcePathHint) }
        return mapOf("paths" to paths, "sourcePathHints" to hints)
    }

    private fun <T> resolveSelectionFiles(items: List<T>, resolve: (T) -> ImportableMediaFile?): List<ImportableMediaFile> {
        val files = mutableListOf<ImportableMediaFile>()
        try {
            for (item in items) {
                files.add(resolve(item) ?: throw IOException("无法读取所选媒体，请重新选择文件"))
            }
            return files
        } catch (error: Exception) {
            files.forEach { it.discardCopy() }
            throw error
        }
    }

    /** Publish only a fully copied file; providers need not expose a raw path. */
    fun copyToCache(cache: File, fileName: String, expectedSize: Long?, open: () -> InputStream?): File {
        require(fileName.isNotBlank() && File(fileName).name == fileName && fileName != "." && fileName != "..")
        val directory = File(File(cache, "picked_media"), UUID.randomUUID().toString())
        if (!directory.mkdirs()) throw IOException("无法创建媒体临时目录")
        val output = File(directory, fileName)
        val partial = File(directory, ".import.partial")
        try {
            val size = (open() ?: throw IOException("无法读取所选媒体内容")).use { input ->
                FileOutputStream(partial).use { destination ->
                    val copied = input.copyTo(destination, bufferSize = 1024 * 1024)
                    destination.fd.sync()
                    copied
                }
            }
            if (size <= 0L || (expectedSize != null && expectedSize >= 0L && size != expectedSize)) {
                throw IOException("所选媒体内容不完整，请重新选择文件")
            }
            if (!partial.renameTo(output)) throw IOException("无法保存媒体临时副本")
            return output
        } catch (error: Exception) {
            partial.delete()
            output.delete()
            directory.delete()
            throw error
        }
    }
}
