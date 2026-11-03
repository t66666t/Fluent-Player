import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../services/media_materialization_service.dart';
import '../media_cache/media_cache_service.dart';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/media_chapter.dart';
import '../../services/library_service.dart';
import '../../utils/ffmpeg_utils.dart';
import 'portable_transfer_models.dart';
import 'zip_export_plan.dart';

const zipExportScratchDirectoryName = 'fluent_zip_export';

class ZipExportResult {
  final int mediaCount;
  final int skippedOnline;
  final int skippedMissing;
  final int sidecarFallbacks;
  final int keptOriginals;
  final int droppedExtras;
  final int referenceCount;
  final int missingSidecars;

  const ZipExportResult({
    required this.mediaCount,
    required this.skippedOnline,
    required this.skippedMissing,
    required this.sidecarFallbacks,
    required this.keptOriginals,
    required this.droppedExtras,
    this.referenceCount = 0,
    this.missingSidecars = 0,
  });

  String summary(int outputBytes) => buildZipExportSummary(
    mediaCount: mediaCount,
    outputBytes: outputBytes,
    skippedOnline: skippedOnline,
    skippedMissing: skippedMissing,
    sidecarFallbacks: sidecarFallbacks,
    keptOriginals: keptOriginals,
    droppedExtras: droppedExtras,
    referenceCount: referenceCount,
    missingSidecars: missingSidecars,
  );
}

typedef ZipProgressCallback =
    void Function(
      double progress,
      String subtitle,
      int processedBytes,
      int totalBytes,
    );

class ZipExportHandle {
  void Function()? cancelSession;
  Process? ffmpeg;
  int? ffmpegKitSessionId;
  bool _cancelled = false;
  String? _outputKey;
  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    cancelSession?.call();
    ffmpeg?.kill();
    final sessionId = ffmpegKitSessionId;
    if (sessionId != null) {
      unawaited(FFmpegKit.cancel(sessionId));
    }
  }
}

class ZipExportRuntime {
  static final Map<String, ZipExportHandle> _handles =
      <String, ZipExportHandle>{};
  static final Map<String, ZipExportHandle> _outputs =
      <String, ZipExportHandle>{};

  static String _outputKey(String path) {
    final absolute = p.normalize(p.absolute(path));
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  static bool isOutputBusy(String partialPath) =>
      _outputs.containsKey(_outputKey(partialPath));

  static void bind(String taskId, ZipExportHandle handle, String partialPath) {
    final output = _outputKey(partialPath);
    if (_handles.containsKey(taskId) || _outputs.containsKey(output)) {
      throw StateError('上次 Zip 写入仍在停止，临时文件已保留，请等待退出后重试');
    }
    handle._outputKey = output;
    _handles[taskId] = handle;
    _outputs[output] = handle;
  }

  static void unbind(String taskId, ZipExportHandle handle) {
    if (identical(_handles[taskId], handle)) {
      _handles.remove(taskId);
    }
    final output = handle._outputKey;
    if (output != null && identical(_outputs[output], handle)) {
      _outputs.remove(output);
    }
  }

  static void cancel(String taskId) {
    _handles[taskId]?.cancel();
  }
}

class ZipMediaExporter {
  const ZipMediaExporter()
    : _probeFactsForTesting = null,
      _onPackStartedForTesting = null,
      _workerDelayBeforeAddForTesting = null;

  @visibleForTesting
  const ZipMediaExporter.forTesting({
    Future<ZipSourceFacts> Function(String path)? probeFacts,
    void Function()? onPackStarted,
    Duration? workerDelayBeforeAdd,
  }) : _probeFactsForTesting = probeFacts,
       _onPackStartedForTesting = onPackStarted,
       _workerDelayBeforeAddForTesting = workerDelayBeforeAdd;

  final Future<ZipSourceFacts> Function(String path)? _probeFactsForTesting;
  final void Function()? _onPackStartedForTesting;
  final Duration? _workerDelayBeforeAddForTesting;

  Future<ZipExportResult> run({
    required LibraryService library,
    required List<String> rootIds,
    required String partialPath,
    required PortableExportOptions options,
    required String taskId,
    required bool Function() isCancelled,
    required ZipProgressCallback onProgress,
  }) async {
    final handle = ZipExportHandle();
    ZipExportRuntime.bind(taskId, handle, partialPath);
    bool cancelled() => isCancelled() || handle.isCancelled;
    final cancellationWatch = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (isCancelled() && !handle.isCancelled) handle.cancel();
      },
    );
    Directory? scratch;
    _ZipPackSession? session;
    final retainedLeases = <MaterializedMediaLease>[];
    var finished = false;
    var cleanupDeferred = false;
    try {
      _throwIfCancelled(cancelled);
      final draft = enumerateZipCandidates(library: library, rootIds: rootIds);
      if (draft.candidates.isEmpty && draft.references.isEmpty) {
        throw StateError('所选项目中没有可导出的本地文件');
      }
      for (final candidate in draft.candidates) {
        final variant = candidate.cachedVariant;
        if (variant == null) continue;
        final lease = await MediaCacheService.instance?.acquireVariant(
          variant,
          candidate.item,
        );
        if (lease == null) throw StateError('所选缓存已不可用，请重试导出');
        retainedLeases.add(lease);
        _throwIfCancelled(cancelled);
      }
      onProgress(0.01, '正在读取 ${draft.candidates.length} 个媒体', 0, 1);
      final facts = await _probeAll(
        draft.candidates,
        options: options,
        isCancelled: cancelled,
        onProgress: onProgress,
      );
      _throwIfCancelled(cancelled);
      final media = <ZipResolvedMedia>[
        for (final candidate in draft.candidates)
          resolveZipCandidate(
            candidate: candidate,
            names: draft.names,
            embedSubtitles: options.zipEmbedSubtitles,
            externalSubtitles: options.zipExternalSubtitles,
            includeDanmaku: options.includeDanmaku,
            facts:
                facts[candidate.item.id] ??
                (zipCandidateNeedsProbe(
                      item: candidate.item,
                      embedTracks: zipEmbedTracks(
                        associated: collectAssociatedSubtitles(candidate.item),
                        danmaku: collectDanmakuTrack(candidate.item),
                        embedSubtitles: options.zipEmbedSubtitles,
                        externalSubtitles: options.zipExternalSubtitles,
                        includeDanmaku: options.includeDanmaku,
                      ),
                    )
                    ? const ZipSourceFacts.unknown()
                    : const ZipSourceFacts()),
          ),
      ];
      final totalBytes =
          media.fold<int>(0, (sum, item) => sum + item.sourceBytes) +
          draft.references.fold<int>(
            0,
            (sum, reference) => sum + utf8.encode(reference.contents).length,
          );
      final temp = await getTemporaryDirectory();
      _throwIfCancelled(cancelled);
      scratch = Directory(
        p.join(temp.path, zipExportScratchDirectoryName, taskId),
      );
      if (await scratch.exists()) {
        await _deleteTree(scratch);
      }
      _throwIfCancelled(cancelled);
      await scratch.create(recursive: true);
      _throwIfCancelled(cancelled);
      final partial = File(partialPath);
      if (await partial.exists()) await _deleteFile(partial);
      await partial.parent.create(recursive: true);
      _throwIfCancelled(cancelled);

      session = _ZipPackSession(
        handle,
        File(p.join(scratch.path, '.zip-cancel')),
        delayBeforeAdd: _workerDelayBeforeAddForTesting,
      );
      _onPackStartedForTesting?.call();
      _throwIfCancelled(cancelled);
      await session.start(
        partialPath: partialPath,
        level: _zipLevel(options.compression),
      );
      var packedBytes = 0;
      var sidecarFallbacks = 0;
      var keptOriginals = 0;
      var droppedExtras = 0;
      for (var index = 0; index < media.length; index++) {
        _throwIfCancelled(cancelled);
        final item = media[index];
        final prepared = await _prepareItem(
          item: item,
          index: index,
          total: media.length,
          scratch: scratch,
          names: draft.names,
          handle: handle,
          isCancelled: cancelled,
          onProgress: (fraction, subtitle) {
            final inFile = (item.sourceBytes * fraction).round();
            onProgress(
              totalBytes == 0
                  ? (index + fraction) / media.length
                  : ((packedBytes + inFile) / totalBytes).clamp(0.0, 0.99),
              subtitle,
              packedBytes + inFile,
              totalBytes,
            );
          },
        );
        if (prepared.usedSidecarFallback) sidecarFallbacks++;
        if (prepared.keptOriginal) keptOriginals++;
        if (prepared.droppedExtras) droppedExtras++;
        final members = prepared.members;
        for (final member in members) {
          _throwIfCancelled(cancelled);
          final before = packedBytes;
          final fileLength = await File(member.sourcePath).length();
          _throwIfCancelled(cancelled);
          onProgress(
            totalBytes == 0 ? index / media.length : before / totalBytes,
            '正在打包 ${index + 1}/${media.length} · ${item.title}',
            before,
            totalBytes,
          );
          await session.add(
            sourcePath: member.sourcePath,
            archivePath: member.archivePath,
            level: _zipLevel(options.compression),
            onBytes: (written) {
              final grown = written > fileLength ? fileLength : written;
              onProgress(
                totalBytes == 0
                    ? (index + 1) / media.length
                    : ((before + grown) / totalBytes).clamp(0.0, 0.99),
                '正在打包 ${index + 1}/${media.length} · ${item.title}',
                before + grown,
                totalBytes,
              );
            },
            partialPath: partialPath,
          );
          if (member.deleteAfterPack) {
            await _deleteIfInside(scratch, member.sourcePath);
          }
        }
        packedBytes += item.sourceBytes;
        onProgress(
          totalBytes == 0
              ? (index + 1) / media.length
              : (packedBytes / totalBytes).clamp(0.0, 0.99),
          '正在打包 ${index + 1}/${media.length} · ${item.title}',
          packedBytes,
          totalBytes,
        );
      }
      for (var index = 0; index < draft.references.length; index++) {
        _throwIfCancelled(cancelled);
        final reference = draft.references[index];
        final file = File(p.join(scratch.path, 'reference_$index.txt'));
        await file.writeAsString(reference.contents, flush: true);
        _throwIfCancelled(cancelled);
        onProgress(0.99, '正在打包播客卡片引用', packedBytes, totalBytes);
        await session.add(
          sourcePath: file.path,
          archivePath: reference.archivePath,
          level: _zipLevel(options.compression),
          onBytes: (_) {},
          partialPath: partialPath,
        );
        packedBytes += await file.length();
      }
      _throwIfCancelled(cancelled);
      await session.finish();
      _throwIfCancelled(cancelled);
      finished = true;
      return ZipExportResult(
        mediaCount: media.length,
        skippedOnline: draft.skippedOnline,
        skippedMissing: draft.skippedMissing,
        sidecarFallbacks: sidecarFallbacks,
        keptOriginals: keptOriginals,
        droppedExtras: droppedExtras,
        referenceCount: draft.referenceCount,
        missingSidecars: media.fold<int>(
          0,
          (sum, item) => sum + item.missingSidecars,
        ),
      );
    } on PortableExportCancelled {
      rethrow;
    } finally {
      Future<void> cleanup() async {
        for (final lease in retainedLeases) {
          try {
            await lease.release();
          } catch (_) {
            // Release unpins first; a pending-delete storage error must not
            // strand the other leases or overwrite the actual export result.
          }
        }
        final work = scratch;
        if (work != null) {
          final parent = work.parent;
          await _deleteTree(work);
          try {
            if (await parent.exists() &&
                await parent.list(followLinks: false).isEmpty) {
              await parent.delete();
            }
          } catch (_) {}
        }
        if (!finished) {
          final partial = File(partialPath);
          await _deleteFile(partial);
        }
      }

      try {
        // A cancellation signal is not a file-close acknowledgement. Keep the
        // marker, leased sources and scratch alive until the worker exits.
        try {
          handle.cancel();
        } catch (_) {}
        final stopped = await session?.close() ?? true;
        if (!stopped) {
          finished = false;
          cleanupDeferred = true;
          unawaited(
            session!.exited
                .then((_) => cleanup())
                .catchError((Object error) {
                  debugPrint('ZIP deferred cleanup failed: $error');
                })
                .whenComplete(() => ZipExportRuntime.unbind(taskId, handle)),
          );
          throw StateError('Zip 写入进程尚未退出，临时文件已保留，退出后会继续清理');
        }
        await cleanup();
      } finally {
        cancellationWatch.cancel();
        if (!cleanupDeferred) ZipExportRuntime.unbind(taskId, handle);
      }
    }
  }

  Future<Map<String, ZipSourceFacts>> _probeAll(
    List<ZipCandidate> candidates, {
    required PortableExportOptions options,
    required bool Function() isCancelled,
    required ZipProgressCallback onProgress,
  }) async {
    final facts = <String, ZipSourceFacts>{};
    for (var index = 0; index < candidates.length; index++) {
      _throwIfCancelled(isCancelled);
      final item = candidates[index].item;
      final embedTracks = zipEmbedTracks(
        associated: collectAssociatedSubtitles(item),
        danmaku: collectDanmakuTrack(item),
        embedSubtitles: options.zipEmbedSubtitles,
        externalSubtitles: options.zipExternalSubtitles,
        includeDanmaku: options.includeDanmaku,
      );
      if (!zipCandidateNeedsProbe(item: item, embedTracks: embedTracks)) {
        continue;
      }
      onProgress(0.02, '正在读取媒体信息 ${index + 1}/${candidates.length}', 0, 1);
      facts[item.id] = await _probeFacts(candidates[index].sourcePath);
      _throwIfCancelled(isCancelled);
    }
    return facts;
  }

  Future<_PreparedZipItem> _prepareItem({
    required ZipResolvedMedia item,
    required int index,
    required int total,
    required Directory scratch,
    required ZipNameAllocator names,
    required ZipExportHandle handle,
    required bool Function() isCancelled,
    required void Function(double fraction, String subtitle) onProgress,
  }) async {
    if (!item.remux) {
      return _PreparedZipItem(
        members: <_ZipMember>[
          _ZipMember(item.sourcePath, item.archivePath, deleteAfterPack: false),
          for (final sidecar in item.sidecars)
            _ZipMember(
              sidecar.sourcePath,
              sidecar.archivePath,
              deleteAfterPack: false,
            ),
        ],
      );
    }

    final full = ZipRemuxPlan(
      tracks: item.embedTracks,
      includeCover: item.coverPath != null,
      includeChapters: item.replacementChapters != null,
    );
    var failures = 0;
    while (true) {
      _throwIfCancelled(isCancelled);
      final attempt = zipRemuxAttemptAfterFailures(full, failures);
      if (attempt == null) break;
      final output = File(
        p.join(
          scratch.path,
          '${index}_$failures${p.extension(item.archivePath)}',
        ),
      );
      try {
        await _remux(
          item: item,
          plan: attempt,
          output: output,
          scratch: scratch,
          handle: handle,
          isCancelled: isCancelled,
          onProgress: (fraction) {
            onProgress(
              fraction * 0.85,
              '正在封装 ${index + 1}/$total · ${item.title}',
            );
          },
        );
        final degraded = failures >= 2;
        return _PreparedZipItem(
          droppedExtras: degraded,
          members: <_ZipMember>[
            _ZipMember(output.path, item.archivePath, deleteAfterPack: true),
            for (final sidecar in item.sidecars)
              _ZipMember(
                sidecar.sourcePath,
                sidecar.archivePath,
                deleteAfterPack: false,
              ),
          ],
        );
      } catch (error) {
        await _deleteIfInside(scratch, output.path);
        await _deleteIfInside(scratch, zipInProgressRemuxPath(output.path));
        if (error is PortableExportCancelled) rethrow;
        failures++;
      }
    }

    final archivePath = reallocateZipCopyPath(media: item, names: names);
    final sidecars = item.sidecars.isNotEmpty
        ? item.sidecars
        : buildZipFallbackSidecars(
            media: item,
            videoArchivePath: archivePath,
            names: names,
          );
    return _PreparedZipItem(
      usedSidecarFallback: item.embedTracks.isNotEmpty,
      keptOriginal: item.embedTracks.isEmpty,
      droppedExtras: full.hasExtras,
      members: <_ZipMember>[
        _ZipMember(item.sourcePath, archivePath, deleteAfterPack: false),
        for (final sidecar in sidecars)
          _ZipMember(
            sidecar.sourcePath,
            sidecar.archivePath,
            deleteAfterPack: false,
          ),
      ],
    );
  }

  Future<void> _remux({
    required ZipResolvedMedia item,
    required ZipRemuxPlan plan,
    required File output,
    required Directory scratch,
    required ZipExportHandle handle,
    required bool Function() isCancelled,
    required void Function(double fraction) onProgress,
  }) async {
    String? chapterPath;
    if (plan.includeChapters && item.replacementChapters != null) {
      final file = File(
        p.join(scratch.path, '${p.basename(output.path)}.ffmeta'),
      );
      await file.writeAsString(
        buildZipChapterMetadata(
          item.replacementChapters!,
          durationMs: item.durationMs,
        ),
      );
      chapterPath = file.path;
    }
    // Container suffix must stay last; see [zipInProgressRemuxPath].
    final partial = File(zipInProgressRemuxPath(output.path));
    await _deleteIfInside(scratch, partial.path);
    final args = buildZipRemuxArguments(
      sourcePath: item.sourcePath,
      outputPath: partial.path,
      tracks: plan.tracks,
      coverPath: plan.includeCover ? item.coverPath : null,
      chapterMetadataPath: chapterPath,
      existingSubtitleStreams: item.existingSubtitleStreams,
      existingSubtitleCodecs: item.existingSubtitleCodecs,
      existingVideoStreams: item.existingVideoStreams,
      outputIsMp4Family: item.outputIsMp4Family,
      progressPipe: _useCli,
    );
    if (_useCli) {
      await _remuxWithCli(
        args: args,
        handle: handle,
        durationMs: item.durationMs,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    } else {
      await _remuxWithKit(
        args: args,
        handle: handle,
        durationMs: item.durationMs,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );
    }
    _throwIfCancelled(isCancelled);
    if (!await partial.exists() || await partial.length() <= 0) {
      throw StateError('封装没有产生文件');
    }
    if (await output.exists()) await output.delete();
    await partial.rename(output.path);
  }

  Future<void> _remuxWithCli({
    required List<String> args,
    required ZipExportHandle handle,
    required int durationMs,
    required bool Function() isCancelled,
    required void Function(double fraction) onProgress,
  }) async {
    final ffmpeg = await FFmpegUtils.ffmpegPath;
    _throwIfCancelled(isCancelled);
    final process = await Process.start(ffmpeg, args);
    handle.ffmpeg = process;
    if (isCancelled()) handle.cancel();
    final stderr = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderr.write);
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final fraction = zipFfmpegProgressFraction(line, durationMs);
          if (fraction != null) onProgress(fraction);
        });
    final code = await process.exitCode;
    await stderrDone.cancel();
    await stdoutDone.cancel();
    handle.ffmpeg = null;
    if (isCancelled()) throw const PortableExportCancelled();
    if (code != 0) {
      final text = stderr.toString().trim();
      final line = text.isEmpty ? '退出码 $code' : text.split('\n').last.trim();
      throw StateError(line);
    }
  }

  Future<void> _remuxWithKit({
    required List<String> args,
    required ZipExportHandle handle,
    required int durationMs,
    required bool Function() isCancelled,
    required void Function(double fraction) onProgress,
  }) async {
    final completed = Completer<FFmpegSession>();
    final session = await FFmpegKit.executeWithArgumentsAsync(
      args,
      (finished) {
        if (!completed.isCompleted) completed.complete(finished);
      },
      null,
      (statistics) {
        if (durationMs <= 0) return;
        onProgress((statistics.getTime() / durationMs).clamp(0.0, 0.99));
      },
    );
    handle.ffmpegKitSessionId = session.getSessionId();
    if (isCancelled()) handle.cancel();
    final finished = await completed.future;
    handle.ffmpegKitSessionId = null;
    if (isCancelled()) throw const PortableExportCancelled();
    final code = await finished.getReturnCode();
    if (!ReturnCode.isSuccess(code)) {
      final logs = await finished.getAllLogsAsString();
      final text = (logs ?? '').trim();
      throw StateError(text.isEmpty ? '封装失败' : text.split('\n').last.trim());
    }
  }

  Future<ZipSourceFacts> _probeFacts(String path) async {
    final override = _probeFactsForTesting;
    if (override != null) return override(path);
    try {
      if (_useCli) return await _probeWithCli(path);
      return await _probeWithKit(path);
    } catch (_) {
      return const ZipSourceFacts.unknown();
    }
  }

  Future<ZipSourceFacts> _probeWithCli(String path) async {
    final ffprobe = await FFmpegUtils.ffprobePath;
    final result = await Process.run(
      ffprobe,
      <String>[
        '-v',
        'error',
        '-show_streams',
        '-show_chapters',
        '-of',
        'json',
        path,
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 20));
    if (result.exitCode != 0) return const ZipSourceFacts.unknown();
    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! Map) return const ZipSourceFacts.unknown();
    return _factsFromProbeJson(Map<String, dynamic>.from(decoded));
  }

  Future<ZipSourceFacts> _probeWithKit(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final information = session.getMediaInformation();
    if (information == null) return const ZipSourceFacts.unknown();
    final streams = information.getStreams();
    var videos = 0;
    var subtitles = 0;
    final subtitleCodecs = <String>[];
    var cover = false;
    for (final stream in streams) {
      final type = stream.getType();
      if (type == 'video') videos++;
      if (type == 'subtitle') {
        subtitles++;
        subtitleCodecs.add(stream.getCodec() ?? '');
      }
      final disposition = stream.getProperty('disposition');
      if (disposition is Map && _isTruthy(disposition['attached_pic'])) {
        cover = true;
      }
    }
    final chapters = information
        .getChapters()
        .map((chapter) {
          final tags = chapter.getTags();
          return MediaChapter(
            title: (tags?['title'] ?? tags?['TITLE'] ?? '').toString().trim(),
            startMs: _secondsToMs(chapter.getStartTime()),
            endMs: _secondsToMs(chapter.getEndTime()),
          );
        })
        .toList(growable: false);
    return ZipSourceFacts(
      hasAttachedCover: cover,
      videoStreamCount: videos,
      subtitleStreamCount: subtitles,
      subtitleCodecs: subtitleCodecs,
      fileChapters: chapters,
    );
  }
}

bool get _useCli => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

ZipSourceFacts _factsFromProbeJson(Map<String, dynamic> json) {
  final streams = json['streams'];
  var videos = 0;
  var subtitles = 0;
  final subtitleCodecs = <String>[];
  var cover = false;
  if (streams is List) {
    for (final raw in streams.whereType<Map>()) {
      final stream = Map<String, dynamic>.from(raw);
      final type = stream['codec_type']?.toString();
      if (type == 'video') videos++;
      if (type == 'subtitle') {
        subtitles++;
        subtitleCodecs.add(stream['codec_name']?.toString() ?? '');
      }
      final disposition = stream['disposition'];
      if (disposition is Map && _isTruthy(disposition['attached_pic'])) {
        cover = true;
      }
    }
  }
  final chapters = <MediaChapter>[];
  final rawChapters = json['chapters'];
  if (rawChapters is List) {
    for (final raw in rawChapters.whereType<Map>()) {
      final chapter = Map<String, dynamic>.from(raw);
      final tags = chapter['tags'] is Map
          ? Map<String, dynamic>.from(chapter['tags'] as Map)
          : const <String, dynamic>{};
      chapters.add(
        MediaChapter(
          title: (tags['title'] ?? tags['TITLE'] ?? '').toString().trim(),
          startMs: _secondsToMs(chapter['start_time']),
          endMs: _secondsToMs(chapter['end_time']),
        ),
      );
    }
  }
  return ZipSourceFacts(
    hasAttachedCover: cover,
    videoStreamCount: videos,
    subtitleStreamCount: subtitles,
    subtitleCodecs: subtitleCodecs,
    fileChapters: chapters,
  );
}

int _secondsToMs(Object? value) {
  final seconds = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  return seconds == null ? 0 : (seconds * 1000).round();
}

bool _isTruthy(Object? value) => value == 1 || value == true || value == '1';

int _zipLevel(PortableCompression compression) => switch (compression) {
  PortableCompression.fast => ZipFileEncoder.store,
  PortableCompression.balanced => 3,
  PortableCompression.smallest => 9,
};

void _throwIfCancelled(bool Function() isCancelled) {
  if (isCancelled()) throw const PortableExportCancelled();
}

Future<void> _deleteIfInside(Directory scratch, String path) async {
  final file = File(path);
  if (!p.isWithin(scratch.path, file.path)) return;
  await _deleteFile(file);
}

Future<void> _deleteFile(File file) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await file.exists()) await file.delete();
      return;
    } catch (_) {
      await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
    }
  }
}

Future<void> _deleteTree(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } catch (_) {
      await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
    }
  }
}

class _PreparedZipItem {
  final List<_ZipMember> members;
  final bool usedSidecarFallback;
  final bool keptOriginal;
  final bool droppedExtras;

  const _PreparedZipItem({
    required this.members,
    this.usedSidecarFallback = false,
    this.keptOriginal = false,
    this.droppedExtras = false,
  });
}

class _ZipMember {
  final String sourcePath;
  final String archivePath;
  final bool deleteAfterPack;

  const _ZipMember(
    this.sourcePath,
    this.archivePath, {
    required this.deleteAfterPack,
  });
}

class _ZipPackSession {
  _ZipPackSession(this.handle, this.cancelMarker, {this.delayBeforeAdd}) {
    handle.cancelSession = cancel;
  }

  final ZipExportHandle handle;
  final File cancelMarker;
  final Duration? delayBeforeAdd;
  Isolate? _isolate;
  SendPort? _send;
  ReceivePort? _replies;
  ReceivePort? _errors;
  ReceivePort? _exits;
  final Completer<void> _exited = Completer<void>();
  Future<bool>? _closing;
  var _ticket = 0;
  final Map<int, Completer<void>> _waiters = <int, Completer<void>>{};
  var _cancelled = false;

  Future<void> start({required String partialPath, required int level}) async {
    if (_cancelled || handle.isCancelled) throw const PortableExportCancelled();
    final ready = ReceivePort();
    _replies = ReceivePort();
    _errors = ReceivePort();
    _exits = ReceivePort();
    _exits!.listen((_) {
      if (!_exited.isCompleted) _exited.complete();
      // Reply and exit use separate ports. Let an already-sent terminal reply
      // drain before treating remaining commands as unexpectedly abandoned.
      Timer.run(() {
        _failWaiters(
          _cancelled
              ? const PortableExportCancelled()
              : StateError('Zip 写入进程已退出'),
        );
      });
    });
    try {
      _isolate = await Isolate.spawn<SendPort>(
        _zipPackWorker,
        ready.sendPort,
        onError: _errors!.sendPort,
        onExit: _exits!.sendPort,
        errorsAreFatal: true,
        debugName: 'zip-export',
      );
      _send = await ready.first.timeout(const Duration(seconds: 5)) as SendPort;
      if (_cancelled) _send!.send(<String, dynamic>{'type': 'cancel'});
    } finally {
      ready.close();
    }
    _replies!.listen((dynamic raw) {
      if (raw is! Map) return;
      final message = Map<String, dynamic>.from(raw);
      final id = message['id'];
      if (id is! int) return;
      final waiter = _waiters.remove(id);
      if (waiter == null || waiter.isCompleted) return;
      if (message['ok'] == true) {
        waiter.complete();
      } else if (_cancelled) {
        waiter.completeError(const PortableExportCancelled());
      } else {
        waiter.completeError(
          StateError(message['error']?.toString() ?? '写入 Zip 失败'),
        );
      }
    });
    _errors!.listen((dynamic _) {
      if (_cancelled) {
        _failWaiters(const PortableExportCancelled());
      } else {
        _failWaiters(StateError('Zip 写入进程意外退出，请重试导出'));
      }
    });
    await _command(<String, dynamic>{
      'type': 'start',
      'path': partialPath,
      'level': level,
      'cancelPath': cancelMarker.path,
    });
  }

  Future<void> add({
    required String sourcePath,
    required String archivePath,
    required int level,
    required void Function(int written) onBytes,
    required String partialPath,
  }) async {
    final partial = File(partialPath);
    final baseline = await partial.exists() ? await partial.length() : 0;
    final timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!partial.existsSync()) return;
      final written = partial.lengthSync() - baseline;
      if (written > 0) onBytes(written);
    });
    try {
      await _command(<String, dynamic>{
        'type': 'add',
        'source': sourcePath,
        'archivePath': archivePath,
        'level': level,
        if (delayBeforeAdd != null)
          'delayBeforeAddMs': delayBeforeAdd!.inMilliseconds,
      });
    } finally {
      timer.cancel();
    }
  }

  Future<void> finish() => _command(<String, dynamic>{'type': 'finish'});

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // The encoder compresses synchronously. A SendPort cancel alone cannot run
    // until a multi-GB member completes; file-handle checkpoints observe this
    // private marker between bounded input/output blocks instead.
    try {
      cancelMarker.writeAsStringSync('cancel', flush: true);
    } catch (_) {}
    _send?.send(<String, dynamic>{'type': 'cancel'});
    _failWaiters(const PortableExportCancelled());
  }

  Future<void> get exited => _exited.future;

  Future<bool> close() => _closing ??= _close();

  Future<bool> _close() async {
    cancel();
    final isolate = _isolate;
    if (isolate == null) {
      if (!_exited.isCompleted) _exited.complete();
      _closePorts();
      return true;
    }
    try {
      await _exited.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // Never kill a descriptor-owning isolate: VM termination skips Dart
      // finally blocks. Resend the cooperative stop, then retain ownership if
      // an exceptional OS read/write still prevents exit.
      _send?.send(<String, dynamic>{'type': 'cancel'});
      try {
        await _exited.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Do not delete the signal/sources while an OS-blocked writer is still
        // alive. The owner defers cleanup to actual exit instead of waiting
        // indefinitely or claiming that files have already been released.
        unawaited(_exited.future.then((_) => _closePorts()));
        return false;
      }
    }
    _closePorts();
    return true;
  }

  void _closePorts() {
    _isolate = null;
    _replies?.close();
    _errors?.close();
    _exits?.close();
    _replies = null;
    _errors = null;
    _exits = null;
    handle.cancelSession = null;
  }

  Future<void> _command(Map<String, dynamic> body) {
    if (_cancelled) throw const PortableExportCancelled();
    final send = _send;
    final replies = _replies;
    if (send == null || replies == null) {
      throw StateError('Zip 写入尚未开始');
    }
    final id = _ticket++;
    final completer = Completer<void>();
    _waiters[id] = completer;
    send.send(<String, dynamic>{...body, 'id': id, 'reply': replies.sendPort});
    return completer.future;
  }

  void _failWaiters(Object error) {
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) waiter.completeError(error);
    }
    _waiters.clear();
  }
}

Future<void> _zipPackWorker(SendPort ready) async {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  ZipFileEncoder? encoder;
  PortableArchiveFileHandle? outputHandle;
  File? cancelMarker;
  try {
    await for (final raw in inbox) {
      if (raw is! Map) continue;
      final message = Map<String, dynamic>.from(raw);
      if (message['type'] == 'cancel') {
        inbox.close();
        return;
      }
      final reply = message['reply'] as SendPort;
      final id = message['id'];
      try {
        switch (message['type']) {
          case 'start':
            cancelMarker = File(message['cancelPath'] as String);
            _throwIfCancelled(cancelMarker.existsSync);
            outputHandle = PortableArchiveFileHandle(
              message['path'] as String,
              cancelMarker,
              mode: FileAccess.write,
            );
            encoder = ZipFileEncoder()
              ..createWithStream(
                OutputFileStream.withFileHandle(outputHandle),
                level: message['level'] as int? ?? ZipFileEncoder.store,
              );
            reply.send(<String, dynamic>{'id': id, 'ok': true});
          case 'add':
            final marker = cancelMarker!;
            final delay = message['delayBeforeAddMs'] as int? ?? 0;
            if (delay > 0) {
              await Future<void>.delayed(Duration(milliseconds: delay));
            }
            _throwIfCancelled(marker.existsSync);
            final source = File(message['source'] as String);
            if (!await source.exists()) {
              throw StateError('导出源文件已不存在：${source.path}');
            }
            final stat = await source.stat();
            _throwIfCancelled(marker.existsSync);
            final inputHandle = PortableArchiveFileHandle(source.path, marker);
            try {
              final input = InputFileStream.withFileHandle(inputHandle);
              final member =
                  ArchiveFile.stream(
                      p.posix.fromUri(
                        p.toUri(message['archivePath'] as String),
                      ),
                      input,
                    )
                    ..mode = stat.mode
                    ..lastModTime =
                        stat.modified.millisecondsSinceEpoch ~/ 1000;
              encoder!.addArchiveFile(member);
            } finally {
              // archive.addFile lacks a finally around its source stream.
              // Closing the owned raw handle survives cancellation/codec errors.
              inputHandle.closeSync();
            }
            reply.send(<String, dynamic>{'id': id, 'ok': true});
          case 'finish':
            await encoder?.close();
            encoder = null;
            reply.send(<String, dynamic>{'id': id, 'ok': true});
            inbox.close();
            return;
          default:
            throw StateError('未知的 Zip 指令');
        }
      } catch (error) {
        try {
          await encoder?.close();
        } catch (_) {}
        encoder = null;
        reply.send(<String, dynamic>{
          'id': id,
          'ok': false,
          'error': error.toString(),
        });
        inbox.close();
        return;
      }
    }
  } finally {
    try {
      await encoder?.close();
    } catch (_) {}
    // OutputFileStream.close flushes before close, so a cancellation exception
    // during flush must not prevent the actual Windows descriptor from closing.
    outputHandle?.closeSync();
  }
}

/// Archive-worker I/O checkpoints shared by ZIP and FluentPack exporters.
class PortableArchiveFileHandle extends FileHandle {
  PortableArchiveFileHandle(super.path, this.marker, {super.mode});
  final File marker;

  @override
  int readInto(Uint8List buffer, [int? length]) {
    _throwIfCancelled(marker.existsSync);
    return super.readInto(buffer, length);
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    _throwIfCancelled(marker.existsSync);
    super.writeFromSync(buffer, start, end);
  }
}
