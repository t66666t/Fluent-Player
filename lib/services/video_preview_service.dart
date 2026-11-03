import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

class VideoPreviewService {
  static final VideoPreviewService _instance = VideoPreviewService._internal();
  factory VideoPreviewService() => _instance;
  VideoPreviewService._internal();

  // Cache: key = "path_timeMs", value = bytes
  // Using LinkedHashMap for LRU (Least Recently Used) cache
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap<String, Uint8List>();
  final int _maxCacheSize = 140; // Keep more recent previews for scrubbing reuse
  final Map<String, List<int>> _keyframeIndexCache = {};
  final Map<String, Future<List<int>>> _keyframeIndexLoads = {};
  final Map<String, double> _frameIntervalMsCache = {};
  final Map<String, Future<double?>> _frameIntervalLoads = {};
  Future<Directory>? _tempDirFuture;
  Timer? _idleCacheCleanupTimer;
  bool _staleTempCleanupRunning = false;

  static const int _fallbackRequestBucketMs = 80;
  static const String _previewTempDirName = 'seek_preview_cache';
  static const Duration _idleCacheCleanupDelay = Duration(seconds: 20);
  static const Duration _staleTempFileMaxAge = Duration(minutes: 10);
  static const int _fastPreviewWidth = 176;
  static const int _fastPreviewQuality = 38;
  static const int _precisePreviewWidth = 200;
  static const int _precisePreviewQuality = 50;

  bool _isGenerating = false;
  _PreviewRequest? _nextRequest;
  String? _activeRequestKey;
  Future<Uint8List?>? _activeRequestFuture;

  /// Preloads lightweight metadata used to make later preview requests
  /// more accurate without delaying the first drag interaction.
  void warmup(String videoPath) {
    _cleanupStaleTempFilesIfNeeded();
    _warmKeyframeIndex(videoPath);
    _warmFrameInterval(videoPath);
  }

  /// Called when the UI finishes interacting with seek preview.
  /// Keeps a short reuse window, then releases in-memory preview bytes.
  void markInteractionEnded() {
    _scheduleIdleCacheCleanup();
  }

  /// Requests a preview image for the given video at the specified timestamp.
  /// Returns null if generation fails.
  ///
  /// This method implements a "latest-wins" throttling mechanism to avoid
  /// overwhelming the system with thumbnail generation tasks during rapid
  /// scrubbing, while still allowing the newest request to complete later.
  Future<Uint8List?> requestPreview(String videoPath, int timeMs) {
    return _requestPreviewInternal(videoPath, timeMs, precise: false);
  }

  /// Requests a more precise preview for the current dwell position.
  /// This is intended for the "user paused while dragging" case, where
  /// slightly higher generation cost is acceptable in exchange for accuracy.
  Future<Uint8List?> requestPrecisePreview(String videoPath, int timeMs) {
    return _requestPreviewInternal(videoPath, timeMs, precise: true);
  }

  Future<Uint8List?> _requestPreviewInternal(
    String videoPath,
    int timeMs, {
    required bool precise,
  }) async {
    _cancelIdleCacheCleanup();
    _cleanupStaleTempFilesIfNeeded();
    final keyframes = _keyframeIndexCache[videoPath];
    if (keyframes == null) {
      _warmKeyframeIndex(videoPath);
    }

    final frameInterval = _frameIntervalMsCache[videoPath];
    if (frameInterval == null) {
      _warmFrameInterval(videoPath);
    }

    final mappedTimeMs = _resolveRequestTimeMs(
      timeMs,
      frameInterval,
      precise: precise,
    );
    final anchorTimeMs = keyframes == null || keyframes.isEmpty
        ? mappedTimeMs
        : _nearestKeyframeAtOrBefore(keyframes, mappedTimeMs);
    final key = _generateKey(videoPath, mappedTimeMs, precise: precise);
    
    // 1. Check memory cache first
    if (_cache.containsKey(key)) {
      // Move to end (mark as recently used)
      final data = _cache.remove(key)!;
      _cache[key] = data;
      return data;
    }

    // 2. Reuse the current in-flight request when the requested frame matches.
    if (_activeRequestKey == key && _activeRequestFuture != null) {
      return _activeRequestFuture!;
    }

    // 3. Reuse an already-queued latest request for the same frame.
    if (_nextRequest != null && _nextRequest!.key == key) {
      return _nextRequest!.completer.future;
    }

    // 4. If already generating, replace the queued request with the latest one.
    if (_isGenerating) {
      _nextRequest?.complete(null);
      _nextRequest = _PreviewRequest(
        videoPath: videoPath,
        timeMs: mappedTimeMs,
        anchorTimeMs: anchorTimeMs,
        key: key,
        precise: precise,
      );
      return _nextRequest!.completer.future;
    }

    // 5. Start generation immediately.
    final request = _PreviewRequest(
      videoPath: videoPath,
      timeMs: mappedTimeMs,
      anchorTimeMs: anchorTimeMs,
      key: key,
      precise: precise,
    );
    return _startRequest(request);
  }

  Future<Uint8List?> _startRequest(_PreviewRequest request) {
    _activeRequestKey = request.key;
    final future = _processRequest(request);
    _activeRequestFuture = future;
    future.whenComplete(() {
      if (identical(_activeRequestFuture, future)) {
        _activeRequestFuture = null;
        _activeRequestKey = null;
      }
    });
    return future;
  }

  Future<Uint8List?> _processRequest(_PreviewRequest request) async {
    _isGenerating = true;
    Uint8List? result;

    try {
      // Check cache again just in case
      final key = request.key;
      if (_cache.containsKey(key)) {
        result = _cache.remove(key);
        if (result != null) {
          _cache[key] = result;
        }
      } else {
        // Linux/desktop Process path: video_thumbnail has no Linux plugin —
        // prefer system ffmpeg first so logs are not flooded with MissingPlugin.
        if (FFmpegUtils.preferSystemFfmpeg) {
          if (request.precise) {
            result = await _extractFrameAccurate(
              request.videoPath,
              request.timeMs,
              request.anchorTimeMs,
            );
            result ??= await _extractFrameFast(
              request.videoPath,
              request.timeMs,
              maxWidth: _precisePreviewWidth,
              quality: _precisePreviewQuality,
            );
          } else {
            result = await _extractFrameFast(
              request.videoPath,
              request.timeMs,
              maxWidth: _fastPreviewWidth,
              quality: _fastPreviewQuality,
            );
            result ??= await _extractFrameAccurate(
              request.videoPath,
              request.timeMs,
              request.anchorTimeMs,
            );
          }
        } else if (request.precise) {
          result = await _extractFrameAccurate(
            request.videoPath,
            request.timeMs,
            request.anchorTimeMs,
          );
          result ??= await _extractFrameFast(
            request.videoPath,
            request.timeMs,
            maxWidth: _precisePreviewWidth,
            quality: _precisePreviewQuality,
          );
        } else {
          result = await _extractFrameFast(
            request.videoPath,
            request.timeMs,
            maxWidth: _fastPreviewWidth,
            quality: _fastPreviewQuality,
          );
          result ??= await _extractFrameAccurate(
            request.videoPath,
            request.timeMs,
            request.anchorTimeMs,
          );
        }
        if (result != null) {
          _addToCache(key, result);
        }
      }
    } catch (e) {
      debugPrint("VideoPreviewService: Error generating thumbnail: $e");
    } finally {
      request.complete(result);
      if (_nextRequest != null) {
        final next = _nextRequest!;
        _nextRequest = null;
        Future.microtask(() => _startRequest(next));
      } else {
        _isGenerating = false;
      }
    }

    return result;
  }

  void _addToCache(String key, Uint8List data) {
    if (_cache.length >= _maxCacheSize) {
      _cache.remove(_cache.keys.first); // Remove least recently used
    }
    _cache[key] = data;
  }

  String _generateKey(
    String path,
    int timeMs, {
    required bool precise,
  }) => "${path}_${timeMs}_${precise ? 'p' : 'f'}";

  /// Clears the memory cache
  void clearCache() {
    _cancelIdleCacheCleanup();
    _cache.clear();
  }

  void _warmKeyframeIndex(String videoPath) {
    if (_keyframeIndexCache.containsKey(videoPath)) return;
    if (_keyframeIndexLoads.containsKey(videoPath)) return;
    _keyframeIndexLoads[videoPath] = _loadKeyframeIndex(videoPath).then((list) {
      _keyframeIndexCache[videoPath] = list;
      _keyframeIndexLoads.remove(videoPath);
      return list;
    });
  }

  Future<List<int>> _loadKeyframeIndex(String videoPath) async {
    try {
      if (FFmpegUtils.preferSystemFfmpeg) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobePath, [
          '-v', 'error',
          '-select_streams', 'v:0',
          '-skip_frame', 'nokey',
          '-show_entries', 'frame=pkt_pts_time',
          '-of', 'csv=p=0',
          videoPath
        ]).timeout(const Duration(seconds: 30));
        if (result.exitCode == 0) {
          return _parseKeyframeTimes(result.stdout.toString());
        }
      } else {
        final session = await FFprobeKit.execute(
          '-v error -select_streams v:0 -skip_frame nokey -show_entries frame=pkt_pts_time -of csv=p=0 "$videoPath"'
        );
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          final output = await session.getOutput();
          return _parseKeyframeTimes(output ?? '');
        }
      }
    } catch (_) {}
    return [];
  }

  List<int> _parseKeyframeTimes(String output) {
    final List<int> times = [];
    for (final line in output.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final seconds = double.tryParse(trimmed);
      if (seconds == null) continue;
      times.add((seconds * 1000).round());
    }
    times.sort();
    return times;
  }

  int _nearestKeyframeAtOrBefore(List<int> keyframes, int timeMs) {
    if (keyframes.isEmpty) return timeMs;
    if (timeMs <= keyframes.first) return keyframes.first;
    if (timeMs >= keyframes.last) return keyframes.last;

    int left = 0;
    int right = keyframes.length - 1;
    while (left <= right) {
      final mid = (left + right) >> 1;
      final midVal = keyframes[mid];
      if (midVal == timeMs) return midVal;
      if (midVal < timeMs) {
        left = mid + 1;
      } else {
        right = mid - 1;
      }
    }
    return keyframes[right];
  }

  void _warmFrameInterval(String videoPath) {
    if (_frameIntervalMsCache.containsKey(videoPath)) return;
    if (_frameIntervalLoads.containsKey(videoPath)) return;
    _frameIntervalLoads[videoPath] = _loadFrameIntervalMs(videoPath).then((value) {
      if (value != null && value > 0) {
        _frameIntervalMsCache[videoPath] = value;
      }
      _frameIntervalLoads.remove(videoPath);
      return value;
    });
  }

  Future<double?> _loadFrameIntervalMs(String videoPath) async {
    try {
      if (FFmpegUtils.preferSystemFfmpeg) {
        final ffprobePath = await FFmpegUtils.ffprobePath;
        final result = await Process.run(ffprobePath, [
          '-v', 'error',
          '-select_streams', 'v:0',
          '-show_entries', 'stream=avg_frame_rate,r_frame_rate,time_base',
          '-of', 'json',
          videoPath
        ]).timeout(const Duration(seconds: 15));
        if (result.exitCode == 0) {
          final data = jsonDecode(result.stdout.toString());
          final streams = data['streams'] as List?;
          if (streams != null && streams.isNotEmpty) {
            final stream = streams.first as Map<dynamic, dynamic>;
            final fpsStr = stream['avg_frame_rate']?.toString() ?? stream['r_frame_rate']?.toString();
            final fps = _parseFraction(fpsStr);
            if (fps != null && fps > 0) {
              return 1000.0 / fps;
            }
            final timeBaseStr = stream['time_base']?.toString();
            final timeBase = _parseFraction(timeBaseStr);
            if (timeBase != null && timeBase > 0) {
              return timeBase * 1000.0;
            }
          }
        }
      } else {
        final session = await FFprobeKit.getMediaInformation(videoPath);
        final info = session.getMediaInformation();
        if (info != null) {
          final streams = info.getStreams();
          for (final stream in streams) {
            if (stream.getType() != 'video') continue;
            final fpsStr = stream.getAverageFrameRate() ?? stream.getRealFrameRate();
            final fps = _parseFraction(fpsStr);
            if (fps != null && fps > 0) {
              return 1000.0 / fps;
            }
            final timeBaseStr = stream.getTimeBase();
            final timeBase = _parseFraction(timeBaseStr);
            if (timeBase != null && timeBase > 0) {
              return timeBase * 1000.0;
            }
            break;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  double? _parseFraction(String? value) {
    if (value == null || value.isEmpty) return null;
    if (!value.contains('/')) {
      return double.tryParse(value);
    }
    final parts = value.split('/');
    if (parts.length != 2) return null;
    final num = double.tryParse(parts[0]);
    final den = double.tryParse(parts[1]);
    if (num == null || den == null || den == 0) return null;
    return num / den;
  }

  int _alignToFrameTimeMs(int timeMs, double frameIntervalMs) {
    if (frameIntervalMs <= 0) return timeMs;
    final index = (timeMs / frameIntervalMs).round();
    final aligned = (index * frameIntervalMs).round();
    return aligned < 0 ? 0 : aligned;
  }

  int _resolveRequestTimeMs(
    int timeMs,
    double? frameIntervalMs, {
    required bool precise,
  }) {
    final normalized = timeMs < 0 ? 0 : timeMs;
    if (frameIntervalMs != null && frameIntervalMs > 0) {
      return _alignToFrameTimeMs(normalized, frameIntervalMs);
    }
    if (precise) {
      return normalized;
    }
    return _alignToBucketMs(normalized, _fallbackRequestBucketMs);
  }

  int _alignToBucketMs(int timeMs, int bucketMs) {
    if (bucketMs <= 1) return timeMs;
    final index = (timeMs / bucketMs).round();
    return index * bucketMs;
  }

  void _scheduleIdleCacheCleanup() {
    _idleCacheCleanupTimer?.cancel();
    _idleCacheCleanupTimer = Timer(_idleCacheCleanupDelay, () {
      _cache.clear();
    });
  }

  void _cancelIdleCacheCleanup() {
    _idleCacheCleanupTimer?.cancel();
    _idleCacheCleanupTimer = null;
  }

  void _cleanupStaleTempFilesIfNeeded() {
    if (_staleTempCleanupRunning) {
      return;
    }
    _staleTempCleanupRunning = true;
    unawaited(
      _cleanupStaleTempFiles().whenComplete(() {
        _staleTempCleanupRunning = false;
      }),
    );
  }

  Future<Directory> _getTempDirectoryCached() {
    return _tempDirFuture ??= _createPreviewTempDirectory();
  }

  Future<Directory> _createPreviewTempDirectory() async {
    final tempDir = await getTemporaryDirectory();
    final previewDir = Directory(p.join(tempDir.path, _previewTempDirName));
    if (!await previewDir.exists()) {
      await previewDir.create(recursive: true);
    }
    return previewDir;
  }

  Future<void> _cleanupStaleTempFiles() async {
    try {
      final previewDir = await _getTempDirectoryCached();
      if (!await previewDir.exists()) {
        return;
      }
      final now = DateTime.now();
      await for (final entity in previewDir.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        final stat = await entity.stat();
        final age = now.difference(stat.modified);
        if (age >= _staleTempFileMaxAge) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  Future<Uint8List?> _extractFrameFast(
    String videoPath,
    int timeMs, {
    required int maxWidth,
    required int quality,
  }) async {
    // video_thumbnail has no Linux plugin; prefer system ffmpeg first.
    if (FFmpegUtils.preferSystemFfmpeg) {
      return _extractFrameFfmpegSimple(
        videoPath,
        timeMs,
        maxWidth: maxWidth,
        quality: quality,
      );
    }
    try {
      return await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        maxWidth: maxWidth,
        timeMs: timeMs,
        quality: quality,
      );
    } on MissingPluginException catch (e) {
      debugPrint(
        'VideoPreviewService: video_thumbnail missing, falling back to ffmpeg: $e',
      );
      return _extractFrameFfmpegSimple(
        videoPath,
        timeMs,
        maxWidth: maxWidth,
        quality: quality,
      );
    }
  }

  /// Fast single-seek frame extract via ffmpeg (Linux / MissingPlugin fallback).
  Future<Uint8List?> _extractFrameFfmpegSimple(
    String videoPath,
    int timeMs, {
    required int maxWidth,
    required int quality,
  }) async {
    File? outputFile;
    try {
      final tempDir = await _getTempDirectoryCached();
      final outputPath = p.join(
        tempDir.path,
        'seek_preview_fast_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      outputFile = File(outputPath);
      final seekSec = (timeMs / 1000.0).toStringAsFixed(3);
      // VideoThumbnail quality ~0-100; map roughly to ffmpeg -q:v (2..31).
      final qv = (((100 - quality.clamp(1, 100)) / 100.0) * 29 + 2)
          .round()
          .clamp(2, 31);
      final scale = maxWidth > 0 ? 'scale=$maxWidth:-1' : 'scale=176:-1';
      final args = [
        '-hide_banner',
        '-loglevel',
        'error',
        '-ss',
        seekSec,
        '-i',
        videoPath,
        '-frames:v',
        '1',
        '-vf',
        scale,
        '-q:v',
        '$qv',
        '-y',
        outputPath,
      ];

      if (FFmpegUtils.preferSystemFfmpeg) {
        final ffmpegPath = await FFmpegUtils.ffmpegPath;
        final result = await Process.run(ffmpegPath, args)
            .timeout(const Duration(seconds: 20));
        if (result.exitCode != 0) return null;
      } else {
        final session = await FFmpegKit.executeWithArguments(args);
        final returnCode = await session.getReturnCode();
        if (!ReturnCode.isSuccess(returnCode)) return null;
      }

      if (await outputFile.exists()) {
        final bytes = await outputFile.readAsBytes();
        if (bytes.isEmpty) return null;
        return bytes;
      }
    } catch (_) {
    } finally {
      if (outputFile != null) {
        try {
          if (await outputFile.exists()) {
            await outputFile.delete();
          }
        } catch (_) {}
      }
    }
    return null;
  }

  Future<Uint8List?> _extractFrameAccurate(String videoPath, int targetTimeMs, int anchorTimeMs) async {
    File? outputFile;
    try {
      final tempDir = await _getTempDirectoryCached();
      final outputPath = p.join(tempDir.path, "seek_preview_${DateTime.now().microsecondsSinceEpoch}.jpg");
      outputFile = File(outputPath);
      final safeAnchor = anchorTimeMs <= targetTimeMs ? anchorTimeMs : targetTimeMs;
      final offsetMs = targetTimeMs - safeAnchor;
      final anchorSec = (safeAnchor / 1000.0).toStringAsFixed(3);
      final offsetSec = (offsetMs / 1000.0).toStringAsFixed(3);
      final args = [
        '-hide_banner',
        '-loglevel', 'error',
        '-ss', anchorSec,
        '-i', videoPath,
        '-ss', offsetSec,
        '-frames:v', '1',
        '-vf', 'scale=200:-1',
        '-q:v', '4',
        '-y',
        outputPath
      ];

      if (FFmpegUtils.preferSystemFfmpeg) {
        final ffmpegPath = await FFmpegUtils.ffmpegPath;
        final result = await Process.run(ffmpegPath, args).timeout(const Duration(seconds: 30));
        if (result.exitCode != 0) return null;
      } else {
        final session = await FFmpegKit.executeWithArguments(args);
        final returnCode = await session.getReturnCode();
        if (!ReturnCode.isSuccess(returnCode)) return null;
      }

      if (await outputFile.exists()) {
        final bytes = await outputFile.readAsBytes();
        if (bytes.isEmpty) return null;
        return bytes;
      }
    } catch (_) {}
    finally {
      if (outputFile != null) {
        try {
          if (await outputFile.exists()) {
            await outputFile.delete();
          }
        } catch (_) {}
      }
    }
    return null;
  }
}

class _PreviewRequest {
  final String videoPath;
  final int timeMs;
  final int anchorTimeMs;
  final String key;
  final bool precise;
  final Completer<Uint8List?> completer;

  _PreviewRequest({
    required this.videoPath,
    required this.timeMs,
    required this.anchorTimeMs,
    required this.key,
    required this.precise,
  }) : completer = Completer<Uint8List?>();

  void complete(Uint8List? data) {
    if (!completer.isCompleted) {
      completer.complete(data);
    }
  }
}
