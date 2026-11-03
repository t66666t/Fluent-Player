import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_browse_models.dart';
import '../../models/bilibili_models.dart';

/// What the Bilibili panel can still show about a video without a network:
/// title, uploader and description, as last seen online.
@immutable
class BilibiliOfflineDetail {
  const BilibiliOfflineDetail({
    required this.bvid,
    this.title = '',
    this.ownerName = '',
    this.ownerMid = 0,
    this.description = '',
  });

  final String bvid;
  final String title;
  final String ownerName;
  final int ownerMid;
  final String description;

  Map<String, Object?> toJson(int seenAt) => <String, Object?>{
    't': title,
    'o': ownerName,
    'm': ownerMid,
    'd': description,
    'at': seenAt,
  };

  static BilibiliOfflineDetail? fromJson(String bvid, Object? raw) {
    if (raw is! Map) return null;
    String text(String key) => (raw[key] ?? '').toString();
    final mid = raw['m'];
    return BilibiliOfflineDetail(
      bvid: bvid,
      title: text('t'),
      ownerName: text('o'),
      ownerMid: mid is num ? mid.toInt() : int.tryParse('${mid ?? ''}') ?? 0,
      description: text('d'),
    );
  }
}

/// Title, uploader and description of the Bilibili videos seen online (the
/// panel's detail, the info a download or a watch fetched), kept in
/// SharedPreferences so the panel of a downloaded video still has them
/// offline. Holds the [capacity] most recently seen videos; nothing about
/// the account is kept.
class BilibiliOfflineDetails {
  BilibiliOfflineDetails({this.capacity = 300});

  static final BilibiliOfflineDetails instance = BilibiliOfflineDetails();

  static const String prefsKey = 'bilibiliOfflineDetails';

  /// Descriptions are cut to this length.
  static const int maxDescriptionLength = 2000;

  final int capacity;

  Map<String, Map<String, Object?>>? _entries;
  Future<void>? _loading;
  Future<void> _saving = Future<void>.value();

  Future<void> _ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    final entries = <String, Map<String, Object?>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          final value = entry.value;
          if (value is Map) {
            entries['${entry.key}'] = Map<String, Object?>.from(value);
          }
        }
      }
    } catch (error) {
      developer.log('Offline Bilibili details not read', error: error);
    }
    _entries = entries;
  }

  /// What was last seen of [bvid], or null.
  Future<BilibiliOfflineDetail?> lookup(String bvid) async {
    await _ensureLoaded();
    return BilibiliOfflineDetail.fromJson(bvid, _entries![bvid]);
  }

  Future<void> rememberDetail(BilibiliVideoDetail detail) => remember(
    BilibiliOfflineDetail(
      bvid: detail.bvid,
      title: detail.title,
      ownerName: detail.owner.name,
      ownerMid: detail.owner.mid,
      description: detail.description,
    ),
  );

  Future<void> rememberInfo(BilibiliVideoInfo info) => remember(
    BilibiliOfflineDetail(
      bvid: info.bvid,
      title: info.title,
      ownerName: info.ownerName,
      ownerMid: int.tryParse(info.ownerMid) ?? 0,
      description: info.desc,
    ),
  );

  /// Keeps [detail] (best effort; failures are only logged).
  Future<void> remember(BilibiliOfflineDetail detail) async {
    final bvid = detail.bvid.trim();
    if (bvid.isEmpty || detail.title.trim().isEmpty) return;
    await _ensureLoaded();
    final entries = _entries!;
    final description = detail.description.length > maxDescriptionLength
        ? detail.description.substring(0, maxDescriptionLength)
        : detail.description;
    entries.remove(bvid);
    entries[bvid] = BilibiliOfflineDetail(
      bvid: bvid,
      title: detail.title,
      ownerName: detail.ownerName,
      ownerMid: detail.ownerMid,
      description: description,
    ).toJson(DateTime.now().millisecondsSinceEpoch);
    while (entries.length > capacity) {
      entries.remove(entries.keys.first);
    }
    final snapshot = jsonEncode(entries);
    _saving = _saving.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsKey, snapshot);
      } catch (error) {
        developer.log('Offline Bilibili details not saved', error: error);
      }
    });
    await _saving;
  }

  @visibleForTesting
  void resetForTest() {
    _entries = null;
    _loading = null;
  }
}
