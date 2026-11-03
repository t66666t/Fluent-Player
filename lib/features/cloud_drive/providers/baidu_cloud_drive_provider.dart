import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';

import '../../../utils/subtitle_file_matcher.dart';
import '../../../utils/subtitle_parser.dart';
import '../models/cloud_drive_media_kind.dart';
import '../models/cloud_drive_models.dart';
import '../services/cloud_drive_playback_budget.dart';
import '../services/cloud_drive_subtitle_text.dart';
import 'cloud_drive_http.dart';
import 'cloud_drive_provider.dart';

/// Pages scanned for a sidecar before the result is reported as incomplete.
const int cloudDriveSubtitleTextByteLimit = 8 * 1024 * 1024;

/// Baidu Netdisk through the official website session.
///
/// `app_id` 250528 is the public client id the official pan.baidu.com page
/// sends with its own requests. It is not a third-party developer secret and
/// this provider does not invent an app identity or call a public parser.
///
/// Directory listing and playback are separate calls. A successful file list
/// is not treated as proof that a native stream exists.
class BaiduCloudDriveProvider extends CloudDriveProvider {
  BaiduCloudDriveProvider({CloudDriveHttp? http, DateTime Function()? now})
    : _http = http ?? NetworkCloudDriveHttp(),
      _now = now ?? DateTime.now;

  static const String providerId = 'baidu';

  /// Official web client id observed on pan.baidu.com, not a project secret.
  static const String webAppId = '250528';
  static const String webUserAgent = 'pan.baidu.com';

  /// Desktop browser identity used by the verified subtitle directory read.
  /// The short `pan.baidu.com` agent is not assumed to be equivalent.
  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const String subtitlePlaylistType = 'M3U8_SUBTITLE_SRT';

  static const List<(String, String)> transcodeLadder = <(String, String)>[
    ('M3U8_AUTO_1080', '1080P 转码'),
    ('M3U8_AUTO_720', '720P 转码'),
    ('M3U8_AUTO_480', '480P 转码'),
  ];

  final CloudDriveHttp _http;

  @override
  CloudDriveHttp get thumbnailHttp => _http;

  @override
  String get thumbnailUserAgent => browserUserAgent;
  final DateTime Function() _now;
  final CloudDriveSingleFlight<_BaiduMeta?> _metaFlights =
      CloudDriveSingleFlight<_BaiduMeta?>();
  final Map<String, ({CloudDrivePlaybackDescriptor descriptor, DateTime at})>
  _verified = {};
  final Map<String, Future<String>> _bdstokenLoads = {};

  @override
  String get id => providerId;

  @override
  String get displayName => '百度网盘';

  @override
  Uri get loginUri => Uri.https('pan.baidu.com', '/disk/main');

  @override
  CloudDriveCapabilities get capabilities =>
      const CloudDriveCapabilities(serverDateSort: true, remoteSubtitles: true);

  @override
  Future<CloudDriveVerifiedSession> verifySession(
    CloudDriveCredential credential, {
    Object? cancelToken,
  }) async {
    final status = await _getJson(
      credential,
      Uri.https('pan.baidu.com', '/api/loginStatus', _webQuery()),
      'login',
      cancelToken: cancelToken,
    );
    final login = status['login_info'];
    if (login is! Map) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '百度网页会话还不能确认账号',
      );
    }
    final info = Map<String, dynamic>.from(login);
    final remoteId = '${info['uk'] ?? ''}'.trim();
    if (remoteId.isEmpty || remoteId == '0') {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '百度网页会话还不能确认账号',
      );
    }
    await listChildren(
      CloudDriveListRequest(
        credential: credential,
        accountLocalId: '',
        remoteAccountId: remoteId,
        driveId: '0',
        parentFileId: '/',
      ),
      cancelToken: cancelToken,
    );
    final name = '${info['username'] ?? info['uname'] ?? ''}'.trim();
    return CloudDriveVerifiedSession(
      remoteAccountId: remoteId,
      displayName: name.isEmpty ? '百度网盘' : name,
      avatar: _optional(info['photo_url']),
    );
  }

  @override
  Future<CloudDrivePage> listChildren(
    CloudDriveListRequest request, {
    Object? cancelToken,
  }) async {
    final page = int.tryParse(request.cursor ?? '') ?? 1;
    final order = request.sort == CloudDriveSort.modified ? 'time' : 'name';
    final json = await _getJson(
      request.credential,
      Uri.https('pan.baidu.com', '/api/list', {
        ..._webQuery(),
        'dir': request.parentFileId.isEmpty ? '/' : request.parentFileId,
        'order': order,
        'desc': request.descending ? '1' : '0',
        'num': '${capabilities.pageSize}',
        'page': '$page',
        'showempty': '0',
        'folder': '0',
      }),
      'list',
      cancelToken: cancelToken,
    );
    final raw = json['list'];
    final entries = raw is List
        ? raw.whereType<Map>().map((item) {
            final map = Map<String, dynamic>.from(item);
            return _entry(request, map);
          }).toList()
        : const <CloudDriveEntry>[];
    final declared = json['has_more'];
    final hasMore = declared is int
        ? declared == 1
        : entries.length >= capabilities.pageSize;
    return CloudDrivePage(
      entries: entries,
      nextCursor: hasMore ? '${page + 1}' : null,
      hasMore: hasMore,
      sort: request.sort,
    );
  }

  @override
  Future<CloudDriveEntry> getFile(
    CloudDriveFileRequest request, {
    Object? cancelToken,
  }) async {
    final json = await _getJson(
      request.credential,
      Uri.https('pan.baidu.com', '/api/filemetas', {
        ..._webQuery(),
        'fsids': '[${request.fileId}]',
        'dlink': '0',
        'thumb': '1',
      }),
      'filemetas',
      cancelToken: cancelToken,
    );
    final info = json['info'];
    if (info is! List || info.isEmpty || info.first is! Map) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.fileMissing,
        '网盘里找不到这个文件',
      );
    }
    return _entry(
      CloudDriveListRequest(
        credential: request.credential,
        accountLocalId: request.accountLocalId,
        remoteAccountId: request.remoteAccountId,
        driveId: request.driveId,
        parentFileId: '',
      ),
      Map<String, dynamic>.from(info.first as Map),
    );
  }

  @override
  List<CloudDriveQualityChoice> qualityPlaceholders(
    CloudDrivePlaybackRequest request,
  ) {
    final kind = classifyCloudDriveFile(
      name: request.name ?? '',
      category: null,
    );
    if (kind == CloudDriveEntryKind.audio) return const [];
    return [
      const CloudDriveQualityChoice(
        id: 'original',
        label: '原画',
        transcoded: false,
        complete: false,
        availability: CloudDriveQualityAvailability.discovering,
        statusDetail: '正在确认',
      ),
      for (final item in transcodeLadder)
        CloudDriveQualityChoice(
          id: item.$1,
          label: item.$2,
          transcoded: true,
          complete: false,
          availability: CloudDriveQualityAvailability.discovering,
          statusDetail: '正在确认',
        ),
    ];
  }

  @override
  CloudDriveQualityDiscovery beginQualityDiscovery(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) {
    final first = Completer<CloudDrivePlaybackDescriptor?>();
    final choices = _discoverQualities(
      request,
      cancelToken,
      onVerified: (descriptor) {
        if (!first.isCompleted) first.complete(descriptor);
      },
    );
    unawaited(
      choices.then(
        (_) {
          if (!first.isCompleted) first.complete(null);
        },
        onError: (Object _) {
          if (!first.isCompleted) first.complete(null);
        },
      ),
    );
    return CloudDriveQualityDiscovery(
      choices: choices,
      firstVerified: first.future,
    );
  }

  @override
  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final preferred = request.preferredQualityId;
    if (preferred != null && preferred != 'original') {
      final cached = _fresh(request, preferred);
      if (cached != null) return _tagged(request, cached);
      // A known file path does not need the original download link. Duration
      // still has to come from somewhere so a short preview is not treated as
      // the full video.
      final meta = _canSkipMetadata(request)
          ? _metaFromRequest(request)
          : await _loadMeta(request, cancelToken, dlink: false);
      return _transcode(request, meta, preferred, cancelToken, explicit: true);
    }

    if (_hintedKind(request) == CloudDriveEntryKind.audio) {
      final meta = await _loadMeta(request, cancelToken, dlink: true);
      return _audio(request, meta, cancelToken);
    }

    if (preferred == null) {
      final cached = _fresh(request, 'auto');
      if (cached != null) return _tagged(request, cached);
    }

    if (preferred == 'original') {
      final meta = await _loadMeta(request, cancelToken, dlink: true);
      final original = await _original(request, meta, cancelToken);
      if (original == null) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '原画当前不可用',
        );
      }
      _remember(request, original, auto: false);
      return original;
    }

    return _resolveAuto(request, cancelToken);
  }

  /// Original probe and the first transcode share the wait. A slow original
  /// must not hold every HLS candidate behind it, and at most those two are
  /// in flight.
  Future<CloudDrivePlaybackDescriptor> _resolveAuto(
    CloudDrivePlaybackRequest request,
    Object? cancelToken,
  ) async {
    final hlsToken = CloudDriveCancelToken();
    if (cancelToken is CloudDriveCancelToken) {
      cancelToken.onCancel(hlsToken.cancel);
    }
    final probeToken = CloudDriveCancelToken();
    if (cancelToken is CloudDriveCancelToken) {
      cancelToken.onCancel(probeToken.cancel);
    }
    final metaFuture = _loadMeta(request, cancelToken, dlink: true);
    CloudDriveFailure? hlsStop;
    final firstRung = transcodeLadder.first.$1;
    final Future<CloudDrivePlaybackDescriptor?>? hlsFuture =
        _trustedVideo(request)
        ? _transcode(
            request,
            _metaFromRequest(request),
            firstRung,
            hlsToken,
            explicit: false,
          ).then<CloudDrivePlaybackDescriptor?>((value) => value).catchError((
            Object error,
          ) {
            if (error is CloudDriveFailure &&
                (error.kind == CloudDriveFailureKind.notLoggedIn ||
                    error.kind == CloudDriveFailureKind.rateLimited)) {
              hlsStop = error;
            }
            return null;
          })
        : null;

    _BaiduMeta? meta;
    CloudDriveFailure? metaFailure;
    try {
      meta = await metaFuture;
    } on CloudDriveFailure catch (error) {
      if (_stopsPlayback(error)) {
        hlsToken.cancel();
        rethrow;
      }
      metaFailure = error;
    }
    final kind = classifyCloudDriveFile(
      name: meta?.name ?? request.name ?? _fileName(request.pathHint),
      category: meta?.category,
    );
    if (kind == CloudDriveEntryKind.audio) {
      hlsToken.cancel();
      return _audio(request, meta, cancelToken);
    }
    try {
      final original = await _original(request, meta, probeToken).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          // The transcode candidate keeps the shared parent token. Only the
          // original probe is abandoned when its short budget runs out.
          probeToken.cancel();
          return null;
        },
      );
      if (original != null) {
        hlsToken.cancel();
        _remember(request, original, auto: true);
        return original;
      }
    } on CloudDriveFailure catch (error) {
      if (_stopsPlayback(error)) {
        hlsToken.cancel();
        rethrow;
      }
      metaFailure ??= error;
    }
    if (hlsFuture != null) {
      final hls = await hlsFuture;
      if (hlsStop != null &&
          (hlsStop!.kind == CloudDriveFailureKind.notLoggedIn ||
              hls == null &&
                  hlsStop!.kind == CloudDriveFailureKind.rateLimited)) {
        throw hlsStop!;
      }
      if (hls != null) {
        _remember(request, hls, auto: true);
        return hls;
      }
    }
    CloudDriveFailure? last = metaFailure;
    CloudDrivePlaybackDescriptor? selected;
    final found = <CloudDriveQualityChoice>[];
    final ladder = hlsFuture == null
        ? transcodeLadder
        : transcodeLadder.skip(1);
    for (final item in ladder) {
      try {
        final descriptor = await _transcode(
          request,
          meta,
          item.$1,
          cancelToken,
          explicit: false,
        );
        found.add(descriptor.quality);
        selected ??= descriptor;
        break;
      } on CloudDriveFailure catch (error) {
        if (error.kind == CloudDriveFailureKind.notLoggedIn ||
            error.kind == CloudDriveFailureKind.rateLimited) {
          rethrow;
        }
        last = error;
        found.add(
          CloudDriveQualityChoice(
            id: item.$1,
            label: item.$2,
            transcoded: true,
            complete: false,
            availability: CloudDriveQualityAvailability.unavailable,
            statusDetail: error.message,
          ),
        );
        if (error.kind == CloudDriveFailureKind.transcoding) continue;
      }
    }
    if (selected == null) {
      throw last ??
          const CloudDriveFailure(
            CloudDriveFailureKind.unsupported,
            '这个文件当前不能用原生播放器播放',
          );
    }
    _remember(request, selected, auto: true);
    return selected.copyWith(qualities: found);
  }

  @override
  Future<List<CloudDriveQualityChoice>> discoverQualities(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) {
    return beginQualityDiscovery(request, cancelToken: cancelToken).choices;
  }

  Future<List<CloudDriveQualityChoice>> _discoverQualities(
    CloudDrivePlaybackRequest request,
    Object? cancelToken, {
    required void Function(CloudDrivePlaybackDescriptor descriptor) onVerified,
  }) async {
    final kind = classifyCloudDriveFile(
      name: request.name ?? '',
      category: null,
    );
    if (kind == CloudDriveEntryKind.audio) return const [];
    _BaiduMeta? meta;
    try {
      meta = await _loadMeta(request, cancelToken, dlink: true);
    } on CloudDriveFailure catch (error) {
      if (error.kind == CloudDriveFailureKind.notLoggedIn) rethrow;
      meta = null;
    }
    final found = <CloudDriveQualityChoice>[];
    final originalToken = CloudDriveCancelToken();
    final removeCancel = cancelToken is CloudDriveCancelToken
        ? cancelToken.onCancel(originalToken.cancel)
        : null;
    try {
      final original =
          _fresh(request, 'original') ??
          await _original(request, meta, originalToken).timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              originalToken.cancel();
              return null;
            },
          );
      if (original != null) {
        _remember(request, original, auto: false);
        found.add(original.quality);
        onVerified(original);
      } else {
        found.add(
          const CloudDriveQualityChoice(
            id: 'original',
            label: '原画',
            transcoded: false,
            complete: false,
            availability: CloudDriveQualityAvailability.unavailable,
            statusDetail: '原画当前不可用，可稍后重试',
          ),
        );
      }
    } on CloudDriveFailure catch (error) {
      if (_stopsPlayback(error)) rethrow;
      found.add(
        CloudDriveQualityChoice(
          id: 'original',
          label: '原画',
          transcoded: false,
          complete: false,
          availability: CloudDriveQualityAvailability.unavailable,
          statusDetail: error.message,
        ),
      );
    } finally {
      removeCancel?.call();
    }
    for (final item in transcodeLadder) {
      if (cancelToken is CloudDriveCancelToken && cancelToken.isCancelled) {
        break;
      }
      final cached = _fresh(request, item.$1);
      if (cached != null) {
        found.add(cached.quality);
        onVerified(cached);
        continue;
      }
      try {
        final descriptor = await _transcode(
          request,
          meta,
          item.$1,
          cancelToken,
          explicit: false,
        );
        found.add(descriptor.quality);
        onVerified(descriptor);
      } on CloudDriveFailure catch (error) {
        if (error.kind == CloudDriveFailureKind.notLoggedIn) rethrow;
        found.add(
          CloudDriveQualityChoice(
            id: item.$1,
            label: item.$2,
            transcoded: true,
            complete: false,
            availability: CloudDriveQualityAvailability.unavailable,
            statusDetail: error.message,
          ),
        );
        if (error.kind == CloudDriveFailureKind.rateLimited) break;
      }
    }
    return found;
  }

  @override
  Future<List<CloudDriveSubtitleTrack>> discoverSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final catalog = await discoverSubtitleCatalog(
      request,
      cancelToken: cancelToken,
    );
    return catalog.tracks;
  }

  @override
  Future<CloudDriveSubtitleCatalog> discoverSubtitleCatalog(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    // Official and sidecar answers stay independent. The official directory
    // is finished before the sidecar walk starts here only so a scripted
    // client stays ordered; the subtitle panel calls the official method
    // alone and does not wait on the directory scan.
    final official = await discoverOfficialSubtitles(
      request,
      cancelToken: cancelToken,
    );
    final sidecars = await discoverSidecarCatalog(
      request,
      cancelToken: cancelToken,
    );
    final notes = <String>[
      if (official.status != CloudDriveOfficialSubtitleStatus.ready &&
          official.status != CloudDriveOfficialSubtitleStatus.unsupported &&
          official.message != null)
        official.message!,
      if (sidecars.warning != null) sidecars.warning!,
    ];
    return CloudDriveSubtitleCatalog(
      tracks: <CloudDriveSubtitleTrack>[...official.tracks, ...sidecars.tracks],
      warning: notes.isEmpty ? null : notes.join('；'),
      official: official,
    );
  }

  @override
  Future<CloudDriveOfficialSubtitleDiscovery> discoverOfficialSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    try {
      final located = await _officialPath(request, cancelToken);
      final tokenKey =
          '${request.remoteAccountId}|${_sessionFingerprint(request.credential)}';
      final token = await _bdstoken(
        request.credential,
        request.remoteAccountId,
        cancelToken,
      );
      final response = await _send(
        request.credential,
        CloudDriveHttpRequest(
          method: 'GET',
          uri: Uri.https('pan.baidu.com', '/api/streaming', {
            ..._webQuery(),
            'path': located.path,
            'type': subtitlePlaylistType,
            'isplayer': '1',
            'check_blue': '1',
            'bdstoken': token,
          }),
          headers: const {'User-Agent': browserUserAgent},
          readMode: CloudDriveReadMode.text,
          maxBytes: 1024 * 1024,
          timeout: const Duration(seconds: 20),
        ),
        cancelToken,
      );
      final discovery = _officialDiscovery(response, request, located.revision);
      if (discovery.status == CloudDriveOfficialSubtitleStatus.loginRequired) {
        _bdstokenLoads.remove(tokenKey);
      }
      developer.log(
        'Baidu subtitle directory status=${discovery.status.name} '
        'tracks=${discovery.tracks.length}',
        name: 'cloud_drive.subtitles',
      );
      return discovery;
    } on CloudDriveFailure catch (error) {
      return _officialFromFailure(error);
    }
  }

  @override
  Future<CloudDriveSubtitleCatalog> discoverSidecarCatalog(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final path = request.pathHint;
    final parent = baiduParentPath(path);
    final videoName = request.name ?? _fileName(path ?? '');
    if (parent == null || videoName.isEmpty) {
      return const CloudDriveSubtitleCatalog(
        tracks: <CloudDriveSubtitleTrack>[],
      );
    }
    final tracks = <CloudDriveSubtitleTrack>[];
    var cursor = '1';
    var truncated = false;
    // Keep the original five-page sidecar scan. A longer walk is not used.
    for (var page = 0; page < 5; page++) {
      final listed = await listChildren(
        CloudDriveListRequest(
          credential: request.credential,
          accountLocalId: request.accountLocalId,
          remoteAccountId: request.remoteAccountId,
          driveId: request.driveId,
          parentFileId: parent,
          cursor: cursor,
          pathHint: parent,
        ),
        cancelToken: cancelToken,
      );
      for (final entry in listed.entries) {
        if (entry.kind != CloudDriveEntryKind.subtitle) continue;
        final analysis = SubtitleFileMatcher.analyzeStems(
          videoStem: _stem(videoName),
          subtitleStem: _stem(entry.name),
        );
        if (analysis.grade == SubtitleMatchGrade.rejected) continue;
        tracks.add(
          CloudDriveSubtitleTrack(
            id: 'sidecar-${entry.fileId}',
            label: entry.name,
            language: analysis.languageCode,
            format: _extension(entry.name).replaceFirst('.', ''),
            origin: CloudDriveSubtitleOrigin.sidecar,
            fileId: entry.fileId,
            pathHint: entry.pathHint,
            revision: entry.revision,
            autoSelect: analysis.grade == SubtitleMatchGrade.autoMatch,
          ),
        );
      }
      if (!listed.hasMore || listed.nextCursor == null) {
        truncated = false;
        break;
      }
      cursor = listed.nextCursor!;
      truncated = page + 1 >= 5;
    }
    return CloudDriveSubtitleCatalog(
      tracks: tracks,
      warning: truncated ? '同目录只核对了前 5 页，后面还有文件，不能据此认为没有字幕' : null,
    );
  }

  Future<({String path, String revision})> _officialPath(
    CloudDrivePlaybackRequest request,
    Object? cancelToken,
  ) async {
    _BaiduMeta? meta;
    try {
      meta = await _loadMeta(request, cancelToken, dlink: false);
    } on CloudDriveFailure catch (error) {
      if (error.kind == CloudDriveFailureKind.notLoggedIn) rethrow;
    }
    final path = meta?.path ?? request.pathHint;
    if (path == null || !path.startsWith('/')) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unsupported,
        '缺少网盘路径，无法读取官方字幕',
      );
    }
    // Metadata md5 is the file version. A card revision is only the fallback
    // so a renamed display title never becomes the path or the identity.
    return (path: path, revision: meta?.md5 ?? request.revision ?? '');
  }

  Future<String> _bdstoken(
    CloudDriveCredential credential,
    String remoteAccountId,
    Object? cancelToken,
  ) {
    final key = '$remoteAccountId|${_sessionFingerprint(credential)}';
    final running = _bdstokenLoads[key];
    if (running != null) return running;
    final future = _readBdstoken(credential, cancelToken);
    _bdstokenLoads[key] = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_bdstokenLoads[key], future)) {
            _bdstokenLoads.remove(key);
          }
        },
      ),
    );
    return future;
  }

  Future<String> _readBdstoken(
    CloudDriveCredential credential,
    Object? cancelToken,
  ) async {
    final page = await _send(
      credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: Uri.https('pan.baidu.com', '/disk/main'),
        headers: const {'User-Agent': browserUserAgent},
        readMode: CloudDriveReadMode.text,
        maxBytes: 2 * 1024 * 1024,
        timeout: const Duration(seconds: 20),
      ),
      cancelToken,
    );
    final fromPage = _bdstokenIn(page.text);
    if (fromPage != null) return fromPage;
    if (page.statusCode == 401 || _looksLikeLoginPage(page.text)) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '百度登录已失效，请重新登录',
      );
    }
    final variable = await _send(
      credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: Uri.https('pan.baidu.com', '/api/gettemplatevariable', {
          ..._webQuery(),
          'fields': '["bdstoken"]',
        }),
        headers: const {'User-Agent': browserUserAgent},
        timeout: const Duration(seconds: 20),
      ),
      cancelToken,
    );
    final json = variable.jsonMap;
    if (json != null) {
      final failure = baiduApiFailure('template', json);
      if (failure != null) throw failure;
      final result = json['result'];
      if (result is Map) {
        final token = _bdstokenIn(result['bdstoken']?.toString() ?? '');
        if (token != null) return token;
      }
    }
    final fallback = _bdstokenIn(variable.text);
    if (fallback != null) return fallback;
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '没有从当前百度会话读到字幕所需的会话值',
    );
  }

  CloudDriveOfficialSubtitleDiscovery _officialDiscovery(
    CloudDriveHttpResponse response,
    CloudDrivePlaybackRequest request,
    String revision,
  ) {
    if (response.statusCode == 401) {
      return const CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.loginRequired,
        message: '百度登录已失效，请重新登录',
      );
    }
    final json = response.jsonMap;
    if (json != null && json.containsKey('errno')) {
      final failure = baiduApiFailure('subtitle', json);
      if (failure != null) return _officialFromFailure(failure);
    }
    if (response.statusCode == 403) {
      return const CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.restricted,
        message: '当前账号没有权限读取官方字幕',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return const CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.failed,
        message: '官方字幕目录暂时没有返回',
      );
    }
    try {
      final tracks = parseBaiduSubtitleDirectory(
        response.text,
        base: response.finalUri,
        accountId: request.remoteAccountId,
        fileId: request.fileId,
        revision: revision,
      );
      return CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.ready,
        tracks: tracks,
      );
    } on CloudDriveFailure catch (error) {
      return _officialFromFailure(error);
    }
  }

  CloudDriveOfficialSubtitleDiscovery _officialFromFailure(
    CloudDriveFailure error,
  ) {
    switch (error.kind) {
      case CloudDriveFailureKind.notLoggedIn:
        return CloudDriveOfficialSubtitleDiscovery(
          status: CloudDriveOfficialSubtitleStatus.loginRequired,
          message: error.message,
        );
      case CloudDriveFailureKind.entitlement:
        return CloudDriveOfficialSubtitleDiscovery(
          status: CloudDriveOfficialSubtitleStatus.restricted,
          message: error.message,
        );
      default:
        return CloudDriveOfficialSubtitleDiscovery(
          status: CloudDriveOfficialSubtitleStatus.failed,
          message: error.message,
        );
    }
  }

  @override
  Future<String> readSubtitleText(
    CloudDriveSubtitleReadRequest request, {
    Object? cancelToken,
  }) async {
    final direct = request.track.remoteUri;
    final uri = direct ?? await _subtitleDownloadUri(request, cancelToken);
    if (uri == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '没有拿到字幕地址',
      );
    }
    final response = await _send(
      request.credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: uri,
        headers: const {'User-Agent': browserUserAgent},
        readMode: CloudDriveReadMode.text,
        maxBytes: cloudDriveSubtitleTextByteLimit,
        timeout: const Duration(seconds: 30),
      ),
      cancelToken,
    );
    if (response.statusCode == 401) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '需要重新登录后才能读取字幕',
      );
    }
    // A 403 on one address is not proof the account itself expired. The
    // track service may refresh the directory once and retry that track.
    if (response.statusCode == 403) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '字幕地址暂时无法读取',
      );
    }
    final decoded = SubtitleParser.decodeBytes(response.body);
    final playlist = subtitlePlaylistSegments(decoded, response.finalUri);
    if (playlist.isNotEmpty) {
      if (playlist.length > 200) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '字幕分片超过 200 段，已停止合并',
        );
      }
      final parts = <({Duration playlistStart, String body})>[];
      for (final segment in playlist) {
        final piece = await _send(
          request.credential,
          CloudDriveHttpRequest(
            method: 'GET',
            uri: segment.uri,
            readMode: CloudDriveReadMode.text,
            maxBytes: cloudDriveSubtitleTextByteLimit,
            timeout: const Duration(seconds: 30),
          ),
          cancelToken,
        );
        parts.add((
          playlistStart: segment.start,
          body: SubtitleParser.decodeBytes(piece.body),
        ));
      }
      return mergeSegmentedWebVtt(parts);
    }
    return interpretCloudDriveSubtitleBody(
      decoded,
      format: request.track.format,
    );
  }

  Future<Uri?> _subtitleDownloadUri(
    CloudDriveSubtitleReadRequest request,
    Object? cancelToken,
  ) async {
    final fileId = request.track.fileId;
    if (fileId == null || fileId.isEmpty) return null;
    final json = await _getJson(
      request.credential,
      Uri.https('pan.baidu.com', '/api/filemetas', {
        ..._webQuery(),
        'fsids': '[$fileId]',
        'dlink': '1',
      }),
      'filemetas',
      cancelToken: cancelToken,
    );
    final info = json['info'];
    if (info is! List || info.isEmpty || info.first is! Map) return null;
    final link = _optional(
      Map<String, dynamic>.from(info.first as Map)['dlink'],
    );
    if (link == null) return null;
    return Uri.tryParse(link);
  }

  Future<CloudDrivePlaybackDescriptor?> _original(
    CloudDrivePlaybackRequest request,
    _BaiduMeta? meta,
    Object? cancelToken,
  ) async {
    final dlink = meta?.dlink;
    if (dlink == null) return null;
    final uri = Uri.tryParse(dlink);
    if (uri == null || !uri.hasScheme) return null;
    final probed = await _probe(request.credential, uri, cancelToken);
    if (probed == null) return null;
    return _descriptor(
      request: request,
      meta: meta,
      uri: probed.uri,
      transport: CloudDriveTransport.progressive,
      qualityId: 'original',
      label: '原画',
      transcoded: false,
      seekable: probed.seekable,
      verifiedComplete: false,
      mediaKind: CloudDriveMediaKind.video,
    );
  }

  Future<CloudDrivePlaybackDescriptor> _audio(
    CloudDrivePlaybackRequest request,
    _BaiduMeta? meta,
    Object? cancelToken,
  ) async {
    final dlink = meta?.dlink;
    if (dlink == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unsupported,
        '没有拿到原始音频地址',
      );
    }
    final uri = Uri.tryParse(dlink);
    if (uri == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '音频地址无法识别',
      );
    }
    final probed = await _probe(request.credential, uri, cancelToken);
    if (probed == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '音频地址暂时无法读取',
      );
    }
    return _descriptor(
      request: request,
      meta: meta,
      uri: probed.uri,
      transport: CloudDriveTransport.progressive,
      qualityId: 'original',
      label: '原始音频',
      transcoded: false,
      seekable: probed.seekable,
      verifiedComplete: false,
      mediaKind: CloudDriveMediaKind.audio,
    );
  }

  Future<CloudDrivePlaybackDescriptor> _transcode(
    CloudDrivePlaybackRequest request,
    _BaiduMeta? meta,
    String type,
    Object? cancelToken, {
    required bool explicit,
  }) async {
    final cached = _fresh(request, type);
    if (cached != null) return _tagged(request, cached);
    final path = meta?.path ?? request.pathHint;
    if (path == null || path.isEmpty) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unsupported,
        '缺少文件路径，无法读取转码流',
      );
    }
    final label =
        transcodeLadder
            .where((item) => item.$1 == type)
            .map((item) => item.$2)
            .firstOrNull ??
        type;
    final response = await _send(
      request.credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: Uri.https('pan.baidu.com', '/api/streaming', {
          ..._webQuery(),
          'path': path,
          'type': type,
        }),
        readMode: CloudDriveReadMode.text,
      ),
      cancelToken,
      connectionScope: request.accountLocalId,
    );
    if (response.statusCode == 429) {
      throw mapCloudHttpStatus(
        429,
        retryAfter: response.headers['retry-after'],
      );
    }
    final json = response.jsonMap;
    if (json != null && json.containsKey('errno')) {
      final failure = baiduApiFailure('streaming', json);
      if (failure != null) throw failure;
    }
    final playlist = response.text;
    if (!playlist.contains('#EXTM3U')) {
      throw CloudDriveFailure(
        explicit
            ? CloudDriveFailureKind.unavailable
            : CloudDriveFailureKind.unsupported,
        explicit ? '所选画质暂时不可用' : '这个画质没有返回播放列表',
      );
    }
    if (json?['adToken'] != null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.previewOnly,
        '当前只拿到试看流，不能当作完整视频播放',
      );
    }
    final assessment = assessBaiduPlaylist(
      playlist,
      meta?.durationMs ?? request.durationMs,
    );
    if (assessment.isPreview) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.previewOnly,
        '当前只拿到试看流，不能当作完整视频播放',
      );
    }
    final descriptor = _descriptor(
      request: request,
      meta: meta,
      uri: response.finalUri,
      transport: CloudDriveTransport.hls,
      qualityId: type,
      label: label,
      transcoded: true,
      seekable: true,
      verifiedComplete: assessment.verifiedComplete,
      mediaKind: CloudDriveMediaKind.video,
      manifest: CloudDriveManifestSnapshot(
        text: playlist,
        baseUri: response.finalUri,
        fetchedAt: _now(),
      ),
    );
    _remember(request, descriptor, auto: false);
    return descriptor;
  }

  CloudDrivePlaybackDescriptor _descriptor({
    required CloudDrivePlaybackRequest request,
    required _BaiduMeta? meta,
    required Uri uri,
    required CloudDriveTransport transport,
    required String qualityId,
    required String label,
    required bool transcoded,
    required bool seekable,
    required bool verifiedComplete,
    required CloudDriveMediaKind mediaKind,
    CloudDriveManifestSnapshot? manifest,
  }) {
    final quality = CloudDriveQualityChoice(
      id: qualityId,
      label: label,
      transcoded: transcoded,
      complete: true,
    );
    return CloudDrivePlaybackDescriptor(
      upstreamUri: uri,
      transport: transport,
      quality: quality,
      fileId: request.fileId,
      revision: meta?.md5 ?? request.revision ?? request.fileId,
      complete: true,
      seekable: seekable,
      userAgent: webUserAgent,
      referer: 'https://pan.baidu.com/disk/main',
      cookies: request.credential.cookies,
      providerId: providerId,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      pathHint: meta?.path ?? request.pathHint,
      transcoded: transcoded,
      qualities: [quality],
      durationMs: meta?.durationMs ?? request.durationMs,
      sizeBytes: meta?.size ?? request.size,
      mediaKind: mediaKind,
      verifiedComplete: verifiedComplete,
      playbackSessionId: request.playbackSessionId ?? '',
      manifest: manifest,
    );
  }

  bool _trustedVideo(CloudDrivePlaybackRequest request) {
    final name = request.name ?? _fileName(request.pathHint);
    if (request.fileId.isEmpty) return false;
    if ((request.pathHint ?? '').isEmpty) return false;
    return classifyCloudDriveFile(name: name, category: null) ==
        CloudDriveEntryKind.video;
  }

  bool _canSkipMetadata(CloudDrivePlaybackRequest request) {
    return _trustedVideo(request) && (request.durationMs ?? 0) > 0;
  }

  CloudDriveEntryKind _hintedKind(CloudDrivePlaybackRequest request) {
    return classifyCloudDriveFile(
      name: request.name ?? _fileName(request.pathHint),
      category: null,
    );
  }

  _BaiduMeta _metaFromRequest(CloudDrivePlaybackRequest request) {
    return _BaiduMeta(
      raw: const <String, dynamic>{},
      name: request.name ?? _fileName(request.pathHint),
      path: request.pathHint,
      md5: request.revision,
      durationMs: request.durationMs,
      size: request.size,
    );
  }

  String _fileName(String? path) {
    if (path == null || path.isEmpty) return '';
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  String _verifiedKey(CloudDrivePlaybackRequest request, String qualityId) {
    return '${request.accountLocalId}|${request.remoteAccountId}|${request.driveId}|'
        '${request.fileId}|${request.revision ?? ''}|$qualityId|'
        '${cloudDriveCredentialStamp(request.credential)}';
  }

  CloudDrivePlaybackDescriptor? _fresh(
    CloudDrivePlaybackRequest request,
    String qualityId,
  ) {
    final hit = _verified[_verifiedKey(request, qualityId)];
    if (hit == null) return null;
    final age = _now().difference(hit.at);
    final expires = hit.descriptor.expiresAt;
    final fresh =
        age >= Duration.zero &&
        age < const Duration(minutes: 2) &&
        (expires == null ||
            expires.isAfter(_now().add(const Duration(seconds: 15))));
    if (!fresh) {
      _verified.remove(_verifiedKey(request, qualityId));
      return null;
    }
    return hit.descriptor;
  }

  void _remember(
    CloudDrivePlaybackRequest request,
    CloudDrivePlaybackDescriptor descriptor, {
    required bool auto,
  }) {
    final stamped = (descriptor: descriptor, at: _now());
    _verified[_verifiedKey(request, descriptor.quality.id)] = stamped;
    if (auto) _verified[_verifiedKey(request, 'auto')] = stamped;
  }

  CloudDrivePlaybackDescriptor _tagged(
    CloudDrivePlaybackRequest request,
    CloudDrivePlaybackDescriptor descriptor,
  ) {
    final session = request.playbackSessionId;
    if (session == null || session.isEmpty) return descriptor;
    return descriptor.copyWith(playbackSessionId: session);
  }

  Future<_BaiduMeta?> _loadMeta(
    CloudDrivePlaybackRequest request,
    Object? cancelToken, {
    required bool dlink,
  }) {
    final caller = cancelToken is CloudDriveCancelToken ? cancelToken : null;
    return _metaFlights.run(
      _verifiedKey(request, dlink ? 'meta-dlink' : 'meta'),
      (token) => _loadMetaOnce(request, token, dlink: dlink),
      caller: caller,
    );
  }

  Future<_BaiduMeta?> _loadMetaOnce(
    CloudDrivePlaybackRequest request,
    CloudDriveCancelToken token, {
    required bool dlink,
  }) async {
    final json = await _getJson(
      request.credential,
      Uri.https('pan.baidu.com', '/api/filemetas', {
        ..._webQuery(),
        'fsids': '[${request.fileId}]',
        'dlink': dlink ? '1' : '0',
      }),
      'filemetas',
      cancelToken: token,
      connectionScope: request.accountLocalId,
    );
    final info = json['info'];
    if (info is! List || info.isEmpty || info.first is! Map) return null;
    final map = Map<String, dynamic>.from(info.first as Map);
    final category = map['category'];
    return _BaiduMeta(
      raw: map,
      dlink: _optional(map['dlink']),
      md5: _optional(map['md5']),
      path: _optional(map['path']) ?? request.pathHint,
      name: _optional(map['server_filename']) ?? request.name ?? '',
      durationMs: baiduDurationToMs(map['duration']) ?? request.durationMs,
      size: map['size'] is int
          ? map['size'] as int
          : int.tryParse('${map['size']}'),
      category: category is int ? category : int.tryParse('$category'),
    );
  }

  Future<({Uri uri, bool seekable})?> _probe(
    CloudDriveCredential credential,
    Uri uri,
    Object? cancelToken,
  ) async {
    final response = await _send(
      credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: uri,
        headers: {
          'User-Agent': webUserAgent,
          'Referer': 'https://pan.baidu.com/disk/main',
        },
        range: (0, 1),
        readMode: CloudDriveReadMode.probe,
        maxBytes: 64,
      ),
      cancelToken,
    );
    if (response.statusCode == 401) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '百度登录已失效，请重新登录',
      );
    }
    // 403 here is "no original stream", not proof the account itself is dead.
    if (response.statusCode == 403) return null;
    if (response.statusCode != 200 && response.statusCode != 206) return null;
    if (looksLikeHtmlOrJsonError(response)) return null;
    final type = response.headers['content-type'] ?? '';
    if (type.contains('text/html') || type.contains('application/json')) {
      return null;
    }
    return (
      uri: response.finalUri,
      seekable:
          response.statusCode == 206 ||
          (response.headers['accept-ranges'] ?? '').contains('bytes'),
    );
  }

  CloudDriveEntry _entry(
    CloudDriveListRequest request,
    Map<String, dynamic> map,
  ) {
    final isDir = map['isdir'] == 1 || map['isdir'] == true;
    final name = '${map['server_filename'] ?? map['filename'] ?? ''}'.trim();
    final category = map['category'];
    final parsedCategory = category is int
        ? category
        : int.tryParse('$category');
    final kind = isDir
        ? CloudDriveEntryKind.folder
        : classifyCloudDriveFile(name: name, category: parsedCategory);
    final thumbs = map['thumbs'];
    String? thumb;
    if (thumbs is Map) {
      thumb =
          _optional(thumbs['url3']) ??
          _optional(thumbs['url2']) ??
          _optional(thumbs['url1']);
    }
    final mtime = map['server_mtime'];
    return CloudDriveEntry(
      providerId: id,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      fileId: '${map['fs_id'] ?? ''}',
      parentFileId: request.parentFileId,
      pathHint: _optional(map['path']),
      name: name.isEmpty ? '未命名' : name,
      kind: kind,
      size: map['size'] is int
          ? map['size'] as int
          : int.tryParse('${map['size']}'),
      modifiedAt: mtime is int
          ? DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true)
          : null,
      durationMs: baiduDurationToMs(map['duration']),
      thumbnailRef: thumb,
      revision: _optional(map['md5']),
    );
  }

  Future<Map<String, dynamic>> _getJson(
    CloudDriveCredential credential,
    Uri uri,
    String api, {
    Object? cancelToken,
    String? connectionScope,
  }) async {
    final response = await _send(
      credential,
      CloudDriveHttpRequest(method: 'GET', uri: uri),
      cancelToken,
      connectionScope: connectionScope,
    );
    if (response.statusCode == 429) {
      throw mapCloudHttpStatus(
        429,
        retryAfter: response.headers['retry-after'],
      );
    }
    final json = response.jsonMap;
    if (json == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '百度网盘返回了无法识别的内容',
      );
    }
    final failure = baiduApiFailure(api, json);
    if (failure != null) throw failure;
    return json;
  }

  Future<CloudDriveHttpResponse> _send(
    CloudDriveCredential credential,
    CloudDriveHttpRequest request,
    Object? cancelToken, {
    String? connectionScope,
  }) {
    Map<String, String> headersFor(Uri uri) {
      final cookie = credential.headerFor(uri);
      return {
        'User-Agent': webUserAgent,
        'Referer': 'https://pan.baidu.com/disk/main',
        if (cookie.isNotEmpty) 'Cookie': cookie,
        ...request.headers,
      };
    }

    return _http.send(
      CloudDriveHttpRequest(
        method: request.method,
        uri: request.uri,
        headersFor: headersFor,
        body: request.body,
        timeout: request.timeout,
        range: request.range,
        readMode: request.readMode,
        maxBytes: request.maxBytes,
        connectionScope: connectionScope ?? request.connectionScope,
      ),
      cancelToken: cancelToken,
    );
  }

  Map<String, String> _webQuery() => {
    'clienttype': '0',
    'app_id': webAppId,
    'web': '1',
    'channel': 'chunlei',
  };
}

class _BaiduMeta {
  const _BaiduMeta({
    required this.raw,
    required this.name,
    this.dlink,
    this.md5,
    this.path,
    this.durationMs,
    this.size,
    this.category,
  });

  final Map<String, dynamic> raw;
  final String name;
  final String? dlink;
  final String? md5;
  final String? path;
  final int? durationMs;
  final int? size;
  final int? category;
}

bool _stopsPlayback(CloudDriveFailure error) {
  return error.kind == CloudDriveFailureKind.notLoggedIn ||
      error.kind == CloudDriveFailureKind.rateLimited ||
      error.kind == CloudDriveFailureKind.fileMissing;
}

/// Maps one Baidu errno in the context of the API that returned it.
///
/// Membership wording is reserved for streaming responses that specifically
/// refuse a quality. The same number on file metadata stays an ordinary
/// refusal so a large file is not reported as "no permission".
CloudDriveFailure? baiduApiFailure(String api, Map<String, dynamic> json) {
  final errno = json['errno'];
  final code = errno is int ? errno : int.tryParse('$errno') ?? 0;
  if (code == 0) return null;
  if (code == -6 || code == -9 || code == 31045) {
    return const CloudDriveFailure(
      CloudDriveFailureKind.notLoggedIn,
      '百度登录已失效，请重新登录',
    );
  }
  if (code == 31034 || code == 31299) {
    return const CloudDriveFailure(
      CloudDriveFailureKind.rateLimited,
      '百度网盘请求过于频繁，请稍后再试',
    );
  }
  if (api == 'streaming' && (code == 31326 || code == 31304 || code == 133)) {
    return const CloudDriveFailure(
      CloudDriveFailureKind.transcoding,
      '视频还在转码，请稍后再试',
    );
  }
  if (api == 'streaming' && (code == 31341 || code == 132)) {
    return const CloudDriveFailure(
      CloudDriveFailureKind.entitlement,
      '这个画质需要更高的会员权益，百度没有返回完整流',
    );
  }
  if (api != 'streaming' && (code == 31066 || code == -7 || code == -3)) {
    return const CloudDriveFailure(
      CloudDriveFailureKind.fileMissing,
      '网盘里找不到这个文件',
    );
  }
  return CloudDriveFailure(
    CloudDriveFailureKind.unavailable,
    '百度网盘拒绝了这次请求（$code）',
  );
}

/// Baidu file metadata reports duration in seconds.
int? baiduDurationToMs(Object? raw) {
  final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
  if (value == null || !value.isFinite || value <= 0) return null;
  return (value * 1000).round();
}

class BaiduPlaylistAssessment {
  const BaiduPlaylistAssessment({
    required this.isMaster,
    required this.isPreview,
    required this.verifiedComplete,
    this.mediaSeconds,
  });

  final bool isMaster;
  final bool isPreview;
  final bool verifiedComplete;
  final double? mediaSeconds;
}

/// A master playlist has no media duration of its own. Unknown duration is
/// not treated as a preview and is not treated as proof of a full copy.
BaiduPlaylistAssessment assessBaiduPlaylist(String playlist, int? durationMs) {
  final master = playlist.contains('#EXT-X-STREAM-INF');
  final matches = RegExp(r'#EXTINF:([0-9.]+)').allMatches(playlist);
  var seconds = 0.0;
  var positive = 0;
  for (final match in matches) {
    final value = double.tryParse(match.group(1) ?? '') ?? 0;
    if (value <= 0) continue;
    positive++;
    seconds += value;
  }
  if (master && positive == 0) {
    return const BaiduPlaylistAssessment(
      isMaster: true,
      isPreview: false,
      verifiedComplete: false,
    );
  }
  if (durationMs == null || durationMs <= 0 || positive == 0) {
    return BaiduPlaylistAssessment(
      isMaster: master,
      isPreview: false,
      verifiedComplete: false,
      mediaSeconds: positive > 0 ? seconds : null,
    );
  }
  final preview = !master && seconds * 1000 < durationMs * 0.8;
  return BaiduPlaylistAssessment(
    isMaster: master,
    isPreview: preview,
    verifiedComplete: !master && !preview,
    mediaSeconds: seconds,
  );
}

bool baiduPlaylistLooksLikePreview(String playlist, int? durationMs) =>
    assessBaiduPlaylist(playlist, durationMs).isPreview;

String baiduEncodeFidList(Iterable<String> ids) =>
    '[${ids.map(jsonEncode).join(',')}]';

String? baiduParentPath(String? path) {
  if (path == null || path.isEmpty) return null;
  final trimmed = path.endsWith('/') && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  final index = trimmed.lastIndexOf('/');
  if (index <= 0) return '/';
  return trimmed.substring(0, index);
}

/// Filemetas subtitle fields. Not the official catalog: that is
/// `M3U8_SUBTITLE_SRT`, read by [BaiduCloudDriveProvider.discoverOfficialSubtitles].
List<CloudDriveSubtitleTrack> baiduOfficialSubtitles(
  Map<String, dynamic>? info,
) {
  if (info == null) return const [];
  final tracks = <CloudDriveSubtitleTrack>[];
  final raw = info['subtitle_list'] ?? info['subtitles'];
  if (raw is List) {
    for (final item in raw.whereType<Map>()) {
      final map = Map<String, dynamic>.from(item);
      final link = _optional(map['url'] ?? map['dlink']);
      final format = _optional(map['format']) ?? 'srt';
      tracks.add(
        CloudDriveSubtitleTrack(
          id: 'official-${_optional(map['id']) ?? tracks.length}',
          label: _optional(map['title'] ?? map['language']) ?? '网盘字幕',
          language: _optional(map['language']),
          format: format,
          origin: CloudDriveSubtitleOrigin.provider,
          remoteUri: link == null ? null : Uri.tryParse(link),
          textAvailable: link != null,
          autoSelect: tracks.isEmpty,
        ),
      );
    }
  }
  final single = info['subtitle'];
  if (single is String && single.trim().isNotEmpty) {
    tracks.add(
      CloudDriveSubtitleTrack(
        id: 'official-single',
        label: '网盘字幕',
        format: 'srt',
        origin: CloudDriveSubtitleOrigin.provider,
        remoteUri: Uri.tryParse(single.trim()),
        textAvailable: true,
        autoSelect: tracks.isEmpty,
      ),
    );
  }
  return tracks;
}

String _fileName(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}

String _stem(String name) {
  final base = _fileName(name);
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return '';
  return name.substring(dot).toLowerCase();
}

String? _optional(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

/// Cookie values stay in this process only. The digest keeps two accounts
/// from sharing a bdstoken and drops the cache when the jar changes.
String _sessionFingerprint(CloudDriveCredential credential) {
  final raw = StringBuffer(credential.capturedAt?.toIso8601String() ?? '');
  for (final cookie in credential.cookies) {
    raw
      ..write('|')
      ..write(cookie.name)
      ..write('=')
      ..write(cookie.value)
      ..write('@')
      ..write(cookie.domain);
  }
  return sha256.convert(utf8.encode(raw.toString())).toString();
}

String? _bdstokenIn(String text) {
  final trimmed = text.trim();
  if (RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(trimmed)) return trimmed;
  for (final pattern in <RegExp>[
    RegExp('''bdstoken["']?\\s*[:=]\\s*["']([A-Za-z0-9_-]+)["']'''),
    RegExp('''bdstoken["']\\s*,\\s*["']([A-Za-z0-9_-]+)["']'''),
  ]) {
    final match = pattern.firstMatch(text);
    final token = match?.group(1);
    if (token != null && token.isNotEmpty) return token;
  }
  return null;
}

bool _looksLikeLoginPage(String text) {
  final lower = text.toLowerCase();
  return lower.contains('passport.baidu.com') || text.contains('扫码登录');
}
