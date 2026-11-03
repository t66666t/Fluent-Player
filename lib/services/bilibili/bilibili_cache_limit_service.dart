import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../library_service.dart';
import '../media_playback_service.dart';
import '../settings_service.dart';
import 'bilibili_streaming_service.dart';

/// Disk usage of the online playback cache.
class BilibiliCacheUsage {
  final int bytes;
  final int fileCount;

  const BilibiliCacheUsage({required this.bytes, required this.fileCount});

  static const empty = BilibiliCacheUsage(bytes: 0, fileCount: 0);
}

/// What one trim pass did.
class BilibiliCacheTrimResult {
  final int bytesBefore;
  final int bytesAfter;

  /// Card cache folders that were removed, oldest first.
  final List<String> removedEntries;

  const BilibiliCacheTrimResult({
    required this.bytesBefore,
    required this.bytesAfter,
    this.removedEntries = const <String>[],
  });
}

class _CacheEntry {
  final String name;
  final Directory dir;
  final int bytes;
  final DateTime newest;

  const _CacheEntry(this.name, this.dir, this.bytes, this.newest);
}

/// Keeps the online playback cache root under a size cap.
///
/// The root holds one folder per online card (gateway media pieces,
/// transcription audio and local material copies, all of which can be fetched
/// again). A trim removes whole card folders, least recently written first,
/// until the total fits; protected folders (cards being played) are skipped.
/// Nothing outside the root is ever looked at.
class BilibiliCacheLimiter {
  BilibiliCacheLimiter({required this.cacheRoot, required this.removeEntry});

  final Future<Directory> Function() cacheRoot;

  /// Removes the card cache folder [entryName] (a direct child of the root).
  final Future<void> Function(String entryName, Directory dir) removeEntry;

  Future<BilibiliCacheUsage> usage() async {
    final root = await cacheRoot();
    final (bytes, files, _) = await _measure(root);
    return BilibiliCacheUsage(bytes: bytes, fileCount: files);
  }

  Future<BilibiliCacheTrimResult> trim(
    int limitBytes, {
    Set<String> protectedEntries = const <String>{},
  }) async {
    final root = await cacheRoot();
    if (!await root.exists()) {
      return const BilibiliCacheTrimResult(bytesBefore: 0, bytesAfter: 0);
    }
    final entries = <_CacheEntry>[];
    var total = 0;
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory) {
        final (bytes, _, newest) = await _measure(entity);
        total += bytes;
        entries.add(
          _CacheEntry(
            p.basename(entity.path),
            entity,
            bytes,
            newest ?? DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      } else if (entity is File) {
        total += await _length(entity);
      }
    }
    final before = total;
    if (total <= limitBytes) {
      return BilibiliCacheTrimResult(bytesBefore: before, bytesAfter: total);
    }
    entries.sort((a, b) => a.newest.compareTo(b.newest));
    final removed = <String>[];
    for (final entry in entries) {
      if (total <= limitBytes) break;
      if (protectedEntries.contains(entry.name)) continue;
      try {
        await removeEntry(entry.name, entry.dir);
      } catch (_) {
        // A file still held open survives; it is measured below.
      }
      final (left, _, _) = await _measure(entry.dir);
      total -= entry.bytes - left;
      removed.add(entry.name);
    }
    return BilibiliCacheTrimResult(
      bytesBefore: before,
      bytesAfter: total,
      removedEntries: removed,
    );
  }

  static Future<(int, int, DateTime?)> _measure(Directory dir) async {
    var bytes = 0;
    var files = 0;
    DateTime? newest;
    if (!await dir.exists()) return (0, 0, null);
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          bytes += stat.size;
          files++;
          if (newest == null || stat.modified.isAfter(newest)) {
            newest = stat.modified;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return (bytes, files, newest);
  }

  static Future<int> _length(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }
}

enum BilibiliCacheClearOutcome { cleared, refusedWhilePlaying }

/// The online cache size cap and the one-tap clear behind the Bilibili
/// settings page.
///
/// The cap only manages `bilibili_stream_cache`; downloaded videos, imported
/// media, card data (covers, preview frames, danmaku) and cookies live
/// elsewhere and are never touched.
class BilibiliCacheManager extends ChangeNotifier {
  BilibiliCacheManager({
    required this.limiter,
    required this.limitBytes,
    required this.isPlaying,
    required this.protectedEntries,
    required this.clearEverything,
  });

  /// Wires the cap to the running app: trims a while after startup, again
  /// after the playback service writes cache (debounced) and whenever the
  /// cap setting changes.
  factory BilibiliCacheManager.forApp({
    required LibraryService library,
    required BilibiliStreamingService streaming,
    required MediaPlaybackService playback,
    SettingsService? settings,
  }) {
    final prefs = settings ?? SettingsService();
    Future<void> removeEntry(String name, Directory dir) async {
      // Watch-only cards count against the cap like library cards.
      for (final item in library.onlineCacheItems) {
        if (BilibiliStreamingService.cacheEntryName(item.id) == name) {
          // Lease-aware: material still in use is deleted later.
          await library.clearOnlineCacheForItem(item.id);
          return;
        }
      }
      // Folder of a card that no longer exists.
      await BilibiliStreamingService.clearCacheForItemOnDisk(
        name,
        cacheDirectory: dir.parent,
      );
    }

    final manager = BilibiliCacheManager(
      limiter: BilibiliCacheLimiter(
        cacheRoot: streaming.resolveCacheDirectory,
        removeEntry: removeEntry,
      ),
      limitBytes: () => prefs.bilibiliCacheLimitBytes,
      isPlaying: () => playback.isPlaying,
      protectedEntries: () => <String>{
        for (final id in streaming.cacheItemIdsInUse)
          BilibiliStreamingService.cacheEntryName(id),
        if (playback.currentItem case final item?)
          BilibiliStreamingService.cacheEntryName(item.id),
      },
      clearEverything: () async {
        // Same order as the media library cache section: per card through
        // the lease-aware path, then sweep what is left.
        var incomplete = false;
        for (final item in library.onlineCacheItems.toList()) {
          final result = await library.clearOnlineCacheForItem(item.id);
          incomplete |= result != OnlineCacheClearStatus.cleared;
        }
        if (incomplete || library.hasOnlineCacheStorageUse) {
          throw const FileSystemException(
            'Some online cache remains in use or could not be deleted',
          );
        }
        await streaming.clearCache();
        final remaining = await streaming.inspectCache(strict: true);
        if (remaining.fileCount > 0) {
          throw const FileSystemException(
            'Some online cache files could not be deleted',
          );
        }
      },
    );
    manager._watch(streaming, prefs);
    return manager;
  }

  static BilibiliCacheManager? _instance;

  /// The app-wide manager, installed at startup; null in tests that do not
  /// set one.
  static BilibiliCacheManager? get instance => _instance;

  static void install(BilibiliCacheManager? manager) {
    if (identical(_instance, manager)) return;
    _instance?.dispose();
    _instance = manager;
  }

  static const Duration startupDelay = Duration(seconds: 8);
  static const Duration writeDebounce = Duration(seconds: 15);

  final BilibiliCacheLimiter limiter;
  final int Function() limitBytes;
  final bool Function() isPlaying;
  final Set<String> Function() protectedEntries;
  final Future<void> Function() clearEverything;

  Timer? _timer;
  Future<BilibiliCacheTrimResult>? _trimming;
  bool _clearing = false;
  VoidCallback? _unwatch;

  void _watch(BilibiliStreamingService streaming, SettingsService prefs) {
    var lastLimit = prefs.bilibiliCacheLimitBytes;
    void onWrite() => scheduleTrim(writeDebounce);
    void onSettings() {
      if (prefs.bilibiliCacheLimitBytes == lastLimit) return;
      lastLimit = prefs.bilibiliCacheLimitBytes;
      scheduleTrim(Duration.zero);
    }

    streaming.addListener(onWrite);
    prefs.addListener(onSettings);
    _unwatch = () {
      streaming.removeListener(onWrite);
      prefs.removeListener(onSettings);
    };
    scheduleTrim(startupDelay);
  }

  /// Runs a trim after [delay], replacing any trim already waiting.
  void scheduleTrim(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(trimNow()));
  }

  Future<BilibiliCacheUsage> usage() => limiter.usage();

  /// Trims to the current cap now; concurrent calls share one pass.
  Future<BilibiliCacheTrimResult> trimNow() {
    final running = _trimming;
    if (running != null) return running;
    final future = _trim();
    _trimming = future;
    return future.whenComplete(() => _trimming = null);
  }

  Future<BilibiliCacheTrimResult> _trim() async {
    if (_clearing) {
      return const BilibiliCacheTrimResult(bytesBefore: 0, bytesAfter: 0);
    }
    try {
      final result = await limiter.trim(
        limitBytes(),
        protectedEntries: protectedEntries(),
      );
      if (result.removedEntries.isNotEmpty) {
        debugPrint(
          '[BilibiliCache] trimmed ${result.removedEntries.length} card '
          'caches: ${result.bytesBefore} -> ${result.bytesAfter} bytes',
        );
        notifyListeners();
      }
      return result;
    } catch (e) {
      debugPrint('[BilibiliCache] trim failed: $e');
      return const BilibiliCacheTrimResult(bytesBefore: 0, bytesAfter: 0);
    }
  }

  /// Clears the whole online cache, unless something is playing.
  Future<BilibiliCacheClearOutcome> clearAll() async {
    if (isPlaying()) return BilibiliCacheClearOutcome.refusedWhilePlaying;
    _clearing = true;
    try {
      await _trimming;
      await clearEverything();
    } finally {
      _clearing = false;
    }
    notifyListeners();
    return BilibiliCacheClearOutcome.cleared;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _unwatch?.call();
    _unwatch = null;
    super.dispose();
  }
}

/// `"312 MB"`-style size text.
String formatBilibiliCacheSize(int bytes) {
  const kib = 1024;
  const mib = kib * 1024;
  const gib = mib * 1024;
  if (bytes >= gib) {
    final value = bytes / gib;
    return '${value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} GB';
  }
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(0)} MB';
  if (bytes >= kib) return '${(bytes / kib).toStringAsFixed(0)} KB';
  return '$bytes B';
}
