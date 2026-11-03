import 'package:video_player_app/services/network/network_http.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_browse_models.dart';
import '../../models/managed_subtitle_asset.dart';
import '../../models/video_item.dart';
import '../../utils/subtitle_util.dart';
import '../library_service.dart';
import '../task_subtitle_storage_service.dart';
import 'bilibili_api_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_player_video.dart';
import 'bilibili_public_api_service.dart';
import 'bilibili_stream_card.dart';

/// Name of a Bilibili subtitle track: its language name, else its code.
String bilibiliSubtitleLabel(String lanDoc, String lan) {
  final doc = lanDoc.trim();
  if (doc.isNotEmpty) return doc;
  final code = lan.trim();
  if (code.isNotEmpty) return code;
  return '字幕';
}

final RegExp _aiWord = RegExp(r'(^|[^A-Za-z])AI([^A-Za-z]|$)');

/// Whether a track is one of Bilibili's machine-made subtitles: its code
/// starts with `ai-`, or its name says so ("中文（自动生成）", "AI 字幕").
bool isBilibiliAiSubtitle({required String lan, required String label}) {
  if (lan.trim().toLowerCase().startsWith('ai-')) return true;
  return _aiWord.hasMatch(label.toUpperCase()) || label.contains('自动生成');
}

/// One subtitle track of a Bilibili video part. [path] is set once the track
/// is a file of the card; [url] is where it can be downloaded. A [locked]
/// track is only a name: Bilibili lists it but hands its file out only to a
/// logged-in request.
@immutable
class BilibiliSubtitleTrack {
  const BilibiliSubtitleTrack({
    required this.lan,
    required this.label,
    required this.isAi,
    this.url = '',
    this.path,
    this.id = '',
    this.locked = false,
  });

  final String lan;
  final String label;
  final bool isAi;
  final String url;
  final String? path;

  /// Bilibili's id of the subtitle, empty when unknown.
  final String id;
  final bool locked;

  bool get isDownloaded => path != null;

  BilibiliSubtitleTrack withPath(String? path) => BilibiliSubtitleTrack(
    lan: lan,
    label: label,
    isAi: isAi,
    url: url,
    path: path,
    id: id,
    locked: locked,
  );

  /// What two listings of the same track share: the subtitle id with its
  /// language, else the address without its query (the address of an AI
  /// track carries a key that differs from answer to answer).
  String get identity {
    if (id.isNotEmpty) return 'id:$id|$lan';
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host.isNotEmpty) return 'url:${uri.host}${uri.path}';
    return 'url:$url|$lan|$label';
  }

  @override
  String toString() =>
      'BilibiliSubtitleTrack($lan, $label, ai: $isAi, locked: $locked)';
}

String _subtitleIdOf(Map raw) {
  final text = readBiliText(raw['id_str']);
  if (text.isNotEmpty && text != '0') return text;
  final number = readBiliInt(raw['id']);
  return number > 0 ? '$number' : '';
}

String _httpsUrl(Object? raw) {
  var url = readBiliText(raw);
  if (url.startsWith('//')) url = 'https:$url';
  if (url.startsWith('http://')) url = 'https://${url.substring(7)}';
  return url;
}

/// The tracks in `data.subtitle.subtitles` of a player answer
/// (`x/player/wbi/v2`). Tracks without an address are left out, a track
/// listed twice is kept once.
List<BilibiliSubtitleTrack> parseBilibiliSubtitleTracks(Object? data) {
  final subtitle = data is Map ? data['subtitle'] : null;
  final list = subtitle is Map ? subtitle['subtitles'] : null;
  if (list is! List) return const <BilibiliSubtitleTrack>[];
  final seen = <String>{};
  final tracks = <BilibiliSubtitleTrack>[];
  for (final raw in list) {
    if (raw is! Map) continue;
    final url = _httpsUrl(raw['subtitle_url']);
    if (url.isEmpty) continue;
    final lan = readBiliText(raw['lan']);
    final label = bilibiliSubtitleLabel(readBiliText(raw['lan_doc']), lan);
    final track = BilibiliSubtitleTrack(
      lan: lan,
      label: label,
      isAi: isBilibiliAiSubtitle(lan: lan, label: label),
      url: url,
      id: _subtitleIdOf(raw),
    );
    if (seen.add(track.identity)) tracks.add(track);
  }
  return tracks;
}

/// Bilibili refused the subtitle list (a business code other than 0 or
/// -101, or risk control). Never carries account data.
class BilibiliSubtitleListException implements Exception {
  const BilibiliSubtitleListException(this.code);

  final Object? code;

  @override
  String toString() => '字幕列表暂时拿不到（$code）';
}

/// What one player answer says about the subtitles of a part.
@immutable
class BilibiliSubtitleAnswer {
  const BilibiliSubtitleAnswer({
    this.tracks = const <BilibiliSubtitleTrack>[],
    this.needsLogin = false,
  });

  final List<BilibiliSubtitleTrack> tracks;

  /// Bilibili keeps subtitles of the part for logged-in requests
  /// (`need_login_subtitle`), or did not accept the login it was sent
  /// (`-101`).
  final bool needsLogin;
}

/// Reads a whole player answer (`code`, `data`). Code 0 gives its tracks and
/// `need_login_subtitle`; -101 is an answer that needs a login; any other
/// code (risk control included) throws [BilibiliSubtitleListException].
BilibiliSubtitleAnswer parseBilibiliSubtitleAnswer(
  Map<String, dynamic> payload,
) {
  final code = payload['code'];
  if (code == -101) return const BilibiliSubtitleAnswer(needsLogin: true);
  if (code != 0 || BilibiliPublicApiService.isRiskControlPayload(payload)) {
    throw BilibiliSubtitleListException(code);
  }
  final data = payload['data'];
  final flag = data is Map ? data['need_login_subtitle'] : null;
  return BilibiliSubtitleAnswer(
    tracks: parseBilibiliSubtitleTracks(data),
    needsLogin: flag == true || flag == 1,
  );
}

/// The subtitle names in `data.subtitle.list` of a video info answer
/// (`x/web-interface/view`) as [BilibiliSubtitleTrack.locked] tracks, for the
/// part [cid]. Logged out Bilibili lists them locked and without address.
/// Empty when the answer describes another part (it covers the first one).
List<BilibiliSubtitleTrack> parseBilibiliLockedSubtitleTracks(
  Object? data,
  int cid,
) {
  if (data is! Map || readBiliInt(data['cid']) != cid) {
    return const <BilibiliSubtitleTrack>[];
  }
  final subtitle = data['subtitle'];
  final list = subtitle is Map ? subtitle['list'] : null;
  if (list is! List) return const <BilibiliSubtitleTrack>[];
  final seen = <String>{};
  final tracks = <BilibiliSubtitleTrack>[];
  for (final raw in list) {
    if (raw is! Map) continue;
    final lan = readBiliText(raw['lan']);
    final label = bilibiliSubtitleLabel(readBiliText(raw['lan_doc']), lan);
    if (!seen.add('$lan|$label')) continue;
    tracks.add(
      BilibiliSubtitleTrack(
        lan: lan,
        label: label,
        isAi: isBilibiliAiSubtitle(lan: lan, label: label),
        id: _subtitleIdOf(raw),
        locked: true,
      ),
    );
  }
  return tracks;
}

/// Whether [a] and [b] name the same track: the same code, else the same
/// shown name.
bool _sameTrackName(BilibiliSubtitleTrack a, BilibiliSubtitleTrack b) {
  if (a.lan.isNotEmpty && b.lan.isNotEmpty) return a.lan == b.lan;
  return subtitleDisplayLabel(a.label) == subtitleDisplayLabel(b.label);
}

/// The Bilibili subtitles already saved as files of [item] (what a card or a
/// download wrote), in the order the card lists them.
List<BilibiliSubtitleTrack> downloadedBilibiliSubtitleTracks(VideoItem item) {
  final tracks = <BilibiliSubtitleTrack>[];
  for (final entry in item.downloadAssociatedSubtitles.entries) {
    ManagedSubtitleAsset? asset;
    for (final candidate in item.managedSubtitleAssets) {
      if (p.equals(p.normalize(candidate.path), p.normalize(entry.value))) {
        asset = candidate;
        break;
      }
    }
    final name = asset?.displayName.trim() ?? '';
    final label = subtitleDisplayLabel(name.isNotEmpty ? name : entry.key);
    final lan = asset?.language?.trim() ?? '';
    tracks.add(
      BilibiliSubtitleTrack(
        lan: lan,
        label: label,
        isAi: isBilibiliAiSubtitle(lan: lan, label: label),
        path: entry.value,
      ),
    );
  }
  return tracks;
}

/// [remote] in its own order, each with the file of the same track when one
/// was saved, then the saved files no remote track names (for example an AI
/// subtitle saved while logged in).
List<BilibiliSubtitleTrack> mergeBilibiliSubtitleTracks(
  List<BilibiliSubtitleTrack> remote,
  List<BilibiliSubtitleTrack> downloaded,
) {
  final left = List<BilibiliSubtitleTrack>.of(downloaded);
  final merged = <BilibiliSubtitleTrack>[];
  for (final track in remote) {
    var index = left.indexWhere(
      (d) => d.lan.isNotEmpty && track.lan.isNotEmpty && d.lan == track.lan,
    );
    if (index < 0) {
      final label = subtitleDisplayLabel(track.label);
      index = left.indexWhere((d) => subtitleDisplayLabel(d.label) == label);
    }
    if (index < 0) {
      merged.add(track);
    } else {
      merged.add(track.withPath(left.removeAt(index).path));
    }
  }
  return <BilibiliSubtitleTrack>[...merged, ...left];
}

/// What the subtitle area shows for the Bilibili tracks of one card.
@immutable
class BilibiliSubtitleTrackList {
  const BilibiliSubtitleTrackList({
    this.tracks = const <BilibiliSubtitleTrack>[],
    this.locked = const <BilibiliSubtitleTrack>[],
    this.loading = false,
    this.listed = false,
    this.loggedIn = false,
    this.loginExpired = false,
    this.needsLogin = false,
    this.savedOnly = false,
    this.failed = false,
    this.networkFailed = false,
    this.partlyFailed = false,
  });

  /// The tracks that can be picked (fetched on demand, or already files).
  final List<BilibiliSubtitleTrack> tracks;

  /// Names of tracks Bilibili hands out only to a logged-in request; shown
  /// greyed, a tap asks to log in.
  final List<BilibiliSubtitleTrack> locked;

  /// The track list of an online card is still being asked for.
  final bool loading;

  /// Bilibili answered with the track list.
  final bool listed;

  /// The list was asked with a login Bilibili accepted.
  final bool loggedIn;

  /// A login is stored but Bilibili no longer accepts it.
  final bool loginExpired;

  /// Bilibili keeps subtitles of the part for logged-in requests.
  final bool needsLogin;

  /// A downloaded video: only its saved files, nothing is asked.
  final bool savedOnly;

  /// The track list could not be asked for; [failureMessage] offers a retry.
  final bool failed;

  /// [failed] because no answer came back at all (no network).
  final bool networkFailed;

  /// Logged in, the logged-in answer failed but the public one listed
  /// tracks: those are shown, the rest can be asked again.
  final bool partlyFailed;

  /// The line shown when the part has no subtitle at all, or null.
  String? get emptyMessage {
    if (loading || failed || tracks.isNotEmpty || locked.isNotEmpty) {
      return null;
    }
    if (savedOnly) return '这个视频没有已下载的字幕';
    if (listed && !needsLogin) return '这个视频没有字幕';
    return null;
  }

  /// The line of a list that could not be (fully) had; a tap asks again.
  String? get failureMessage {
    if (loading) return null;
    if (failed) {
      return networkFailed ? '网络不通，字幕列表暂时拿不到，点一下重试' : '字幕列表暂时拿不到，点一下重试';
    }
    if (partlyFailed) return '部分字幕暂时拿不到，点一下重试';
    return null;
  }

  /// The line asking to log in, or null; a tap opens the login.
  String? get loginMessage {
    if (loading || failed || savedOnly || !listed || loggedIn) return null;
    final again = loginExpired ? '登录已过期，重新登录后' : '登录后';
    // Bilibili asks for a login (need_login_subtitle) only for videos that
    // have subtitles, so the line says so even when no names came for this
    // part (they cover only the first part).
    if (tracks.isEmpty && (locked.isNotEmpty || needsLogin)) {
      return loginExpired ? '这个视频有字幕，登录已过期，重新登录后可加载' : '这个视频有字幕，登录后可加载';
    }
    if (locked.isNotEmpty || needsLogin) return '$again可加载更多字幕';
    if (tracks.isNotEmpty) return '$again可加载 AI 字幕';
    return null;
  }
}

/// Where the track list and the subtitle files come from. Tests pass fakes.
class BilibiliSubtitleTrackSource {
  const BilibiliSubtitleTrackSource({
    required this.fetchPublicAnswer,
    required this.fetchLoggedInAnswer,
    required this.isLoggedIn,
    required this.fetchContent,
    this.fetchLockedTracks,
    this.completePending,
    this.loginChanges,
  });

  /// The app's sources: the public (cookie-free) player answer, the player
  /// answer asked with the login of [api], the subtitle names of the
  /// cookie-free video info, and the subtitle files from a cookie-free
  /// client.
  factory BilibiliSubtitleTrackSource.app({
    required BilibiliApiService api,
    BilibiliPublicApiService? publicApi,
    Future<bool> Function(String itemId)? completePending,
    Dio? contentClient,
  }) {
    final public = publicApi ?? BilibiliPublicApiService();
    final client =
        contentClient ??
        NetworkHttp.instance.createDio(
          scope: NetworkScope.bilibili,
          options: BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 20),
            headers: const {
              'User-Agent': BilibiliPublicApiService.userAgent,
              'Referer': 'https://www.bilibili.com/',
            },
          ),
        );
    return BilibiliSubtitleTrackSource(
      fetchPublicAnswer: (bvid, cid) async {
        final payload = await public.getPublicJson(
          '/x/player/wbi/v2',
          query: <String, dynamic>{'bvid': bvid, 'cid': cid},
          referer: BilibiliPublicApiService.videoReferer(bvid),
          what: '字幕列表',
          signed: true,
        );
        return parseBilibiliSubtitleAnswer(payload);
      },
      // The logged-in player answer; its log lines carry only bvid/cid.
      fetchLoggedInAnswer: (bvid, cid) async =>
          parseBilibiliSubtitleAnswer(await api.fetchPlayerAnswer(bvid, cid)),
      fetchLockedTracks: (bvid, cid) async {
        final payload = await public.getPublicJson(
          '/x/web-interface/view',
          query: <String, dynamic>{'bvid': bvid},
          referer: BilibiliPublicApiService.videoReferer(bvid),
          what: '视频信息',
        );
        if (payload['code'] != 0) {
          throw BilibiliSubtitleListException(payload['code']);
        }
        return parseBilibiliLockedSubtitleTracks(payload['data'], cid);
      },
      isLoggedIn: () async {
        await api.init();
        return api.hasCookie();
      },
      fetchContent: (url) async {
        final uri = Uri.tryParse(url);
        final host = uri?.host ?? '';
        if (uri == null ||
            uri.scheme != 'https' ||
            !(host.endsWith('.hdslb.com') || host.endsWith('.bilibili.com'))) {
          throw const FormatException('字幕地址无效');
        }
        final response = await client.getUri<dynamic>(uri);
        return response.data;
      },
      completePending: completePending,
      loginChanges: api.loginChanges,
    );
  }

  /// The player answer asked without the login cookie. Throws when it could
  /// not be had.
  final Future<BilibiliSubtitleAnswer> Function(String bvid, int cid)
  fetchPublicAnswer;

  /// The player answer asked with the stored login (CC and AI tracks).
  /// Throws when it could not be had.
  final Future<BilibiliSubtitleAnswer> Function(String bvid, int cid)
  fetchLoggedInAnswer;

  /// The names of the part's subtitles Bilibili lists without a login (see
  /// [parseBilibiliLockedSubtitleTracks]); asked only when no track could be
  /// had without one.
  final Future<List<BilibiliSubtitleTrack>> Function(String bvid, int cid)?
  fetchLockedTracks;

  /// Whether a login is stored. Asks nothing over the network.
  final Future<bool> Function() isLoggedIn;

  /// The subtitle file at a track address (Bilibili's JSON subtitle).
  final Future<Object?> Function(String url) fetchContent;

  /// Finishes the player data of a watch-only entry that has none yet and
  /// returns true, or returns false when [itemId] is no such entry.
  final Future<bool> Function(String itemId)? completePending;

  /// Notifies when the stored login was replaced or removed.
  final Listenable? loginChanges;
}

/// Where a picked track is saved: the card it belongs to.
class BilibiliSubtitleTrackStore {
  const BilibiliSubtitleTrackStore({
    required this.itemOf,
    required this.noteChanged,
    required this.writeSubtitle,
    this.attachSubtitle,
    this.changes,
  });

  factory BilibiliSubtitleTrackStore.library(LibraryService library) =>
      BilibiliSubtitleTrackStore(
        itemOf: library.getVideo,
        noteChanged: library.noteCardDataChanged,
        writeSubtitle: (itemId, label, contents) async {
          // Same part, same file: a watch card and the library card both see it.
          final path = await library.allocateSubtitleFile(
            itemId,
            TaskSubtitleStorageService.readableSubtitleFileName(
              label: label,
              extension: '.srt',
            ),
          );
          await File(path).writeAsString(contents, flush: true);
          return path;
        },
        attachSubtitle: (itemId, track, path) async {
          final cards = library.cardsOfSameBilibiliPart(itemId);
          final single = library.getVideo(itemId);
          final targets = cards.isNotEmpty
              ? cards
              : <VideoItem>[?single];
          for (final card in targets) {
            BilibiliSubtitleTracks.attachSavedTrack(card, track, path);
            await library.noteCardDataChanged(card.id);
          }
        },
        changes: library,
      );

  final VideoItem? Function(String itemId) itemOf;

  /// Saves the card after its subtitle files changed.
  final Future<void> Function(String itemId) noteChanged;

  /// Writes [contents] as a subtitle file of the card and returns its path.
  final Future<String> Function(String itemId, String label, String contents)
  writeSubtitle;

  /// Binds a saved track onto every card that should show it. When null, only
  /// the card that was asked is updated.
  final Future<void> Function(
    String itemId,
    BilibiliSubtitleTrack track,
    String path,
  )?
  attachSubtitle;

  /// Notifies when cards changed (for example a part got its player data).
  final Listenable? changes;
}

class _RemoteTracks {
  _RemoteTracks(this.loggedIn);

  /// A login was stored when the list was asked for.
  final bool loggedIn;
  bool loading = true;
  bool failed = false;
  bool networkFailed = false;
  bool partlyFailed = false;

  /// The stored login was not accepted (expired).
  bool loginRejected = false;
  bool needsLogin = false;

  /// The login changed while this list was on its way: asked again after.
  bool outdated = false;
  List<BilibiliSubtitleTrack> tracks = const <BilibiliSubtitleTrack>[];
  List<BilibiliSubtitleTrack> locked = const <BilibiliSubtitleTrack>[];

  bool get complete => !loading && !failed && !partlyFailed;
}

/// The Bilibili subtitle tracks of the cards on the playback page: which
/// tracks a part has, and the subtitle file of a picked track.
///
/// * Online cards ask for the list once per part. Logged in, the CC and AI
///   tracks come from the logged-in player answer, merged with the public
///   one (each track once). Logged out (or with a login Bilibili no longer
///   accepts) only the public answer is asked; when it has no track the
///   names Bilibili lists for logged-in users are shown greyed with a login
///   line, never "no subtitles".
/// * A list that could not be had is a failure with a retry, never an empty
///   list and never a spinner that does not end.
/// * A login, logout or new login asks every listed part again.
/// * Downloaded videos list only their saved files and ask nothing.
///
/// Nothing here selects a subtitle by itself; the caller loads a picked
/// path like any other subtitle.
class BilibiliSubtitleTracks extends ChangeNotifier {
  BilibiliSubtitleTracks({required this.source, required this.store}) {
    store.changes?.addListener(notifyListeners);
    source.loginChanges?.addListener(_loginChanged);
  }

  /// The app instance for [download] and [library].
  factory BilibiliSubtitleTracks.forApp({
    required BilibiliDownloadService download,
    required LibraryService library,
  }) {
    final known = _app;
    if (known != null &&
        identical(known.$1, download) &&
        identical(known.$2, library)) {
      return known.$3;
    }
    final tracks = BilibiliSubtitleTracks(
      source: BilibiliSubtitleTrackSource.app(
        api: download.apiService,
        completePending: (itemId) => download.isPendingWatchPart(itemId)
            ? download.completeWatchPart(library, itemId)
            : Future<bool>.value(false),
      ),
      store: BilibiliSubtitleTrackStore.library(library),
    );
    _app = (download, library, tracks);
    return tracks;
  }

  static (BilibiliDownloadService, LibraryService, BilibiliSubtitleTracks)?
  _app;

  /// Used instead of the app instance when set (tests put fakes here).
  static BilibiliSubtitleTracks? overrideForTesting;

  final BilibiliSubtitleTrackSource source;
  final BilibiliSubtitleTrackStore store;

  final Map<String, _RemoteTracks> _remote = <String, _RemoteTracks>{};
  final Map<String, Future<String?>> _loading = <String, Future<String?>>{};
  final Set<String> _failedLoads = <String>{};
  bool _disposed = false;

  /// `bvid#cid` of an online card, or null for anything else.
  static String? onlineKeyOf(VideoItem item) => bilibiliOnlinePartKey(item);

  /// Whether [item] is a Bilibili video whose tracks are listed here.
  static bool covers(VideoItem? item) => bilibiliPlayerVideoOf(item) != null;

  /// Whether the list of the online card [itemId] has not been asked for
  /// (or was dropped after a login change), so [ensureLoaded] should run.
  bool needsAsking(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null) return false;
    final key = onlineKeyOf(item);
    return key != null && !_remote.containsKey(key);
  }

  /// Asks for the track list of the card [itemId] unless it is known for the
  /// current login. A list that failed (fully or partly) is asked again.
  /// Downloaded videos ask nothing.
  Future<void> ensureLoaded(String itemId) async {
    final item = store.itemOf(itemId);
    if (item == null) return;
    final key = onlineKeyOf(item);
    if (key == null) return;
    final known = _remote[key];
    if (known != null && known.loading) return;
    bool loggedIn;
    var loginUnknown = false;
    try {
      loggedIn = await source.isLoggedIn();
    } catch (error) {
      developer.log('Bilibili login check failed', error: error.runtimeType);
      loggedIn = false;
      loginUnknown = true;
    }
    final again = _remote[key];
    if (again != null &&
        (again.loading || (again.complete && again.loggedIn == loggedIn))) {
      return;
    }
    final entry = _RemoteTracks(loggedIn);
    _remote[key] = entry;
    _notify();
    final separator = key.indexOf('#');
    final bvid = key.substring(0, separator);
    final cid = int.parse(key.substring(separator + 1));
    try {
      if (loginUnknown) throw StateError('login unknown');
      await _ask(entry, bvid, cid);
    } catch (error) {
      entry
        ..failed = true
        ..networkFailed = _isNetworkFailure(error)
        ..tracks = const <BilibiliSubtitleTrack>[]
        ..locked = const <BilibiliSubtitleTrack>[];
      developer.log(
        'Bilibili subtitle list unavailable',
        error: error.runtimeType,
      );
    } finally {
      entry.loading = false;
      // The login changed meanwhile: dropped, so the area asks again.
      if (entry.outdated && identical(_remote[key], entry)) _remote.remove(key);
      _notify();
    }
  }

  /// Drops the list of [itemId] (unless it is on its way) and asks again:
  /// the retry of a failed list, or after the login page was left.
  Future<void> reload(String itemId) {
    final item = store.itemOf(itemId);
    final key = item == null ? null : onlineKeyOf(item);
    if (key != null && !(_remote[key]?.loading ?? false)) _remote.remove(key);
    return ensureLoaded(itemId);
  }

  Future<void> _ask(_RemoteTracks entry, String bvid, int cid) async {
    Future<(BilibiliSubtitleAnswer?, Object?)> attempt(
      Future<BilibiliSubtitleAnswer> Function(String, int) ask,
    ) async {
      try {
        return (await ask(bvid, cid), null);
      } catch (error) {
        return (null, error);
      }
    }

    final publicAsk = attempt(source.fetchPublicAnswer);
    if (entry.loggedIn) {
      final (withLogin, loginError) = await attempt(source.fetchLoggedInAnswer);
      final (public, _) = await publicAsk;
      if (withLogin != null && !withLogin.needsLogin) {
        entry.tracks = _distinct(<BilibiliSubtitleTrack>[
          ...withLogin.tracks,
          ...?public?.tracks,
        ]);
        return;
      }
      if (withLogin == null) {
        developer.log(
          'Bilibili logged-in subtitle list unavailable',
          error: loginError.runtimeType,
        );
        if (public == null || public.tracks.isEmpty) throw loginError!;
        entry
          ..tracks = _distinct(public.tracks)
          ..partlyFailed = true;
        return;
      }
      // Bilibili did not accept the stored login: as if logged out.
      entry.loginRejected = true;
    }
    final (public, publicError) = await publicAsk;
    if (public == null) throw publicError!;
    entry
      ..tracks = _distinct(public.tracks)
      ..needsLogin = public.needsLogin;
    if (entry.tracks.isNotEmpty) return;
    final names = source.fetchLockedTracks;
    if (names == null) return;
    try {
      entry.locked = await names(bvid, cid);
    } catch (error) {
      // Only the greyed names are missing; the login line still shows when
      // Bilibili said the part keeps subtitles for logged-in users.
      developer.log(
        'Bilibili subtitle names unavailable',
        error: error.runtimeType,
      );
    }
  }

  static List<BilibiliSubtitleTrack> _distinct(
    List<BilibiliSubtitleTrack> tracks,
  ) {
    final seen = <String>{};
    return <BilibiliSubtitleTrack>[
      for (final track in tracks)
        if (seen.add(track.identity)) track,
    ];
  }

  void _loginChanged() {
    for (final entry in _remote.values) {
      entry.outdated = true;
    }
    _remote.removeWhere((_, entry) => !entry.loading);
    _notify();
  }

  static bool _isNetworkFailure(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      (error is BilibiliPublicApiException && error.isNetworkError) ||
      (error is DioException &&
          error.type != DioExceptionType.badResponse &&
          error.type != DioExceptionType.cancel &&
          error.type != DioExceptionType.badCertificate);

  /// The tracks to show for the card [itemId] right now.
  BilibiliSubtitleTrackList listFor(String itemId) {
    final item = store.itemOf(itemId);
    if (item == null) return const BilibiliSubtitleTrackList();
    final saved = downloadedBilibiliSubtitleTracks(item);
    final key = onlineKeyOf(item);
    if (key == null) {
      return BilibiliSubtitleTrackList(tracks: saved, savedOnly: true);
    }
    final remote = _remote[key];
    if (remote == null || remote.loading) {
      return BilibiliSubtitleTrackList(tracks: saved, loading: true);
    }
    if (remote.failed) {
      return BilibiliSubtitleTrackList(
        tracks: saved,
        failed: true,
        networkFailed: remote.networkFailed,
      );
    }
    final accepted = remote.loggedIn && !remote.loginRejected;
    return BilibiliSubtitleTrackList(
      tracks: mergeBilibiliSubtitleTracks(remote.tracks, saved),
      locked: <BilibiliSubtitleTrack>[
        for (final name in remote.locked)
          if (!saved.any((file) => _sameTrackName(file, name))) name,
      ],
      listed: true,
      loggedIn: accepted,
      loginExpired: remote.loginRejected,
      needsLogin: !accepted && (remote.needsLogin || remote.locked.isNotEmpty),
      partlyFailed: remote.partlyFailed,
    );
  }

  static String _trackKey(String itemId, BilibiliSubtitleTrack track) =>
      '$itemId|${track.lan}|${track.label}|${track.url}';

  /// Whether the file of [track] is being fetched for [itemId].
  bool isLoading(String itemId, BilibiliSubtitleTrack track) =>
      _loading.containsKey(_trackKey(itemId, track));

  /// Whether the last fetch of [track] for [itemId] failed.
  bool hasFailed(String itemId, BilibiliSubtitleTrack track) =>
      _failedLoads.contains(_trackKey(itemId, track));

  /// The subtitle file of [track] for the card [itemId], fetched and saved
  /// with the card when it is not a file yet. Null when it could not be had.
  ///
  /// A watch-only entry still waiting for its player data gets that first
  /// (it saves every track), so the track is not fetched twice.
  Future<String?> load(String itemId, BilibiliSubtitleTrack track) {
    final saved = track.path;
    if (saved != null && File(saved).existsSync()) {
      return Future<String?>.value(saved);
    }
    final key = _trackKey(itemId, track);
    final running = _loading[key];
    if (running != null) return running;
    _failedLoads.remove(key);
    final loading = _load(itemId, track);
    _loading[key] = loading;
    _notify();
    return loading
        .then((path) {
          if (path == null) _failedLoads.add(key);
          return path;
        })
        .whenComplete(() {
          _loading.remove(key);
          _notify();
        });
  }

  Future<String?> _load(String itemId, BilibiliSubtitleTrack track) async {
    try {
      final complete = source.completePending;
      if (complete != null && await complete(itemId)) {
        final item = store.itemOf(itemId);
        if (item != null) {
          final merged = mergeBilibiliSubtitleTracks(<BilibiliSubtitleTrack>[
            track.withPath(null),
          ], downloadedBilibiliSubtitleTracks(item));
          final path = merged.first.path;
          if (path != null && File(path).existsSync()) return path;
        }
      }
      if (track.url.isEmpty) return null;
      final payload = await source.fetchContent(track.url);
      final srt = SubtitleUtil.convertJsonToSrt(payload);
      if (srt.trim().isEmpty) return null;
      final item = store.itemOf(itemId);
      if (item == null) return null;
      final path = await store.writeSubtitle(itemId, track.label, srt);
      final current = store.itemOf(itemId);
      if (current == null) {
        await _deleteQuietly(path);
        return null;
      }
      final attach = store.attachSubtitle;
      if (attach != null) {
        await attach(itemId, track, path);
      } else {
        attachSavedTrack(current, track, path);
        await store.noteChanged(itemId);
      }
      return path;
    } catch (error) {
      developer.log(
        'Bilibili subtitle track not loaded',
        error: error.runtimeType,
      );
      return null;
    }
  }

  /// Remembers [path] as a saved track of [item]. A path already on the card
  /// is kept once, so binding the same file onto a sibling does not duplicate it.
  static void attachSavedTrack(
    VideoItem item,
    BilibiliSubtitleTrack track,
    String path,
  ) {
    final normalizedPath = p.normalize(path);
    final subtitles = <String, String>{...?item.additionalSubtitles};
    final alreadyListed = subtitles.values.any(
      (existing) => p.equals(p.normalize(existing), normalizedPath),
    );
    final alreadyManaged = item.managedSubtitleAssets.any(
      (asset) => p.equals(p.normalize(asset.path), normalizedPath),
    );
    if (alreadyListed && alreadyManaged) return;
    final label = subtitleDisplayLabel(track.label);
    var key = label;
    if (subtitles.containsKey(key)) {
      key = p.basename(path);
      var serial = 2;
      while (subtitles.containsKey(key)) {
        key =
            '${p.basenameWithoutExtension(path)} ($serial)'
            '${p.extension(path)}';
        serial++;
      }
    }
    if (!alreadyListed) subtitles[key] = normalizedPath;
    item
      ..additionalSubtitles = subtitles
      ..usesManagedAssociatedSubtitles = true;
    if (!alreadyManaged) {
      item.managedSubtitleAssets = <ManagedSubtitleAsset>[
        ...item.managedSubtitleAssets,
        ManagedSubtitleAsset(
          assetId: 'bilibili-${DateTime.now().microsecondsSinceEpoch}',
          path: normalizedPath,
          kind: ManagedSubtitleAssetKind.downloaded,
          displayName: label,
          language: track.lan.isEmpty ? null : track.lan,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ];
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    store.changes?.removeListener(notifyListeners);
    source.loginChanges?.removeListener(_loginChanged);
    super.dispose();
  }
}
