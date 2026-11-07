import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../../models/managed_subtitle_asset.dart';
import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../../services/subtitle_discovery_service.dart';
import '../../services/task_subtitle_storage_service.dart';
import '../../utils/ffmpeg_utils.dart';
import '../../utils/subtitle_parser.dart';

class ExternalAiPreparationCancelled implements Exception {}

class ExternalAiDocumentWork {
  bool cancelled = false;
  Process? _process;
  void check() {
    if (cancelled) throw ExternalAiPreparationCancelled();
  }

  void cancel() {
    cancelled = true;
    _process?.kill();
  }

  /// Drain bounded output and kill/reap on timeout or cancellation. A cancelled
  /// batch never leaves an extraction process running in the background.
  Future<({int code, String output})> run(
    String binary,
    List<String> args, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    check();
    final process = await Process.start(binary, args);
    _process = process;
    final output = <int>[];
    var overflow = false;
    void collect(List<int> data) {
      if (output.length + data.length > 1024 * 1024) {
        overflow = true;
        process.kill();
      } else {
        output.addAll(data);
      }
    }

    final out = process.stdout.listen(collect),
        err = process.stderr.listen(collect);
    final outputDone = out.asFuture<void>(), errorDone = err.asFuture<void>();
    try {
      check();
      final code = await process.exitCode.timeout(timeout);
      await Future.wait([
        outputDone,
        errorDone,
      ]).timeout(const Duration(seconds: 5));
      check();
      if (overflow) throw StateError('subtitle probe output exceeded limit');
      return (code: code, output: utf8.decode(output, allowMalformed: true));
    } finally {
      process.kill();
      await process.exitCode;
      await out.cancel();
      await err.cancel();
      if (identical(_process, process)) _process = null;
    }
  }
}

typedef ExternalAiOnlineDocuments =
    Future<Map<String, dynamic>> Function(
      VideoItem item,
      void Function() guard,
      ExternalAiDocumentWork work,
    );

Future<String?> externalAiDocumentLocalPath(VideoItem item) async {
  for (final path in {
    item.path,
    item.playbackPath,
    item.bilibiliDownloadPath,
  }.whereType<String>()) {
    final local = SubtitleDiscoveryService.localVideoPath(path);
    if (local == null || !p.isAbsolute(local)) continue;
    try {
      if ((await File(local).stat()).type == FileSystemEntityType.file) {
        return local;
      }
    } on FileSystemException {
      /* A remote/cached source may currently be offline. */
    }
  }
  return null;
}

Future<String> externalAiDocumentIdentity(VideoItem item) async {
  final local = await externalAiDocumentLocalPath(item);
  FileStat? stat;
  if (local != null) {
    try {
      stat = await File(local).stat();
    } on FileSystemException {
      /* Existing text remains readable if media is offline. */
    }
  }
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            item.id,
            item.path,
            item.sourceRef?.toJson(),
            stat?.size,
            stat?.modified.microsecondsSinceEpoch,
          ]),
        ),
      )
      .toString();
}

/// Prepares existing TEXT only. It never transcribes, OCRs, plays media or
/// materializes a remote video. Native paths/URLs stay behind this adapter.
typedef ExternalAiSubtitleCommand =
    Future<({int code, String output})> Function(
      ExternalAiDocumentWork work,
      bool probe,
      List<String> arguments,
    );

class ExternalAiDocumentBackend {
  ExternalAiDocumentBackend({required this.library, this.online, this.command});
  final LibraryService library;
  final ExternalAiOnlineDocuments? online;
  final ExternalAiSubtitleCommand? command;
  Future<({int code, String output})> _command(
    ExternalAiDocumentWork work,
    bool probe,
    List<String> arguments,
  ) async => command != null
      ? command!(work, probe, arguments)
      : work.run(
          probe ? await FFmpegUtils.ffprobePath : await FFmpegUtils.ffmpegPath,
          arguments,
          timeout: Duration(seconds: probe ? 20 : 90),
        );
  static const textExtensions = {
    '.srt',
    '.vtt',
    '.ass',
    '.ssa',
    '.lrc',
    '.ttml',
    '.dfxp',
    '.txt',
    '.json',
    '.xml',
  };
  static const textCodecs = {
    'subrip',
    'srt',
    'ass',
    'ssa',
    'webvtt',
    'mov_text',
    'text',
    'ttml',
    'dfxp',
    'sami',
    'microdvd',
    'mpl2',
    'jacosub',
    'subviewer',
    'subviewer1',
    'vplayer',
    'realtext',
    'eia_608',
    'hdmv_text_subtitle',
    'arib_caption',
    'dvb_teletext',
    'pjs',
    'stl',
    'aqtitle',
  };

  Future<String> identity(VideoItem item) => externalAiDocumentIdentity(item);

  Future<bool> _readable(String path, {String? formatPath}) async {
    final sourcePath = formatPath ?? path;
    if (!textExtensions.contains(p.extension(sourcePath).toLowerCase())) {
      return false;
    }
    try {
      final file = File(path), length = await File(path).length();
      if (length == 0 || length > 16 * 1024 * 1024) return false;
      final bytes = await file.readAsBytes();
      final text = SubtitleParser.decodeBytes(bytes, sourcePath: sourcePath);
      if (text.contains('\u0000')) return false;
      return SubtitleParser.parse(text, sourcePath: sourcePath).isNotEmpty ||
          (p.extension(sourcePath).toLowerCase() == '.txt' &&
              text.trim().isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  final Map<String, Future<void>> _mediaWrites = {};
  Future<Map<String, dynamic>> prepare(
    VideoItem item, {
    required SubtitleDiscoveryBatch batch,
    required ExternalAiDocumentWork work,
    required void Function() guard,
    bool includeEmbedded = true,
    bool includeOnline = true,
  }) {
    final next = (_mediaWrites[item.id] ?? Future<void>.value()).then((_) {
      work.check();
      guard();
      return _prepare(
        item,
        batch: batch,
        work: work,
        guard: guard,
        includeEmbedded: includeEmbedded,
        includeOnline: includeOnline,
      );
    });
    final done = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _mediaWrites[item.id] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(_mediaWrites[item.id], done)) {
          _mediaWrites.remove(item.id);
        }
      }),
    );
    return next;
  }

  Future<Map<String, dynamic>> _prepare(
    VideoItem item, {
    required SubtitleDiscoveryBatch batch,
    required ExternalAiDocumentWork work,
    required void Function() guard,
    bool includeEmbedded = true,
    bool includeOnline = true,
  }) async {
    void check() {
      work.check();
      guard();
    }

    check();
    final storage = TaskSubtitleStorageService(
      dataRootOverride: library.dataRootDirOrNull,
    );
    // A prior playback-page extraction is already a valid prepared result,
    // including tracks which are no longer selected as primary/secondary.
    final known = <String>{
      if (item.subtitlePath != null) item.subtitlePath!,
      if (item.secondarySubtitlePath != null) item.secondarySubtitlePath!,
      ...item.managedSubtitleAssets.map((a) => a.path),
      ...?item.additionalSubtitles?.values,
      ...?item.localSubtitles?.values,
      ...await storage
          .listTaskSubtitles(item.id)
          .then((v) => v.map((f) => f.path)),
    };
    final sourceVersion = await identity(item);
    for (final path in known) {
      final name = p.basename(path);
      if (name.startsWith('mcp-soft-') &&
          !name.startsWith('mcp-soft-${sourceVersion.substring(0, 16)}-')) {
        continue;
      }
      if (await _readable(path)) {
        check();
        return {'state': 'ready', 'reused': true, 'source': 'saved'};
      }
    }
    final local = await externalAiDocumentLocalPath(item);
    var candidates = 0;
    if (local != null) {
      final found = await const SubtitleDiscoveryService().scanVideoDirectory(
        videoPath: local,
        videoDurationMs: item.durationMs,
        batch: batch,
      );
      for (final file in found.where((f) => f.isAuto).take(24)) {
        check();
        if (!await _readable(file.path)) continue;
        check();
        // The read adapter already exposes strongly matched adjacent text.
        // Keep it in place: managed assets must belong to the app's task
        // directory, and discovery should not duplicate or move user files.
        return {'state': 'ready', 'reused': true, 'source': 'sidecar'};
      }
      candidates = found
          .where((f) => !f.isAuto && f.grade.name != 'rejected')
          .length;
      if (!includeEmbedded) {
        return {
          'state': candidates > 0 ? 'candidate' : 'unchecked',
          'candidateCount': candidates,
          'reason': 'embedded_not_checked',
        };
      }
      final before = await identity(item);
      // Community inputs are local files; no protected-media gateway exists.
      {
        check();
        final probe = await _command(work, true, [
          '-v',
          'error',
          '-select_streams',
          's',
          '-show_entries',
          'stream=index,codec_name:stream_tags=language,title',
          '-of',
          'json',
          local,
        ]);
        if (probe.code != 0) throw StateError('probe unavailable');
        final streams =
            (jsonDecode(probe.output) as Map)['streams'] as List? ?? [];
        final text = streams
            .whereType<Map>()
            .where((s) => textCodecs.contains(s['codec_name']))
            .toList();
        if (text.isEmpty) {
          return {
            'state': candidates > 0
                ? 'candidate'
                : streams.any(
                    (s) =>
                        s is Map &&
                        !{
                          'hdmv_pgs_subtitle',
                          'dvd_subtitle',
                          'dvb_subtitle',
                          'xsub',
                        }.contains(s['codec_name']),
                  )
                ? 'unsupported'
                : 'confirmed_none',
            'candidateCount': candidates,
            'ignoredNonTextTrackCount': streams.length,
            'checkedSources': ['saved', 'sidecar', 'embedded_text'],
          };
        }
        final stream = text.first, index = stream['index'];
        if (index is! int || index < 0) {
          throw StateError('invalid subtitle stream');
        }
        final directory = await storage.taskDirectory(item.id, create: true);
        final suffix =
            stream['codec_name'] == 'ass' || stream['codec_name'] == 'ssa'
            ? '.ass'
            : '.srt';
        final file = File(
          p.join(
            directory.path,
            'mcp-soft-${before.substring(0, 16)}-$index$suffix',
          ),
        );
        if (!await _readable(file.path)) {
          final temp = '${file.path}.partial';
          try {
            check();
            final extraction = await _command(work, false, [
              '-nostdin',
              '-v',
              'error',
              '-y',
              '-i',
              local,
              '-map',
              '0:$index',
              '-c:s',
              suffix == '.ass' ? 'ass' : 'srt',
              '-fs',
              '16777216',
              '-f',
              suffix == '.ass' ? 'ass' : 'srt',
              temp,
            ]);
            check();
            if (extraction.code != 0 ||
                await File(temp).length() >= 16 * 1024 * 1024 ||
                !await _readable(temp, formatPath: file.path)) {
              throw StateError('text extraction failed');
            }
            if (await identity(item) != before) {
              throw StateError('source changed');
            }
            check();
            await File(temp).rename(file.path);
          } finally {
            if (await File(temp).exists()) await File(temp).delete();
          }
        }
        check();
        if (await identity(item) != before) throw StateError('source changed');
        check();
        final tags = stream['tags'] is Map ? stream['tags'] as Map : const {};
        await library.registerManagedSubtitleAsset(
          item.id,
          path: file.path,
          kind: ManagedSubtitleAssetKind.embedded,
          displayName: '内嵌文字字幕',
          language: tags['language'] as String?,
          entryId: 'mcp-soft-$before-$index',
          shareWithBilibiliPart: false,
          authorize: check,
        );
        return {
          'state': 'ready',
          'source': 'embedded_text',
          'reused': false,
          'remainingTextTracks': text.length - 1,
        };
      }
    }
    if (includeOnline && online != null) return online!(item, check, work);
    return {
      'state': 'unchecked',
      'reason': 'remote_embedded_not_downloaded',
      'note': '不会为提取字幕下载整个媒体；可准备已存在的在线字幕或另外申请转录。',
    };
  }
}
