package com.example.video_player_app

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.CancellationException

data class ModelImportFileRequest(
    val targetPath: String,
    val candidates: List<String>,
    val expectedBytes: Long,
)

data class ModelImportSource(val expectedBytes: Long?, val open: () -> InputStream?)

data class ModelImportStage(val directory: File, val token: String)

/** Copies only the requested catalog files; provider originals are never modified. */
object ModelImportStaging {
    private const val ROOT_NAME = "offline_model_imports"
    private const val BUFFER_BYTES = 1024 * 1024
    private val tokenPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

    /** Validate the complete request before creating directories or contacting a provider. */
    fun validateRequests(requests: List<ModelImportFileRequest>) {
        require(requests.isNotEmpty() && requests.size <= 128) { "模型文件数量无效" }
        val targets = HashSet<File>()
        var candidateCount = 0
        for (request in requests) {
            validateRelativePath(request.targetPath)
            require(request.expectedBytes > 0) { "模型文件大小无效" }
            require(request.candidates.isNotEmpty() && request.candidates.size <= 32) {
                "模型候选文件数量无效"
            }
            candidateCount += request.candidates.size
            require(candidateCount <= 128) { "模型候选文件总数无效" }
            request.candidates.forEach(::validateRelativePath)
            require(targets.add(File(request.targetPath))) { "模型目标文件重复" }
        }
        for (target in targets) {
            var ancestor = target.parentFile
            while (ancestor != null) {
                require(ancestor !in targets) { "模型目标文件与目录冲突" }
                ancestor = ancestor.parentFile
            }
        }
    }

    fun stage(
        cache: File,
        requests: List<ModelImportFileRequest>,
        isCancelled: () -> Boolean = { false },
        resolve: (String) -> ModelImportSource?,
    ): ModelImportStage {
        // Provider callbacks must not be able to change a request after validation.
        validateRequests(requests)
        val files = requests.map { it.copy(candidates = it.candidates.toList()) }
        validateRequests(files)
        checkCancellation(isCancelled)
        val root = importRoot(cache)
        if (!root.isDirectory && !root.mkdirs()) throw IOException("无法创建模型暂存目录")
        val token = UUID.randomUUID().toString()
        val directory = File(root, token)
        if (!directory.mkdir()) throw IOException("无法创建模型导入目录")
        try {
            val buffer = ByteArray(BUFFER_BYTES)
            for (request in files) {
                checkCancellation(isCancelled)
                val output = File(directory, request.targetPath)
                val parent = requireNotNull(output.parentFile)
                if (!parent.isDirectory && !parent.mkdirs()) throw IOException("无法创建模型文件目录")
                var copied = false
                var lastError: Exception? = null
                for (candidate in request.candidates) {
                    checkCancellation(isCancelled)
                    try {
                        val source = resolve(candidate) ?: continue
                        val knownSize = source.expectedBytes
                        if (knownSize != null && knownSize >= 0 && knownSize != request.expectedBytes) {
                            throw IOException("模型候选文件大小不匹配：$candidate")
                        }
                        copyFile(source, output, request.expectedBytes, buffer, isCancelled)
                        copied = true
                        break
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: IOException) {
                        lastError = error
                    } catch (error: SecurityException) {
                        lastError = error
                    }
                }
                if (!copied) throw IOException("无法读取完整模型文件：${request.targetPath}", lastError)
            }
            checkCancellation(isCancelled)
            return ModelImportStage(directory, token)
        } catch (error: Throwable) {
            if (!cleanup(cache, token)) error.addSuppressed(IOException("模型导入暂存清理失败"))
            throw error
        }
    }

    /** A token can name only one direct child owned by this import mechanism. */
    fun cleanup(cache: File, token: String): Boolean {
        if (!tokenPattern.matches(token)) return false
        return try {
            val directory = File(importRoot(cache), token)
            if (directory.canonicalFile != directory.absoluteFile) return false
            deleteOwnedTree(directory)
        } catch (_: IOException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    private fun validateRelativePath(path: String) {
        require(path.isNotEmpty() && path.toByteArray(Charsets.UTF_8).size <= 4096) { "模型相对路径无效" }
        require(!File(path).isAbsolute && !path.startsWith('/') && '\\' !in path && '\u0000' !in path && ':' !in path) {
            "模型路径必须为相对路径"
        }
        val segments = path.split('/')
        require(segments.size <= 32 && segments.all {
            it.isNotEmpty() && it != "." && it != ".." && it.toByteArray(Charsets.UTF_8).size <= 255
        }) { "模型路径包含无效目录段" }
    }

    private fun importRoot(cache: File): File {
        val root = File(cache.canonicalFile, ROOT_NAME)
        // An existing link must not redirect staging or cleanup outside the app cache.
        if (root.canonicalFile != root.absoluteFile) throw IOException("模型暂存根目录不能是链接")
        return root
    }

    private fun copyFile(
        source: ModelImportSource,
        output: File,
        expectedBytes: Long,
        buffer: ByteArray,
        isCancelled: () -> Boolean,
    ) {
        var partial: File? = null
        try {
            (source.open() ?: throw IOException("无法打开模型候选文件")).use { input ->
                checkCancellation(isCancelled)
                val temporary = File.createTempFile(".model-import-", ".part", output.parentFile)
                partial = temporary
                FileOutputStream(temporary).use { destination ->
                    var copied = 0L
                    while (true) {
                        checkCancellation(isCancelled)
                        val remaining = expectedBytes - copied
                        // Read at most one extra byte, detecting oversized/unbounded streams.
                        val limit = if (remaining >= buffer.size) buffer.size else remaining.toInt() + 1
                        val count = input.read(buffer, 0, limit)
                        checkCancellation(isCancelled)
                        if (count < 0) break
                        if (count == 0) {
                            val byte = input.read()
                            checkCancellation(isCancelled)
                            if (byte < 0) break
                            if (copied == expectedBytes) throw IOException("模型文件超过清单大小")
                            destination.write(byte)
                            copied += 1
                        } else {
                            if (count.toLong() > remaining) throw IOException("模型文件超过清单大小")
                            destination.write(buffer, 0, count)
                            copied += count
                        }
                    }
                    if (copied != expectedBytes) throw IOException("模型文件不完整")
                    destination.fd.sync()
                }
            }
            checkCancellation(isCancelled)
            if (output.exists() || !requireNotNull(partial).renameTo(output)) {
                throw IOException("无法保存完整模型文件")
            }
        } finally {
            partial?.delete()
        }
    }

    private fun checkCancellation(isCancelled: () -> Boolean) {
        if (isCancelled()) throw CancellationException("模型导入已取消")
    }

    private fun deleteOwnedTree(file: File): Boolean {
        var deletedChildren = true
        // Never descend through a link, including one placed inside this owned directory.
        if (file.canonicalFile == file.absoluteFile && file.isDirectory) {
            val children = file.listFiles() ?: return false
            for (child in children) deletedChildren = deleteOwnedTree(child) && deletedChildren
        }
        val removed = file.delete() || !hasDirectoryEntry(file)
        return removed && deletedChildren
    }

    private fun hasDirectoryEntry(file: File): Boolean {
        val parent = file.parentFile ?: return file.exists()
        val names = parent.list()
        return names?.any { it == file.name } ?: parent.exists()
    }
}
