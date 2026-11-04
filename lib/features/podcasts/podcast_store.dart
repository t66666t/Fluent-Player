import '../../services/app_storage_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'podcast_models.dart';
import 'podcast_settings.dart';

/// What an import kept, plus anything the user should see in the existing status line.
class PodcastImportResult {
  const PodcastImportResult({this.notices = const []});
  final List<String> notices;
}

class PodcastManualOrder {
  const PodcastManualOrder({
    required this.ids,
    required this.revision,
    required this.updatedClock,
  });
  final List<String> ids;
  final int revision;
  final int updatedClock;
}

class PodcastStore {
  static const int schemaVersion = 2;
  PodcastStore(this.database, {this.path = ':memory:'}) {
    final current =
        database.select('PRAGMA user_version').first.values.first as int;
    if (current > schemaVersion) {
      throw const FormatException('播客数据库来自更新版本，请更新应用后再打开');
    }
    database.execute('PRAGMA journal_mode=WAL');
    database.execute('PRAGMA busy_timeout=5000');
    database.execute(
      'CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, id TEXT NOT NULL, channel TEXT NOT NULL DEFAULT \'\', payload TEXT NOT NULL, PRIMARY KEY(kind,id))',
    );
    database.execute(
      'CREATE INDEX IF NOT EXISTS records_channel ON records(kind,channel)',
    );
    // Version 0 is a new file. Only an existing catalog gets a restorable copy.
    if (current >= 1 && current < schemaVersion && path != ':memory:') {
      _backupBeforeUpgrade(current);
    }
    database.execute('PRAGMA user_version=$schemaVersion');
  }

  void _backupBeforeUpgrade(int fromVersion) {
    database.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final backup = File('$path.v$fromVersion.bak');
    if (backup.existsSync()) return;
    final escaped = backup.path.replaceAll("'", "''");
    database.execute("VACUUM INTO '$escaped'");
  }

  factory PodcastStore.open(String path) {
    File(path).parent.createSync(recursive: true);
    final database = sqlite3.open(path);
    try {
      return PodcastStore(database, path: path);
    } catch (_) {
      database.dispose();
      rethrow;
    }
  }
  final Database database;
  final String path;
  final _episodeCache = <String, List<PodcastEpisode>>{};
  final _parsedEpisodes = <String, PodcastEpisode>{};

  /// Counts catalog SQL projections so a progress tick can be shown not to
  /// rescan the catalog.
  int catalogQueries = 0;

  /// Changes when channel-query membership can change: listen bucket, favorite,
  /// or hidden. Progress that stays inside one bucket does not bump it.
  int catalogRevision = 0;
  void close() => database.dispose();

  /// Local discovery history is kept apart from subscriptions and sync data.
  List<String> get searchHistory =>
      (read('localSearch', 'history')?['queries'] as List? ?? const [])
          .whereType<String>()
          .toList();

  void rememberSearch(String query) {
    final value = query.trim();
    if (value.isEmpty) return;
    final values = searchHistory
      ..removeWhere((entry) => entry.toLowerCase() == value.toLowerCase())
      ..insert(0, value);
    write('localSearch', 'history', {'queries': values.take(12).toList()});
  }

  void removeSearch(String query) {
    write('localSearch', 'history', {'queries': searchHistory..remove(query)});
  }

  void clearSearchHistory() => remove('localSearch', 'history');

  Map<String, dynamic>? read(String kind, String id) {
    final rows = database.select(
      'SELECT payload FROM records WHERE kind=? AND id=?',
      [kind, id],
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(
            AppStorageService.instance.decodePaths(
              jsonDecode(rows.first['payload'] as String),
            ),
          );
  }

  List<Map<String, dynamic>> list(String kind, {String? channel}) => database
      .select(
        'SELECT payload FROM records WHERE kind=?${channel == null ? '' : ' AND channel=?'}',
        [kind, ?channel],
      )
      .map(
        (r) => Map<String, dynamic>.from(
          AppStorageService.instance.decodePaths(
            jsonDecode(r['payload'] as String),
          ),
        ),
      )
      .toList();
  void write(
    String kind,
    String id,
    Map<String, dynamic> value, {
    String channel = '',
  }) {
    if (kind == 'episode') {
      _episodeCache.remove(channel);
      _episodeCache.remove('*');
      _parsedEpisodes.remove(id);
    }
    database.execute(
      'INSERT INTO records(kind,id,channel,payload) VALUES(?,?,?,?) ON CONFLICT(kind,id) DO UPDATE SET channel=excluded.channel,payload=excluded.payload',
      [
        kind,
        id,
        channel,
        jsonEncode(AppStorageService.instance.encodePaths(value)),
      ],
    );
  }

  void remove(String kind, String id) {
    if (kind == 'episode') {
      _episodeCache.clear();
      _parsedEpisodes.remove(id);
    }
    database.execute('DELETE FROM records WHERE kind=? AND id=?', [kind, id]);
  }

  T transaction<T>(T Function() body) {
    database.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      database.execute('COMMIT');
      return result;
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  List<PodcastChannel> get channels =>
      list('channel').map(PodcastChannel.fromJson).toList();
  PodcastChannel? channel(String id) {
    final value = read('channel', id);
    return value == null ? null : PodcastChannel.fromJson(value);
  }

  List<PodcastEpisode> episodes([String? id]) {
    final key = id ?? '*';
    final cached = _episodeCache.remove(key);
    final values =
        cached ??
        (list('episode', channel: id).map(PodcastEpisode.fromJson).toList()
          ..sort((a, b) => b.publishedMs.compareTo(a.publishedMs)));
    _episodeCache[key] = values;
    if (_episodeCache.length > 8) {
      _episodeCache.remove(_episodeCache.keys.first);
    }
    return List<PodcastEpisode>.of(values);
  }

  int countEpisodes(String channelId, {int? newSince, bool unplayed = false}) =>
      database.select(
            "SELECT COUNT(*) AS n FROM records e WHERE e.kind='episode' AND e.channel=? ${newSince == null ? '' : "AND json_extract(e.payload,'\$.discoveredMs')>?"} ${unplayed ? "AND NOT EXISTS(SELECT 1 FROM records s WHERE s.kind='state' AND s.id=e.id AND json_extract(s.payload,'\$.played')=1)" : ''}",
            [channelId, ?newSince],
          ).first['n']
          as int;
  List<PodcastEpisode> view(String category) {
    final condition = switch (category) {
      'favorites' =>
        "EXISTS(SELECT 1 FROM records s WHERE s.kind='state' AND s.id=e.id AND json_extract(s.payload,'\$.favorite')=1)",
      'continue' =>
        "EXISTS(SELECT 1 FROM records s WHERE s.kind='state' AND s.id=e.id AND json_extract(s.payload,'\$.positionMs')>0 AND json_extract(s.payload,'\$.played')!=1)",
      'new' =>
        "EXISTS(SELECT 1 FROM records c WHERE c.kind='channel' AND c.id=e.channel AND json_extract(c.payload,'\$.active')=1 AND json_extract(e.payload,'\$.discoveredMs')>json_extract(c.payload,'\$.seenMs'))",
      _ => '1=1',
    };
    return database
        .select(
          "SELECT e.payload FROM records e WHERE e.kind='episode' AND $condition ORDER BY json_extract(e.payload,'\$.publishedMs') DESC",
        )
        .map(
          (r) => PodcastEpisode.fromJson(
            Map<String, dynamic>.from(
              AppStorageService.instance.decodePaths(
                jsonDecode(r['payload'] as String),
              ),
            ),
          ),
        )
        .toList();
  }

  void invalidateCatalogCache() {
    _episodeCache.clear();
    _parsedEpisodes.clear();
  }

  PodcastEpisode? episode(String id) {
    final cached = _parsedEpisodes.remove(id);
    if (cached != null) {
      _parsedEpisodes[id] = cached;
      return cached;
    }
    final value = read('episode', id);
    if (value == null) return null;
    final parsed = PodcastEpisode.fromJson(value);
    _parsedEpisodes[id] = parsed;
    while (_parsedEpisodes.length > 256) {
      _parsedEpisodes.remove(_parsedEpisodes.keys.first);
    }
    return parsed;
  }

  /// The latest in-progress episode of one channel. Avoids loading every
  /// channel's continue list and filtering it in Dart.
  PodcastEpisode? continueInChannel(String channelId) {
    final rows = database.select(
      '''
      SELECT e.payload AS payload
      FROM records e
      JOIN records s ON s.kind='state' AND s.id=e.id
      WHERE e.kind='episode' AND e.channel=?
        AND COALESCE(json_extract(s.payload,'\$.positionMs'), 0) > 0
        AND COALESCE(json_extract(s.payload,'\$.played'), 0) != 1
      ORDER BY COALESCE(json_extract(s.payload,'\$.lastPlayedMs'), 0) DESC
      LIMIT 1
      ''',
      [channelId],
    );
    if (rows.isEmpty) return null;
    return PodcastEpisode.fromJson(
      Map<String, dynamic>.from(
        AppStorageService.instance.decodePaths(
          jsonDecode(rows.first['payload'] as String),
        ),
      ),
    );
  }

  PodcastEpisodeState state(String id) =>
      PodcastEpisodeState.fromJson(read('state', id) ?? {});
  void saveState(String id, PodcastEpisodeState value) {
    final previous = state(id);
    write('state', id, value.toJson());
    if (previous.listenBucket != value.listenBucket ||
        previous.favorite != value.favorite) {
      catalogRevision++;
    }
  }

  PodcastPreferences get preferences =>
      PodcastPreferences(read('settings', 'global') ?? {});
  Map<String, dynamic> overrides(String id) => read('settings', id) ?? {};
  PodcastPreferences effective(String? id) =>
      id == null ? preferences : preferences.overlay(overrides(id));
  void setSetting(String? channelId, String key, Object? value) {
    final definition = podcastSettings.firstWhere((s) => s.key == key);
    if (channelId != null && definition.deviceOnly) {
      throw ArgumentError('设备设置不能被频道覆盖');
    }
    final id = channelId ?? 'global';
    final values = read('settings', id) ?? {};
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = definition.normalize(value);
    }
    write('settings', id, values);
    write('settingClock', id, {
      'updatedMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  List<PodcastEpisode> mergeFeed(PodcastFeed feed, {bool initial = false}) {
    return transaction(() {
      final existingChannel = channel(feed.channel.id);
      final c = feed.channel;
      final prior = existingChannel == null
          ? <PodcastEpisode>[]
          : episodes(c.id);
      final byMedia = <String, PodcastEpisode>{
        for (final episode in prior)
          for (final media in episode.media)
            podcastCanonicalUrl(media.url): episode,
      };
      String? fingerprint(PodcastEpisode episode) =>
          episode.title.trim().isEmpty ||
              (episode.publishedMs <= 0 && episode.number == null)
          ? null
          : '${episode.title.trim()}|${episode.publishedMs}|${episode.season}|${episode.number}';
      final byFingerprint = <String, List<PodcastEpisode>>{};
      for (final episode in prior.where((e) => e.guid.isEmpty)) {
        final key = fingerprint(episode);
        if (key != null) byFingerprint.putIfAbsent(key, () => []).add(episode);
      }
      if (existingChannel != null) {
        c.subscribedMs = existingChannel.subscribedMs;
        c.seenMs = existingChannel.seenMs;
        c.active = existingChannel.active;
        c.aliases = {
          ...existingChannel.aliases,
          existingChannel.feedUrl,
          ...c.aliases,
        }.toList();
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      c.subscribedMs = c.subscribedMs == 0 ? now : c.subscribedMs;
      c.checkedMs = now;
      c.successMs = now;
      c.error = '';
      c.failureCount = 0;
      if (initial) c.seenMs = now;
      write('channel', c.id, c.toJson());
      final merged = <PodcastEpisode>[];
      for (final incoming in feed.episodes) {
        var episode = incoming;
        var old = this.episode(episode.id);
        if (old == null) {
          final mediaMatch = episode.media
              .map((m) => byMedia[podcastCanonicalUrl(m.url)])
              .whereType<PodcastEpisode>()
              .where((e) => e.guid.isEmpty || episode.guid.isEmpty)
              .firstOrNull;
          final candidates = episode.guid.isEmpty
              ? byFingerprint[fingerprint(episode)]
              : null;
          old =
              mediaMatch ??
              (candidates?.length == 1 ? candidates!.single : null);
          if (old != null) {
            episode = PodcastEpisode.fromJson({
              ...episode.toJson(),
              'id': old.id,
              if (episode.guid.isEmpty) 'guid': old.guid,
            });
          }
        }
        final payload = episode.toJson();
        if (old != null) payload['discoveredMs'] = old.discoveredMs;
        write('episode', episode.id, payload, channel: c.id);
        merged.add(PodcastEpisode.fromJson(payload));
      }
      final newest = merged.toList()
        ..sort((a, b) {
          final byDate = b.publishedMs.compareTo(a.publishedMs);
          return byDate != 0 ? byDate : a.id.compareTo(b.id);
        });
      // New episodes land at the head. Existing manual positions stay put,
      // including episodes the latest feed no longer mentions.
      reconcileManualOrder(c.id, newest.map((episode) => episode.id).toList());
      return merged;
    });
  }

  Map<String, dynamic> exportChannel(String id, {int? payloadVersion}) {
    final version = payloadVersion ?? 2;
    final sharedSettings = overrides(id)
      ..removeWhere(
        (key, _) => !podcastSettings.any((s) => s.key == key && !s.deviceOnly),
      );
    final globalRaw = read('settings', 'global') ?? {};
    final presentations = <String, Map<String, dynamic>>{};
    for (final episode in episodes(id)) {
      final presentation = read('episodeUserPresentation', episode.id);
      if (presentation != null && presentation.isNotEmpty) {
        presentations[episode.id] = presentation;
      }
    }
    return {
      // Version 2 carries explicit overrides only. Filled-in defaults are not
      // frozen into the file, or a later "follow the app" switch could never win.
      'version': version,
      'inheritanceVersion': 1,
      'channel': channel(id)!.toJson()
        ..remove('etag')
        ..remove('lastModified'),
      'episodes': episodes(id).map((e) => e.toJson()).toList(),
      'states': {for (final e in episodes(id)) e.id: state(e.id).toJson()},
      'settings': sharedSettings,
      'settingsUpdatedMs': read('settingClock', id)?['updatedMs'] ?? 0,
      'globalSettings': {
        for (final entry in globalRaw.entries)
          if (podcastSettings.any(
            (definition) =>
                definition.key == entry.key && !definition.deviceOnly,
          ))
            entry.key: entry.value,
      },
      'globalSettingsUpdatedMs':
          read('settingClock', 'global')?['updatedMs'] ?? 0,
      if (version >= 2) 'manualOrder': _orderJson(id),
      if (version >= 2) 'presentations': presentations,
    };
  }

  PodcastImportResult importChannel(
    Map<String, dynamic> data, {
    bool synchronization = false,
  }) {
    final version = data['version'];
    if (version != 1 && version != 2) {
      throw const FormatException('播客数据版本不受支持');
    }
    final notices = <String>[];
    transaction(() {
      final c = PodcastChannel.fromJson(
        Map<String, dynamic>.from(data['channel']),
      );
      if (!RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(c.id) ||
          !['http', 'https'].contains(Uri.tryParse(c.feedUrl)?.scheme)) {
        throw const FormatException('播客频道身份或订阅地址无效');
      }
      final old = channel(c.id);
      if (old == null) write('channel', c.id, c.toJson());
      for (final raw in data['episodes'] as List? ?? []) {
        final e = PodcastEpisode.fromJson(Map<String, dynamic>.from(raw));
        if (!RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(e.id) ||
            e.media.any(
              (m) => !['http', 'https'].contains(Uri.tryParse(m.url)?.scheme),
            )) {
          throw const FormatException('播客节目身份或媒体地址无效');
        }
        if (e.channelId != c.id || e.media.isEmpty) continue;
        if (episode(e.id) == null) {
          write('episode', e.id, e.toJson(), channel: c.id);
        }
      }
      for (final entry in Map<String, dynamic>.from(
        data['states'] ?? {},
      ).entries) {
        final remote = PodcastEpisodeState.fromJson(
          Map<String, dynamic>.from(entry.value),
        );
        final local = state(entry.key);
        if (synchronization) {
          if (remote.favoriteUpdatedMs > local.favoriteUpdatedMs) {
            local.favorite = remote.favorite;
            local.favoriteUpdatedMs = remote.favoriteUpdatedMs;
            saveState(entry.key, local);
          }
        } else if (remote.updatedMs > local.updatedMs) {
          saveState(entry.key, remote);
        }
      }
      final settings = Map<String, dynamic>.from(data['settings'] ?? {});
      _importExplicitSettings(
        scopeId: c.id,
        incoming: settings,
        updatedMs: (data['settingsUpdatedMs'] as num? ?? 0).toInt(),
        replace: version == 2,
        notices: notices,
        strict: false,
      );
      _importExplicitSettings(
        scopeId: 'global',
        incoming: Map<String, dynamic>.from(data['globalSettings'] ?? {}),
        updatedMs: (data['globalSettingsUpdatedMs'] as num? ?? 0).toInt(),
        replace: version == 2,
        notices: notices,
        strict: true,
        // A version 1 backup stored every effective value. Keep those keys as
        // explicit overrides and say so, instead of writing them into the app
        // settings or pretending the user chose to follow the app.
        legacyFilled: version == 1,
      );
      if (version == 2 && data['manualOrder'] is Map) {
        _importManualOrder(
          c.id,
          Map<String, dynamic>.from(data['manualOrder'] as Map),
          notices,
        );
      }
      if (data['presentations'] is Map) {
        for (final entry in Map<String, dynamic>.from(
          data['presentations'] as Map,
        ).entries) {
          _importPresentation(
            entry.key,
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
    });
    return PodcastImportResult(notices: notices);
  }

  void _importExplicitSettings({
    required String scopeId,
    required Map<String, dynamic> incoming,
    required int updatedMs,
    required bool replace,
    required List<String> notices,
    required bool strict,
    bool legacyFilled = false,
  }) {
    final localClock =
        (read('settingClock', scopeId)?['updatedMs'] as num? ?? 0).toInt();
    final newer = strict ? updatedMs > localClock : updatedMs >= localClock;
    if (!newer) return;
    final explicit = <String, dynamic>{
      for (final definition in podcastSettings.where(
        (definition) =>
            !definition.deviceOnly && incoming.containsKey(definition.key),
      ))
        definition.key: definition.normalize(incoming[definition.key]),
    };
    if (replace) {
      write('settings', scopeId, explicit);
    } else if (explicit.isNotEmpty) {
      final merged = read('settings', scopeId) ?? {};
      merged.addAll(explicit);
      write('settings', scopeId, merged);
    }
    if (updatedMs > 0 || explicit.isNotEmpty) {
      write('settingClock', scopeId, {'updatedMs': updatedMs});
    }
    const notice = '已保留旧版独立设置，可恢复跟随软件';
    if (legacyFilled &&
        explicit.keys.any((key) => key == 'continuous' || key == 'speed') &&
        !notices.contains(notice)) {
      notices.add(notice);
    }
  }

  Map<String, dynamic> _orderJson(String channelId) {
    final order = manualOrder(channelId);
    return {
      'orderedEpisodeIds': order.ids,
      'revision': order.revision,
      'updatedClock': order.updatedClock,
    };
  }

  PodcastManualOrder manualOrder(String channelId) {
    final raw = read('manualOrder', 'channel:$channelId');
    if (raw == null) {
      return const PodcastManualOrder(ids: [], revision: 0, updatedClock: 0);
    }
    return PodcastManualOrder(
      ids: (raw['orderedEpisodeIds'] as List? ?? [])
          .map((id) => '$id')
          .toList(),
      revision: (raw['revision'] as num? ?? 0).toInt(),
      updatedClock: (raw['updatedClock'] as num? ?? 0).toInt(),
    );
  }

  /// Keeps the relative order of episodes we already placed. Episodes seen for
  /// the first time are inserted at the head in newest-first order.
  void reconcileManualOrder(String channelId, List<String> newestFirstIds) {
    final current = manualOrder(channelId);
    if (current.revision == 0 && current.ids.isEmpty) {
      _writeOrder(channelId, _dedupe(newestFirstIds), 1, current.updatedClock);
      return;
    }
    final known = current.ids.toSet();
    final fresh = newestFirstIds.where((id) => !known.contains(id));
    final next = _dedupe([...fresh, ...current.ids]);
    if (_sameIds(next, current.ids)) return;
    _writeOrder(
      channelId,
      next,
      current.revision + 1,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Moves [movingIds] as one block to sit immediately before [beforeId].
  /// A stale [expectedRevision] cancels the move and leaves the saved order.
  bool moveManual({
    required String channelId,
    required List<String> movingIds,
    required int expectedRevision,
    String? beforeId,
  }) {
    final current = manualOrder(channelId);
    if (current.revision != expectedRevision) return false;
    final block = _dedupe(movingIds);
    if (block.isEmpty) return false;
    if (beforeId != null && block.contains(beforeId)) return false;
    final remaining = current.ids.where((id) => !block.contains(id)).toList();
    if (beforeId != null &&
        !remaining.contains(beforeId) &&
        !current.ids.contains(beforeId)) {
      return false;
    }
    final index = beforeId == null
        ? remaining.length
        : remaining.indexOf(beforeId);
    if (beforeId != null && index < 0) return false;
    remaining.insertAll(index, block);
    _writeOrder(
      channelId,
      _dedupe(remaining),
      current.revision + 1,
      DateTime.now().millisecondsSinceEpoch,
    );
    return true;
  }

  void _importManualOrder(
    String channelId,
    Map<String, dynamic> raw,
    List<String> notices,
  ) {
    final remoteIds = _dedupe(
      (raw['orderedEpisodeIds'] as List? ?? []).map((id) => '$id'),
    );
    final remoteClock = (raw['updatedClock'] as num? ?? 0).toInt();
    final local = manualOrder(channelId);
    if (remoteClock > local.updatedClock) {
      _writeOrder(channelId, remoteIds, local.revision + 1, remoteClock);
      return;
    }
    if (remoteClock == local.updatedClock &&
        remoteClock != 0 &&
        !_sameIds(remoteIds, local.ids)) {
      write('manualOrderConflict', 'channel:$channelId', {
        'local': local.ids,
        'remote': remoteIds,
        'updatedClock': remoteClock,
      });
      notices.add('频道顺序存在冲突，已保留两份版本');
    }
  }

  void _writeOrder(
    String channelId,
    List<String> ids,
    int revision,
    int clock,
  ) {
    write('manualOrder', 'channel:$channelId', {
      'orderedEpisodeIds': ids,
      'revision': revision,
      'updatedClock': clock,
    });
  }

  List<String> _dedupe(Iterable<String> ids) {
    final seen = <String>{};
    final result = <String>[];
    for (final id in ids) {
      if (id.isEmpty || !seen.add(id)) continue;
      result.add(id);
    }
    return result;
  }

  bool _sameIds(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> presentation(String episodeId) =>
      read('episodeUserPresentation', episodeId) ?? {};

  void setPresentation(String episodeId, {String? localTitle, bool? hidden}) {
    final current = presentation(episodeId);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (localTitle != null) {
      if (current['localTitle'] != localTitle) catalogRevision++;
      current['localTitle'] = localTitle;
      current['titleClock'] = now;
    }
    if (hidden != null) {
      final wasHidden = current['hidden'] == true;
      current['hidden'] = hidden;
      current['hiddenClock'] = now;
      if (wasHidden != hidden) catalogRevision++;
    }
    write('episodeUserPresentation', episodeId, current);
  }

  void _importPresentation(String episodeId, Map<String, dynamic> remote) {
    final local = presentation(episodeId);
    final previousTitle = local['localTitle'];
    if ((remote['titleClock'] as num? ?? 0) >
        (local['titleClock'] as num? ?? 0)) {
      local['localTitle'] = remote['localTitle'] ?? '';
      local['titleClock'] = remote['titleClock'];
    }
    final wasHidden = local['hidden'] == true;
    if ((remote['hiddenClock'] as num? ?? 0) >
        (local['hiddenClock'] as num? ?? 0)) {
      local['hidden'] = remote['hidden'] == true;
      local['hiddenClock'] = remote['hiddenClock'];
    }
    if (local.isNotEmpty) {
      write('episodeUserPresentation', episodeId, local);
      if (wasHidden != (local['hidden'] == true) ||
          previousTitle != local['localTitle']) {
        catalogRevision++;
      }
    }
  }

  /// Ids for the current channel query. Does not create media-library records.
  List<String> queryEpisodeIds({
    required String channelId,
    String filter = 'all',
    String query = '',
    String sort = 'newest',
    bool hidePlayed = false,
    Set<String> downloaded = const {},
  }) {
    return _episodeIdsForRows(
      _readEpisodeQueryRows(channelId),
      channelId: channelId,
      filter: filter,
      query: query,
      sort: sort,
      hidePlayed: hidePlayed,
      downloaded: downloaded,
    );
  }

  /// One stable projection supplies both filter counts and the visible ids.
  /// Keep the existing joins/fields and membership rules; avoid repeating the
  /// database scan and sorting every category just to obtain its length.
  List<Row> _readEpisodeQueryRows(String channelId) {
    catalogQueries++;
    final rows = database.select(
      '''
      SELECT e.id AS id,
             COALESCE(json_extract(e.payload,'\$.publishedMs'), 0) AS published,
             COALESCE(json_extract(e.payload,'\$.title'), '') AS title,
             COALESCE(json_extract(p.payload,'\$.localTitle'), '') AS localTitle,
             COALESCE(json_extract(e.payload,'\$.description'), '') AS description,
             COALESCE(json_extract(s.payload,'\$.played'), 0) AS played,
             COALESCE(json_extract(s.payload,'\$.positionMs'), 0) AS positionMs,
             COALESCE(json_extract(s.payload,'\$.favorite'), 0) AS favorite,
             COALESCE(json_extract(p.payload,'\$.hidden'), 0) AS hidden
      FROM records e
      LEFT JOIN records s ON s.kind='state' AND s.id=e.id
      LEFT JOIN records p ON p.kind='episodeUserPresentation' AND p.id=e.id
      WHERE e.kind='episode' AND e.channel=?
      ''',
      [channelId],
    );
    return rows.toList(growable: false);
  }

  Iterable<Row> _matchingEpisodeRows(
    List<Row> rows, {
    String filter = 'all',
    String query = '',
    bool hidePlayed = false,
    Set<String> downloaded = const {},
  }) sync* {
    final needle = query.trim().toLowerCase();
    for (final row in rows) {
      final id = row['id'] as String;
      final played = row['played'] == 1 || row['played'] == true;
      final positionMs = (row['positionMs'] as num?)?.toInt() ?? 0;
      final favorite = row['favorite'] == 1 || row['favorite'] == true;
      final hidden = row['hidden'] == 1 || row['hidden'] == true;
      if (filter == 'hidden') {
        if (!hidden) continue;
      } else if (hidden) {
        continue;
      }
      if (hidePlayed && played && filter != 'played') continue;
      // Unheard means never started. A resume point is its own bucket and
      // does not count as heard until playback completes or the user marks it.
      final matches = switch (filter) {
        'unplayed' => !played && positionMs <= 0,
        'inProgress' => !played && positionMs > 0,
        'played' => played,
        'favorite' => favorite,
        'downloaded' => downloaded.contains(id),
        _ => true,
      };
      if (!matches) continue;
      if (needle.isNotEmpty) {
        final haystack =
            '${row['title']} ${row['localTitle']} ${row['description']}'
                .toLowerCase();
        if (!haystack.contains(needle)) continue;
      }
      yield row;
    }
  }

  List<String> _episodeIdsForRows(
    List<Row> rows, {
    required String channelId,
    String filter = 'all',
    String query = '',
    String sort = 'newest',
    bool hidePlayed = false,
    Set<String> downloaded = const {},
  }) {
    final visible = [
      for (final row in _matchingEpisodeRows(
        rows,
        filter: filter,
        query: query,
        hidePlayed: hidePlayed,
        downloaded: downloaded,
      ))
        (
          id: row['id'] as String,
          published: (row['published'] as num?)?.toInt() ?? 0,
        ),
    ];
    if (sort == 'manual') {
      final order = manualOrder(channelId);
      final rank = <String, int>{
        for (var i = 0; i < order.ids.length; i++) order.ids[i]: i,
      };
      visible.sort((a, b) {
        final left = rank[a.id] ?? 1 << 30;
        final right = rank[b.id] ?? 1 << 30;
        if (left != right) return left.compareTo(right);
        return a.id.compareTo(b.id);
      });
    } else {
      visible.sort((a, b) {
        final byDate = sort == 'oldest'
            ? a.published.compareTo(b.published)
            : b.published.compareTo(a.published);
        return byDate != 0 ? byDate : a.id.compareTo(b.id);
      });
    }
    return visible.map((row) => row.id).toList(growable: false);
  }

  List<String> overviewOrder() {
    final raw = read('viewState', 'podcast-overview');
    return (raw?['orderedChannelIds'] as List? ?? [])
        .map((id) => '$id')
        .toList();
  }

  /// Subscription overview order. This does not move a channel card's folder.
  void setOverviewOrder(List<String> channelIds) {
    write('viewState', 'podcast-overview', {
      ...?read('viewState', 'podcast-overview'),
      'orderedChannelIds': _dedupe(channelIds),
      'updatedClock': DateTime.now().millisecondsSinceEpoch,
    });
  }
}

/// Channel directory kept outside the widget build. Progress ticks that do
/// not change this key must not scan the catalog again.
class PodcastCatalogSnapshot {
  String? key;
  List<String> ids = const [];
  List<PodcastEpisode> episodes = const [];
  Map<String, int> counts = const {};
  PodcastEpisode? continuing;
  int resolutions = 0;

  void resolve({
    required PodcastStore store,
    required String channelId,
    required String filter,
    required String query,
    required String sort,
    required bool hidePlayed,
    required Set<String> downloaded,
    required Iterable<String> countFilters,
  }) {
    final downloadKey = (downloaded.toList()..sort()).join(',');
    // Revision moves a row between buckets without treating every progress
    // tick as a new query.
    final nextKey =
        '$channelId|$filter|$query|$sort|$hidePlayed|$downloadKey|${store.catalogRevision}';
    if (nextKey == key) return;
    key = nextKey;
    resolutions++;
    final rows = store._readEpisodeQueryRows(channelId);
    counts = {
      for (final name in countFilters)
        name: store
            ._matchingEpisodeRows(
              rows,
              filter: name,
              hidePlayed: hidePlayed && name == 'all',
              downloaded: downloaded,
            )
            .length,
    };
    ids = store._episodeIdsForRows(
      rows,
      channelId: channelId,
      filter: filter,
      query: query,
      sort: sort,
      hidePlayed: hidePlayed,
      downloaded: downloaded,
    );
    episodes = [for (final id in ids) ?store.episode(id)];
    continuing = store.continueInChannel(channelId);
  }
}

/// Coalesces channel search. An empty string applies immediately and drops
/// any older keystroke that has not fired yet.
class PodcastSearchDebounce {
  PodcastSearchDebounce({this.wait = const Duration(milliseconds: 200)});

  final Duration wait;
  Timer? _timer;
  int _generation = 0;

  void submit(String value, void Function(String applied) apply) {
    _timer?.cancel();
    final generation = ++_generation;
    if (value.isEmpty) {
      apply('');
      return;
    }
    _timer = Timer(wait, () {
      if (generation == _generation) apply(value);
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
