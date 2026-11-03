import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../debug/developer_log.dart' as developer;
import '../settings_service.dart';

/// One video watched through the in-app Bilibili pages.
@immutable
class BilibiliWatchHistoryEntry {
  final String bvid;
  final String title;
  final String ownerName;

  /// Cover URL; empty when unknown (filled later from the public API).
  final String coverUrl;

  /// 1-based part last opened.
  final int page;

  /// Title of [page] for multi-part videos, empty otherwise.
  final String partTitle;
  final DateTime watchedAt;

  /// Playback position in [page] when last saved, in milliseconds.
  final int positionMs;

  const BilibiliWatchHistoryEntry({
    required this.bvid,
    required this.title,
    required this.watchedAt,
    this.ownerName = '',
    this.coverUrl = '',
    this.page = 1,
    this.partTitle = '',
    this.positionMs = 0,
  });

  /// Whole seconds of [positionMs].
  int get positionSeconds => positionMs ~/ 1000;

  BilibiliWatchHistoryEntry copyWith({
    String? coverUrl,
    DateTime? watchedAt,
    int? page,
    String? partTitle,
    int? positionMs,
  }) {
    return BilibiliWatchHistoryEntry(
      bvid: bvid,
      title: title,
      ownerName: ownerName,
      coverUrl: coverUrl ?? this.coverUrl,
      page: page ?? this.page,
      partTitle: partTitle ?? this.partTitle,
      watchedAt: watchedAt ?? this.watchedAt,
      positionMs: positionMs ?? this.positionMs,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'bvid': bvid,
    'title': title,
    'owner': ownerName,
    'cover': coverUrl,
    'page': page,
    'part': partTitle,
    'at': watchedAt.millisecondsSinceEpoch,
    'pos': positionMs,
  };

  static BilibiliWatchHistoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final bvid = raw['bvid'];
    final at = raw['at'];
    if (bvid is! String || bvid.isEmpty || at is! int) return null;
    String text(String key) => raw[key] is String ? raw[key] as String : '';
    final page = raw['page'];
    final position = raw['pos'];
    return BilibiliWatchHistoryEntry(
      bvid: bvid,
      title: text('title'),
      ownerName: text('owner'),
      coverUrl: text('cover'),
      page: page is int && page > 0 ? page : 1,
      partTitle: text('part'),
      watchedAt: DateTime.fromMillisecondsSinceEpoch(at),
      positionMs: position is int && position > 0 ? position : 0,
    );
  }
}

/// Fetches a cover URL for [bvid] without the login cookie; null if none.
typedef BilibiliCoverFetcher = Future<String?> Function(String bvid);

/// Search keywords and watched videos of the in-app Bilibili pages, kept in
/// SharedPreferences. Recording follows the two switches in
/// [SettingsService]; existing entries can always be removed or cleared.
class BilibiliHistoryService extends ChangeNotifier {
  BilibiliHistoryService._();

  static final BilibiliHistoryService instance = BilibiliHistoryService._();

  static const int maxSearchEntries = 12;
  static const int maxWatchEntries = 50;
  static const String searchHistoryKey = 'bilibiliSearchHistory';
  static const String watchHistoryKey = 'bilibiliWatchHistory';

  List<String> _search = const <String>[];
  List<BilibiliWatchHistoryEntry> _watch = const <BilibiliWatchHistoryEntry>[];
  Future<void>? _loading;
  final Set<String> _coverAttempted = <String>{};

  /// Newest first.
  List<String> get searchHistory => _search;

  /// Newest first.
  List<BilibiliWatchHistoryEntry> get watchHistory => _watch;

  /// Reads both lists once; later calls reuse the first read.
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _search = _cleanSearch(prefs.getStringList(searchHistoryKey));
      final raw = prefs.getString(watchHistoryKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      _watch = _cleanWatch(decoded is List ? decoded : const <Object?>[]);
      notifyListeners();
    } catch (error) {
      developer.log('Bilibili history could not be read', error: error);
    }
  }

  static List<String> _cleanSearch(List<String>? raw) {
    final result = <String>[];
    for (final value in raw ?? const <String>[]) {
      final keyword = value.trim();
      if (keyword.isEmpty || result.contains(keyword)) continue;
      result.add(keyword);
      if (result.length == maxSearchEntries) break;
    }
    return List<String>.unmodifiable(result);
  }

  static List<BilibiliWatchHistoryEntry> _cleanWatch(List<Object?> raw) {
    final seen = <String>{};
    final result = <BilibiliWatchHistoryEntry>[];
    for (final item in raw) {
      final entry = BilibiliWatchHistoryEntry.fromJson(item);
      if (entry == null || !seen.add(entry.bvid)) continue;
      result.add(entry);
      if (result.length == maxWatchEntries) break;
    }
    return List<BilibiliWatchHistoryEntry>.unmodifiable(result);
  }

  // ------------------------------------------------------------ search

  /// Records a keyword search. The keyword is trimmed; an equal keyword
  /// (exact match after trimming, case-sensitive) moves to the top.
  Future<void> addSearch(String keyword) async {
    final value = keyword.trim();
    if (value.isEmpty || !SettingsService().bilibiliRecordSearchHistory) {
      return;
    }
    await ensureLoaded();
    _search = List<String>.unmodifiable(
      <String>[
        value,
        ..._search.where((k) => k != value),
      ].take(maxSearchEntries),
    );
    notifyListeners();
    await _saveSearch();
  }

  Future<void> removeSearch(String keyword) async {
    await ensureLoaded();
    final next = _search.where((k) => k != keyword).toList();
    if (next.length == _search.length) return;
    _search = List<String>.unmodifiable(next);
    notifyListeners();
    await _saveSearch();
  }

  Future<void> clearSearch() async {
    await ensureLoaded();
    _search = const <String>[];
    notifyListeners();
    await _saveSearch();
  }

  Future<void> _saveSearch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(searchHistoryKey, _search);
    } catch (error) {
      developer.log('Bilibili search history not saved', error: error);
    }
  }

  // ------------------------------------------------------------- watch

  /// Records a watched video; the previous entry of the same BV is replaced
  /// and the newest entry comes first. An empty cover keeps a known one.
  Future<void> recordWatch(BilibiliWatchHistoryEntry entry) async {
    if (entry.bvid.isEmpty || !SettingsService().bilibiliRecordWatchHistory) {
      return;
    }
    await ensureLoaded();
    var next = entry;
    if (next.coverUrl.isEmpty) {
      for (final old in _watch) {
        if (old.bvid == entry.bvid && old.coverUrl.isNotEmpty) {
          next = next.copyWith(coverUrl: old.coverUrl);
          break;
        }
      }
    }
    _watch = List<BilibiliWatchHistoryEntry>.unmodifiable(
      <BilibiliWatchHistoryEntry>[
        next,
        ..._watch.where((e) => e.bvid != entry.bvid),
      ].take(maxWatchEntries),
    );
    notifyListeners();
    await _saveWatch();
  }

  /// The entry of [bvid], or null. Loaded entries only; call
  /// [ensureLoaded] first.
  BilibiliWatchHistoryEntry? watchEntryOf(String bvid) {
    for (final entry in _watch) {
      if (entry.bvid == bvid) return entry;
    }
    return null;
  }

  /// Saves where playback of [bvid] stands: part [page] at [positionMs]. Only
  /// an entry that already exists is updated (it is created when the video
  /// is opened) and it moves to the top. Does nothing while watch history is
  /// off.
  Future<void> recordProgress({
    required String bvid,
    required int page,
    required int positionMs,
    String? partTitle,
    DateTime? at,
  }) async {
    if (bvid.isEmpty || !SettingsService().bilibiliRecordWatchHistory) return;
    await ensureLoaded();
    final old = watchEntryOf(bvid);
    if (old == null) return;
    final position = positionMs < 0 ? 0 : positionMs;
    final samePart = old.page == page;
    final next = old.copyWith(
      page: page,
      partTitle: samePart ? old.partTitle : (partTitle ?? ''),
      positionMs: position,
      watchedAt: at ?? DateTime.now(),
    );
    _watch = List<BilibiliWatchHistoryEntry>.unmodifiable(
      <BilibiliWatchHistoryEntry>[next, ..._watch.where((e) => e.bvid != bvid)],
    );
    notifyListeners();
    await _saveWatch();
  }

  Future<void> removeWatch(String bvid) async {
    await ensureLoaded();
    final next = _watch.where((e) => e.bvid != bvid).toList();
    if (next.length == _watch.length) return;
    _watch = List<BilibiliWatchHistoryEntry>.unmodifiable(next);
    notifyListeners();
    await _saveWatch();
  }

  Future<void> clearWatch() async {
    await ensureLoaded();
    _watch = const <BilibiliWatchHistoryEntry>[];
    notifyListeners();
    await _saveWatch();
  }

  /// Looks up covers for up to [limit] entries that have none, [concurrency]
  /// at a time. Found covers are saved; failures are ignored and not retried
  /// in this session.
  Future<int> fillMissingCovers(
    BilibiliCoverFetcher fetchCover, {
    int limit = 10,
    int concurrency = 3,
  }) async {
    await ensureLoaded();
    final pending = _watch
        .where((e) => e.coverUrl.isEmpty && _coverAttempted.add(e.bvid))
        .map((e) => e.bvid)
        .take(limit)
        .toList();
    if (pending.isEmpty) return 0;
    final found = <String, String>{};
    var next = 0;
    Future<void> worker() async {
      while (next < pending.length) {
        final bvid = pending[next++];
        try {
          final url = (await fetchCover(bvid))?.trim();
          if (url != null && url.isNotEmpty) found[bvid] = url;
        } catch (_) {
          // A missing cover only keeps the placeholder.
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (var i = 0; i < concurrency.clamp(1, pending.length); i++) worker(),
    ]);
    if (found.isEmpty) return 0;
    _watch = List<BilibiliWatchHistoryEntry>.unmodifiable(
      <BilibiliWatchHistoryEntry>[
        for (final entry in _watch)
          found[entry.bvid] != null && entry.coverUrl.isEmpty
              ? entry.copyWith(coverUrl: found[entry.bvid])
              : entry,
      ],
    );
    notifyListeners();
    await _saveWatch();
    return found.length;
  }

  Future<void> _saveWatch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        watchHistoryKey,
        jsonEncode(_watch.map((e) => e.toJson()).toList()),
      );
    } catch (error) {
      developer.log('Bilibili watch history not saved', error: error);
    }
  }

  @visibleForTesting
  void resetForTest() {
    _search = const <String>[];
    _watch = const <BilibiliWatchHistoryEntry>[];
    _loading = null;
    _coverAttempted.clear();
  }
}
