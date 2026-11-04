import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subtitle_search_models.dart';
import 'subtitle_search_service.dart';
import 'subtitle_release_info.dart';

abstract interface class SubtitleSearchSecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class PlatformSubtitleSearchSecretStorage
    implements SubtitleSearchSecretStorage {
  final _storage = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

/// Navigation-independent, bounded workspace. Opening a route attaches to an
/// existing session, including its outstanding request, rather than refetching.
class SubtitleSearchWorkspace extends ChangeNotifier {
  SubtitleSearchWorkspace({
    SubtitleSearchService? service,
    SubtitleSearchSecretStorage? secrets,
  }) : service = service ?? SubtitleSearchService(),
       _secrets = secrets ?? PlatformSubtitleSearchSecretStorage();
  static final instance = SubtitleSearchWorkspace();
  final SubtitleSearchService service;
  final SubtitleSearchSecretStorage _secrets;
  final Map<SubtitleSearchSource, SubtitleSearchCredentials> credentials = {};
  final Map<SubtitleSearchSource, String> connectionErrors = {};
  final _sessions = <String, SubtitleSearchSession>{};
  final _documents = <String, List<SubtitleSearchDocument>>{};
  final _files = <String, List<SubtitleSearchFile>>{};
  final _pendingFiles = <String, Future<List<SubtitleSearchFile>>>{};
  SharedPreferences? _prefs;
  Future<void>? _initializing;
  bool ready = false;
  List<String> recent = [];
  int _credentialRevision = 0;
  int get credentialRevision => _credentialRevision;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    await Future.wait([
      () async {
        try {
          _prefs = await SharedPreferences.getInstance();
          recent = _prefs!.getStringList('subtitle_search_recent_v1') ?? [];
        } catch (_) {
          /* Session state still survives navigation. */
        }
      }(),
      ...SubtitleSearchSource.values.map((source) async {
        if (!source.requiresKey) return;
        try {
          final raw = await _secrets
              .read('subtitle_search_${source.name}_v1')
              .timeout(const Duration(seconds: 5));
          if (raw != null) {
            credentials[source] = SubtitleSearchCredentials.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
          }
        } catch (_) {
          connectionErrors[source] = '无法读取安全存储，可重新输入密钥供本次使用';
        }
      }),
    ]);
    ready = true;
    notifyListeners();
  }

  Future<bool> saveCredentials(
    SubtitleSearchSource source,
    SubtitleSearchCredentials value,
  ) async {
    await initialize();
    var persisted = true;
    try {
      await _secrets
          .write(
            'subtitle_search_${source.name}_v1',
            jsonEncode(value.toJson()),
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      persisted = false;
    }
    // A keychain failure never copies credentials into plain-text preferences.
    credentials[source] = value;
    _credentialRevision++;
    connectionErrors.remove(source);
    _files.clear();
    _pendingFiles.clear();
    _documents.clear();
    for (final session in _sessions.values) {
      session.credentialsChanged();
    }
    notifyListeners();
    return persisted;
  }

  bool configured(SubtitleSearchSource source) =>
      !source.requiresKey || (credentials[source]?.configured ?? false);
  int get connectedCount =>
      SubtitleSearchSource.values.where(configured).length;

  SubtitleSearchSession acquire(
    String mediaKey,
    String title, {
    String filename = '',
  }) {
    final existing = _sessions.remove(mediaKey);
    final session =
        existing ??
        SubtitleSearchSession(this, mediaKey, title, filename: filename);
    _sessions[mediaKey] = session;
    session.attachments++;
    _trimSessions();
    return session;
  }

  void release(SubtitleSearchSession session) {
    session.attachments--;
    _trimSessions();
  }

  void _trimSessions() {
    while (_sessions.length > 8) {
      final idle = _sessions.entries
          .where((e) => e.value.attachments == 0)
          .firstOrNull;
      if (idle == null) break;
      _sessions.remove(idle.key)?.dispose();
    }
  }

  Future<Map<String, dynamic>?> readDraft(String key) async {
    await initialize();
    try {
      final drafts =
          jsonDecode(_prefs?.getString('subtitle_search_drafts_v1') ?? '{}')
              as Map<String, dynamic>;
      return (drafts[key] as Map?)?.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDraft(SubtitleSearchSession session) async {
    try {
      final drafts =
          jsonDecode(_prefs?.getString('subtitle_search_drafts_v1') ?? '{}')
              as Map<String, dynamic>;
      drafts.remove(session.mediaKey);
      drafts[session.mediaKey] = {
        'text': session.text,
        'language': session.language,
        'season': session.season,
        'episode': session.episode,
        if (session.work != null) 'work': session.work!.toJson(),
      };
      while (drafts.length > 20) {
        drafts.remove(drafts.keys.first);
      }
      await _prefs?.setString('subtitle_search_drafts_v1', jsonEncode(drafts));
    } catch (_) {
      /* Disk preferences are optional; memory state is retained. */
    }
  }

  Future<void> remember(String text) async {
    recent = [text, ...recent.where((s) => s != text)].take(8).toList();
    try {
      await _prefs?.setStringList('subtitle_search_recent_v1', recent);
    } catch (_) {}
  }

  Future<List<SubtitleSearchFile>> files(
    SubtitleSearchHit hit,
    SubtitleSearchQuery query,
  ) async {
    final key =
        '${hit.key}|${query.season}|${query.episode}|$_credentialRevision';
    if (_files.containsKey(key)) return _files[key]!;
    final existing = _pendingFiles[key];
    if (existing != null) return existing;
    final future = service.files(
      hit,
      query,
      credentials[hit.source] ?? const SubtitleSearchCredentials(),
    );
    _pendingFiles[key] = future;
    try {
      final files = await future;
      _files[key] = files;
      while (_files.length > 40) {
        _files.remove(_files.keys.first);
      }
      return files;
    } finally {
      _pendingFiles.remove(key);
    }
  }

  List<SubtitleSearchDocument>? documents(String key) {
    final docs = _documents.remove(key);
    if (docs != null) _documents[key] = docs;
    return docs;
  }

  void cacheDocuments(String key, List<SubtitleSearchDocument> documents) {
    _documents.remove(key);
    _documents[key] = documents;
    int size() => _documents.values
        .expand((d) => d)
        .fold(0, (n, d) => n + d.content.length * 2);
    while (_documents.length > 1 &&
        (size() > 24 * 1024 * 1024 || _documents.length > 8)) {
      _documents.remove(_documents.keys.first);
    }
  }

  @override
  void dispose() {
    for (final s in _sessions.values) {
      s.dispose();
    }
    service.dispose();
    super.dispose();
  }
}

class SubtitleSearchSession extends ChangeNotifier {
  SubtitleSearchSession(
    this.workspace,
    this.mediaKey,
    String title, {
    String filename = '',
  }) : text = SubtitleSearchQuery.cleanTitle(title) {
    var (s, e) = SubtitleSearchQuery.episodeFrom(filename);
    final fallback = SubtitleSearchQuery.episodeFrom(title);
    s ??= fallback.$1;
    e ??= fallback.$2;
    season = s?.toString() ?? '';
    episode = e?.toString() ?? '';
    restored = _restore();
  }
  final SubtitleSearchWorkspace workspace;
  final String mediaKey;
  late final Future<void> restored;
  String text, language = '', season = '', episode = '';
  SubtitleSearchWork? work;
  List<SubtitleSearchWork> works = [];
  bool lookingUpWorks = false, packsOnly = false;
  String? workError;
  int _workGeneration = 0;
  Timer? _workTimer;
  SubtitleSearchSource? sourceFilter;
  int attachments = 0;
  double scrollOffset = 0;
  final hits = <SubtitleSearchHit>[];
  final errors = <SubtitleSearchSource, String>{};
  final more = <SubtitleSearchSource, int>{};
  final pending = <SubtitleSearchSource>{};
  final savedPaths = <String, String>{};
  SubtitleSearchQuery? completedQuery;
  bool searching = false, loadingFiles = false, downloading = false;
  String? message, detailError;
  SubtitleSearchHit? selected;
  List<SubtitleSearchFile> availableFiles = [];
  SubtitleSearchFile? selectedFile;
  int documentIndex = 0;
  double downloadProgress = 0;
  String offset = '0';
  CancelToken? _searchToken, _downloadToken;
  int _generation = 0, _detailGeneration = 0;
  bool _disposed = false, _edited = false;
  String? _signature;
  Timer? _draftTimer;
  String get documentKey => '${selected?.key}|${selectedFile?.id}';
  List<SubtitleSearchDocument> get documents =>
      workspace.documents(documentKey) ?? const [];
  SubtitleSearchDocument? get document =>
      documents.elementAtOrNull(documentIndex);
  Iterable<SubtitleSearchHit> get visibleHits => hits.where(
    (h) =>
        (sourceFilter == null || h.source == sourceFilter) &&
        (!packsOnly ||
            h.releaseInfo.pack ||
            h.source == SubtitleSearchSource.jimaku),
  );

  Future<void> _restore() async {
    final draft = await workspace.readDraft(mediaKey);
    if (!_edited && draft != null) {
      text = draft['text'] as String? ?? text;
      language = draft['language'] as String? ?? '';
      season = draft['season'] as String? ?? season;
      episode = draft['episode'] as String? ?? episode;
      if (draft['work'] is Map) {
        work = SubtitleSearchWork.fromJson(
          Map<String, dynamic>.from(draft['work'] as Map),
        );
      }
    }
    _notify();
  }

  void edit() {
    _edited = true;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 300),
      () => workspace.saveDraft(this),
    );
  }

  void updateText(String value) {
    text = value;
    work = null;
    _workGeneration++;
    works = [];
    lookingUpWorks = false;
    workError = null;
    _workTimer?.cancel();
    if (value.trim().runes.length >= 2) {
      _workTimer = Timer(const Duration(milliseconds: 450), lookupWorks);
    }
    edit();
    _notify();
  }

  Future<void> lookupWorks() async {
    _workTimer?.cancel();
    if (_disposed || work != null || text.trim().runes.length < 2) return;
    final generation = ++_workGeneration;
    lookingUpWorks = true;
    workError = null;
    _notify();
    try {
      final result = await workspace.service.findWorks(text);
      if (_disposed || generation != _workGeneration) return;
      works = result;
    } catch (_) {
      if (_disposed || generation != _workGeneration) return;
      workError = '作品目录暂时不可用，可以直接搜索字幕';
    } finally {
      if (!_disposed && generation == _workGeneration) {
        lookingUpWorks = false;
        _notify();
      }
    }
  }

  Future<void> chooseWork(SubtitleSearchWork value) async {
    _workTimer?.cancel();
    _workGeneration++;
    lookingUpWorks = false;
    workError = null;
    work = value;
    season = value.season?.toString() ?? '';
    if (value.isMovie || SubtitleReleaseInfo.parse(value.title).special) {
      season = '';
      episode = '';
    }
    text = SubtitleSearchQuery.cleanTitle(value.title);
    if (text.isEmpty) text = value.title;
    edit();
    await search();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void credentialsChanged() {
    _signature = null;
    _searchToken?.cancel();
    _downloadToken?.cancel();
    _generation++;
    _detailGeneration++;
    searching = downloading = loadingFiles = false;
    pending.clear();
    availableFiles = [];
    selectedFile = null;
    _notify();
  }

  Future<void> search({bool force = false, SubtitleSearchSource? retry}) async {
    await workspace.initialize();
    if (_disposed) return;
    final query = SubtitleSearchQuery(
      text: text.trim(),
      language: language,
      season: int.tryParse(season),
      episode: int.tryParse(episode),
      work: work,
    );
    if (query.text.runes.length < 2) {
      message = '请输入至少 2 个字的片名或文件名';
      _notify();
      return;
    }
    if (season.isNotEmpty &&
            (query.season == null ||
                query.season! < 0 ||
                query.season! > 999) ||
        episode.isNotEmpty &&
            (query.episode == null ||
                query.episode! < 0 ||
                query.episode! > 9999)) {
      message = '请填写有效的季数和集数，也可以留空';
      _notify();
      return;
    }
    final signature = '${query.cacheKey}|${workspace.credentialRevision}';
    if (!force &&
        retry == null &&
        _signature == signature &&
        completedQuery != null) {
      return;
    }
    if (retry == null && work == null) unawaited(lookupWorks());
    final sources = retry != null
        ? [retry]
        : SubtitleSearchSource.values.where(workspace.configured).toList();
    if (sources.isEmpty) {
      message = '连接一个字幕来源后，即可在这里搜索和下载';
      _notify();
      return;
    }
    _searchToken?.cancel();
    final token = _searchToken = CancelToken();
    final generation = ++_generation;
    if (retry == null || completedQuery?.cacheKey != query.cacheKey) {
      hits.clear();
      errors.clear();
      more.clear();
      sourceFilter = null;
      scrollOffset = 0;
      closeDetail();
    } else {
      hits.removeWhere((h) => h.source == retry);
      errors.remove(retry);
      more.remove(retry);
    }
    completedQuery = query;
    _signature = signature;
    message = null;
    searching = true;
    pending
      ..clear()
      ..addAll(sources);
    _notify();
    unawaited(workspace.remember(query.text));
    await Future.wait(
      sources.map((source) => _fetchPage(source, query, token, generation)),
    );
    if (_disposed || generation != _generation) return;
    searching = false;
    _notify();
  }

  Future<void> _fetchPage(
    SubtitleSearchSource source,
    SubtitleSearchQuery query,
    CancelToken token,
    int generation,
  ) async {
    try {
      final result = await workspace.service.search(
        source,
        query,
        workspace.credentials[source] ?? const SubtitleSearchCredentials(),
        cancelToken: token,
      );
      if (_disposed || generation != _generation) return;
      final keys = hits.map((h) => h.key).toSet();
      hits.addAll(result.hits.where((h) => keys.add(h.key)));
      hits.sort((a, b) {
        final source = a.source.index.compareTo(b.source.index);
        if (source != 0) return source;
        final aInfo = a.releaseInfo, bInfo = b.releaseInfo;
        final aRank = query.episode != null && aInfo.episode == query.episode
            ? 2
            : aInfo.pack
            ? 1
            : 0;
        final bRank = query.episode != null && bInfo.episode == query.episode
            ? 2
            : bInfo.pack
            ? 1
            : 0;
        final rank = bRank.compareTo(aRank);
        return rank != 0 ? rank : a.key.compareTo(b.key);
      });
      if (result.hasMore) {
        more[source] = query.page + 1;
      } else {
        more.remove(source);
      }
      errors.remove(source);
    } catch (error) {
      if (_disposed || generation != _generation || token.isCancelled) return;
      errors[source] = SubtitleSearchService.errorMessage(error);
    } finally {
      if (!_disposed && generation == _generation) {
        pending.remove(source);
        _notify();
      }
    }
  }

  Future<void> loadMore() async {
    if (searching || completedQuery == null || more.isEmpty) return;
    searching = true;
    final pages = Map.of(more);
    final token = _searchToken = CancelToken();
    final generation = ++_generation;
    pending.addAll(pages.keys);
    _notify();
    await Future.wait(
      pages.entries.map(
        (e) => _fetchPage(
          e.key,
          completedQuery!.atPage(e.value),
          token,
          generation,
        ),
      ),
    );
    if (_disposed || generation != _generation) return;
    searching = false;
    _notify();
  }

  void cancelSearch() {
    _searchToken?.cancel();
    _generation++;
    searching = false;
    pending.clear();
    _signature = null;
    _notify();
  }

  Future<void> select(SubtitleSearchHit hit) async {
    if (selected?.key == hit.key && availableFiles.isNotEmpty) return;
    _downloadToken?.cancel();
    final generation = ++_detailGeneration;
    selected = hit;
    selectedFile = null;
    availableFiles = [];
    loadingFiles = true;
    downloading = false;
    detailError = null;
    offset = '0';
    documentIndex = 0;
    _notify();
    try {
      final files = await workspace.files(hit, completedQuery!);
      if (_disposed || generation != _detailGeneration) return;
      availableFiles = files;
      selectedFile = files.firstOrNull;
      if (files.isEmpty) detailError = '没有找到这一集的文件，可清空集数重新搜索，或前往来源网站';
    } catch (e) {
      if (generation == _detailGeneration) {
        detailError = SubtitleSearchService.errorMessage(e);
      }
    } finally {
      if (generation == _detailGeneration) {
        loadingFiles = false;
        _notify();
      }
    }
  }

  void chooseFile(SubtitleSearchFile file) {
    _downloadToken?.cancel();
    _detailGeneration++;
    selectedFile = file;
    documentIndex = 0;
    downloading = false;
    detailError = null;
    offset = '0';
    _notify();
  }

  Future<void> preview() async {
    final hit = selected, file = selectedFile;
    if (hit == null || file == null || downloading) return;
    if (documents.isNotEmpty) {
      _notify();
      return;
    }
    final generation = ++_detailGeneration;
    final key = documentKey;
    final token = _downloadToken = CancelToken();
    downloading = true;
    detailError = null;
    downloadProgress = 0;
    _notify();
    try {
      final documents = await workspace.service.download(
        hit,
        file,
        workspace.credentials[hit.source] ?? const SubtitleSearchCredentials(),
        cancelToken: token,
        onProgress: (p) {
          if (generation != _detailGeneration) return;
          // Progress notifications are coalesced to avoid rebuilding per chunk.
          if ((p - downloadProgress).abs() >= .03 || p == 1) {
            downloadProgress = p;
            _notify();
          }
        },
      );
      if (_disposed || generation != _detailGeneration) return;
      workspace.cacheDocuments(key, documents);
      documentIndex = 0;
      final ep = completedQuery?.episode;
      if (ep != null) {
        final index = documents.indexWhere((d) {
          final info = SubtitleReleaseInfo.parse(d.name);
          return info.episode == ep && info.accepts(completedQuery?.season, ep);
        });
        if (index >= 0) documentIndex = index;
      }
    } catch (e) {
      if (generation == _detailGeneration && !token.isCancelled) {
        detailError = SubtitleSearchService.errorMessage(e);
      }
    } finally {
      if (generation == _detailGeneration) {
        downloading = false;
        _notify();
      }
    }
  }

  void cancelDownload() {
    _downloadToken?.cancel();
    _detailGeneration++;
    downloading = false;
    _notify();
  }

  void closeDetail() {
    _downloadToken?.cancel();
    _detailGeneration++;
    selected = null;
    selectedFile = null;
    loadingFiles = downloading = false;
    detailError = null;
    _notify();
  }

  void changed() => _notify();
  @override
  void dispose() {
    _disposed = true;
    _draftTimer?.cancel();
    _workTimer?.cancel();
    _workGeneration++;
    unawaited(workspace.saveDraft(this));
    _searchToken?.cancel();
    _downloadToken?.cancel();
    super.dispose();
  }
}
