import 'dart:async';
import 'dart:collection';

import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';

/// Video details the playback page's Bilibili panel shows, kept in memory so
/// reopening the panel or coming back to a video does not ask again.
///
/// Requests for the same BV id that overlap share one request. Only answers
/// are kept, never failures, and at most [capacity] of them (the least
/// recently used goes first). A request that takes longer than [timeout]
/// fails, so the panel never waits forever.
class BilibiliVideoDetailCache {
  BilibiliVideoDetailCache({
    required Future<BilibiliVideoDetail> Function(String bvid) fetch,
    this.capacity = 24,
    this.timeout = const Duration(seconds: 20),
  }) : assert(capacity > 0),
       _fetch = fetch;

  static BilibiliPublicApiService? _publicApi;

  /// The app-wide cache, asking the cookieless public API.
  static final BilibiliVideoDetailCache instance = BilibiliVideoDetailCache(
    fetch: (bvid) => (_publicApi ??= BilibiliPublicApiService())
        .fetchVideoDetail(bvid: bvid),
  );

  final Future<BilibiliVideoDetail> Function(String bvid) _fetch;
  final int capacity;
  final Duration timeout;

  final LinkedHashMap<String, BilibiliVideoDetail> _details =
      LinkedHashMap<String, BilibiliVideoDetail>();
  final Map<String, Future<BilibiliVideoDetail>> _pending =
      <String, Future<BilibiliVideoDetail>>{};

  /// The kept detail of [bvid], without asking.
  BilibiliVideoDetail? peek(String bvid) => _details[bvid];

  int get length => _details.length;

  /// The detail of [bvid]: the kept one, the request already running, or a
  /// new request.
  Future<BilibiliVideoDetail> get(String bvid) {
    final kept = _details.remove(bvid);
    if (kept != null) {
      _details[bvid] = kept;
      return Future<BilibiliVideoDetail>.value(kept);
    }
    final running = _pending[bvid];
    if (running != null) return running;
    late final Future<BilibiliVideoDetail> request;
    request = _load(bvid).whenComplete(() {
      if (identical(_pending[bvid], request)) _pending.remove(bvid);
    });
    _pending[bvid] = request;
    return request;
  }

  Future<BilibiliVideoDetail> _load(String bvid) async {
    final detail = await _fetch(bvid).timeout(timeout);
    _details.remove(bvid);
    _details[bvid] = detail;
    while (_details.length > capacity) {
      _details.remove(_details.keys.first);
    }
    return detail;
  }

  /// Forgets [bvid], or everything when null.
  void evict([String? bvid]) {
    if (bvid == null) {
      _details.clear();
    } else {
      _details.remove(bvid);
    }
  }
}
