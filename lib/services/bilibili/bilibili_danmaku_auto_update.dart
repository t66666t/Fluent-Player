import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/video_item.dart';
import '../library_service.dart';
import 'bilibili_download_service.dart';

/// How long a successful check suppresses another automatic fetch.
const Duration bilibiliDanmakuAutoUpdateSuccessCooldown = Duration(hours: 12);

/// How long a dead, empty, or timeline-mismatched source stays quiet.
const Duration bilibiliDanmakuAutoUpdateHardCooldown = Duration(hours: 24);

/// Comments already on screen are left alone once playback is past this point.
const Duration bilibiliDanmakuAutoUpdateImmediateApply = Duration(seconds: 15);

/// A position jump at least this large counts as a seek and may reveal a
/// refresh that was held back during playback.
const Duration bilibiliDanmakuAutoUpdateSeekThreshold = Duration(
  milliseconds: 1200,
);

/// Cooldown identity. Prefer BV+cid so two cards of the same part share it.
String bilibiliDanmakuAutoUpdateLedgerKey(VideoItem item) {
  final source = item.sourceRef;
  final bvid = (source?.bvid ?? '').trim();
  final cid = source?.cid ?? 0;
  if (bvid.isNotEmpty && cid > 0) return '$bvid:$cid';
  final page = source?.page ?? 0;
  if (bvid.isNotEmpty && page > 0) return '$bvid:p$page';
  return 'item:${item.id}';
}

/// True when swapping the sidecar would not interrupt comments already flying.
bool bilibiliDanmakuAutoUpdateApplyNow({
  required Duration position,
  required bool playing,
}) {
  return position < bilibiliDanmakuAutoUpdateImmediateApply || !playing;
}

class DanmakuAutoUpdateBlock {
  final DateTime at;
  final bool hard;

  const DanmakuAutoUpdateBlock({required this.at, required this.hard});

  bool blocksAt(DateTime now) {
    final window = hard
        ? bilibiliDanmakuAutoUpdateHardCooldown
        : bilibiliDanmakuAutoUpdateSuccessCooldown;
    return now.difference(at) < window;
  }
}

abstract class DanmakuAutoUpdateLedger {
  Future<DanmakuAutoUpdateBlock?> blockFor(String key);

  Future<void> record(String key, {required bool hard, required DateTime at});
}

class MemoryDanmakuAutoUpdateLedger implements DanmakuAutoUpdateLedger {
  final Map<String, DanmakuAutoUpdateBlock> records = {};

  @override
  Future<DanmakuAutoUpdateBlock?> blockFor(String key) async => records[key];

  @override
  Future<void> record(
    String key, {
    required bool hard,
    required DateTime at,
  }) async {
    records[key] = DanmakuAutoUpdateBlock(at: at, hard: hard);
  }
}

class PrefsDanmakuAutoUpdateLedger implements DanmakuAutoUpdateLedger {
  static const prefsKey = 'bilibiliDanmakuAutoUpdateLedgerV1';

  final SharedPreferences _prefs;
  Map<String, dynamic>? _cache;

  PrefsDanmakuAutoUpdateLedger(this._prefs);

  Map<String, dynamic> _read() {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = _prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) {
      return _cache = <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return _cache = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // A corrupt ledger must not block playback or keep retrying forever.
    }
    return _cache = <String, dynamic>{};
  }

  @override
  Future<DanmakuAutoUpdateBlock?> blockFor(String key) async {
    final entry = _read()[key];
    if (entry is! Map) return null;
    final at = entry['at'];
    if (at is! int) return null;
    return DanmakuAutoUpdateBlock(
      at: DateTime.fromMillisecondsSinceEpoch(at),
      hard: entry['hard'] == true,
    );
  }

  @override
  Future<void> record(
    String key, {
    required bool hard,
    required DateTime at,
  }) async {
    final all = _read();
    all[key] = {'at': at.millisecondsSinceEpoch, 'hard': hard};
    await _prefs.setString(prefsKey, jsonEncode(all));
  }
}

/// Schedules one silent danmaku refresh per time a Bilibili video is opened.
///
/// The local sidecar stays on screen while the request runs. A changed file
/// reloads immediately only near the start or while paused; otherwise the
/// reload waits for a pause or seek, and the next open reads the new file.
class BilibiliDanmakuAutoUpdate {
  BilibiliDanmakuAutoUpdate({
    this.delay = const Duration(milliseconds: 1500),
    DateTime Function()? clock,
    Future<bool> Function()? isOnline,
    DanmakuAutoUpdateLedger? ledger,
  }) : _clock = clock ?? DateTime.now,
       _isOnline = isOnline,
       _ledgerOverride = ledger;

  static final BilibiliDanmakuAutoUpdate instance = BilibiliDanmakuAutoUpdate();

  final Duration delay;
  final DateTime Function() _clock;
  final Future<bool> Function()? _isOnline;
  final DanmakuAutoUpdateLedger? _ledgerOverride;

  final Set<String> _manualVideoIds = <String>{};
  final Set<String> _scheduledStamps = <String>{};
  final Map<String, Future<BilibiliDanmakuAutoUpdateResult>> _inFlight =
      <String, Future<BilibiliDanmakuAutoUpdateResult>>{};

  String? _pendingVideoId;
  Duration _pendingPosition = Duration.zero;
  bool _pendingPlaying = true;
  Future<DanmakuAutoUpdateLedger>? _ledgerFuture;

  void beginManual(String videoId) {
    _manualVideoIds.add(videoId);
  }

  void endManual(String videoId) {
    _manualVideoIds.remove(videoId);
  }

  /// A manual refresh already checked this part, so auto-update waits out
  /// the same success cooldown.
  Future<void> recordManualSuccess(VideoItem item) async {
    try {
      final ledger = await _resolveLedger();
      await ledger.record(
        bilibiliDanmakuAutoUpdateLedgerKey(item),
        hard: false,
        at: _clock(),
      );
    } catch (error, stack) {
      debugPrint('Danmaku manual cooldown was not saved: $error\n$stack');
    }
  }

  bool hasPendingVisual(String videoId) => _pendingVideoId == videoId;

  /// Pause or seek reveals a refresh that finished too late to swap live.
  bool consumePendingVisual({
    required String videoId,
    required Duration position,
    required bool playing,
  }) {
    if (_pendingVideoId != videoId) return false;
    final deltaMs = position.inMilliseconds - _pendingPosition.inMilliseconds;
    final jumped =
        deltaMs.abs() >= bilibiliDanmakuAutoUpdateSeekThreshold.inMilliseconds;
    final paused = _pendingPlaying && !playing;
    _pendingPosition = position;
    _pendingPlaying = playing;
    if (!paused && !jumped) return false;
    _pendingVideoId = null;
    return true;
  }

  /// [surface] plus [playbackToken] identify one open of [item]. A second
  /// call for that same open does nothing. The next open can try again when
  /// the previous attempt failed because of the network.
  Future<void> scheduleForPlayback({
    required VideoItem item,
    required Object surface,
    required int playbackToken,
    required bool enabled,
    required BilibiliDownloadService downloads,
    required LibraryService library,
    required bool Function() stillCurrent,
    required Duration Function() position,
    required bool Function() playing,
    required VoidCallback reloadVisual,
    bool Function()? playingCachedMedia,
  }) async {
    if (!enabled || !item.isBilibiliExported) return;
    final stamp = '${identityHashCode(surface)}:$playbackToken:${item.id}';
    if (!_scheduledStamps.add(stamp)) return;
    if (_manualVideoIds.contains(item.id)) {
      _scheduledStamps.remove(stamp);
      return;
    }

    try {
      await Future<void>.delayed(delay);
      if (!stillCurrent()) return;

      final ledger = await _resolveLedger();
      final key = bilibiliDanmakuAutoUpdateLedgerKey(item);
      final block = await ledger.blockFor(key);
      if (block != null && block.blocksAt(_clock())) return;
      if (!await _online()) return;

      final result = await _singleFlight(item, downloads, library,
        followLivePage: playingCachedMedia?.call() == true ? false : null,
      );
      final settledKey = bilibiliDanmakuAutoUpdateLedgerKey(item);
      if (result.checkedSuccessfully) {
        await ledger.record(settledKey, hard: false, at: _clock());
      } else if (result.hardFailure) {
        await ledger.record(settledKey, hard: true, at: _clock());
      }
      if (!stillCurrent() ||
          result.status != BilibiliDanmakuAutoUpdateStatus.updated) {
        return;
      }
      final playbackPosition = position();
      final isPlaying = playing();
      if (bilibiliDanmakuAutoUpdateApplyNow(
        position: playbackPosition,
        playing: isPlaying,
      )) {
        if (_pendingVideoId == item.id) _pendingVideoId = null;
        reloadVisual();
        return;
      }
      _pendingVideoId = item.id;
      _pendingPosition = playbackPosition;
      _pendingPlaying = isPlaying;
    } catch (error, stack) {
      debugPrint('Danmaku auto-update schedule failed: $error\n$stack');
    }
  }

  Future<BilibiliDanmakuAutoUpdateResult> _singleFlight(
    VideoItem item,
    BilibiliDownloadService downloads,
    LibraryService library, {
    bool? followLivePage,
  }) {
    final existing = _inFlight[item.id];
    if (existing != null) return existing;
    final future = followLivePage == false
        ? downloads.autoUpdateDanmakuForCachedVideo(item, library)
        : downloads.autoUpdateDanmakuForVideo(item, library);
    _inFlight[item.id] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[item.id], future)) {
        _inFlight.remove(item.id);
      }
    });
  }

  Future<DanmakuAutoUpdateLedger> _resolveLedger() {
    final override = _ledgerOverride;
    if (override != null) {
      return Future<DanmakuAutoUpdateLedger>.value(override);
    }
    return _ledgerFuture ??= SharedPreferences.getInstance().then(
      PrefsDanmakuAutoUpdateLedger.new,
    );
  }

  Future<bool> _online() async {
    final override = _isOnline;
    if (override != null) return override();
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((result) => result != ConnectivityResult.none);
    } catch (_) {
      // Unknown reachability still attempts the request; a failure stays soft.
      return true;
    }
  }
}
