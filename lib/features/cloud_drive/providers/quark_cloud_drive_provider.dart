import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../models/cloud_drive_media_kind.dart';
import '../models/cloud_drive_models.dart';
import '../models/cloud_drive_quality_order.dart';
import '../../../utils/subtitle_file_matcher.dart';
import '../../../utils/subtitle_parser.dart';
import '../services/cloud_drive_subtitle_text.dart';
import '../services/quark_subtitle_text.dart';
import 'cloud_drive_http.dart';
import 'cloud_drive_provider.dart';

/// Quark returns either an address or an object for its preview field.
String? quarkThumbnailUrl(Map<String, dynamic> file) {
  String? address(Object? value) {
    if (value is Map) {
      for (final key in ['url', 'large', 'middle', 'small']) {
        final found = address(value[key]);
        if (found != null) return found;
      }
      return null;
    }
    if (value is! String) return null;
    final normalized = value.startsWith('//') ? 'https:$value' : value;
    final uri = Uri.tryParse(normalized);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty
        ? uri.toString()
        : null;
  }

  for (final key in ['thumbnail', 'preview_url', 'lbig_thumb', 'big_thumb']) {
    final found = address(file[key]);
    if (found != null) return found;
  }
  return null;
}

/// Quark Drive through the official web session.
///
/// The host, `pr=ucpro` and `fr=pc` are the public parameters the official
/// pan.quark.cn page sends. TV and Open OAuth are not used.
class QuarkCloudDriveProvider extends CloudDriveProvider {
  QuarkCloudDriveProvider({CloudDriveHttp? http})
    : _http = http ?? NetworkCloudDriveHttp();

  static const String providerId = 'quark';
  static const String apiOrigin = 'https://drive-pc.quark.cn/1/clouddrive';
  static const _originalQuality = CloudDriveQualityChoice(
    id: 'original',
    label: '原画',
    transcoded: false,
    complete: true,
  );

  /// Public desktop client user agent used by the official Quark page.
  static const String webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 '
      'Electron/18.3.5.4 Safari/537.36 Channel/pckk_other_ch';

  final CloudDriveHttp _http;
  String get apiBase => apiOrigin;
  String get clientProduct => 'ucpro';
  String get cookieRoot => 'quark.cn';
  String get requestUserAgent => webUserAgent;
  bool get supportsTranscodeApi => true;
  bool get preferTranscodedPlayback => false;
  bool get supportsOfficialSubtitleApi => true;
  CloudDriveCredential refreshedCredentialFor(
    CloudDriveCredential credential,
  ) => _effectiveCredential(credential);
  @override
  String get rootFileId => '0';
  final _sessions = <String, Map<String, CloudDriveCookie>>{};
  final _subtitleBodies = <String, String>{};
  final _bilingualSources =
      <
        String,
        ({CloudDriveSubtitleTrack source, CloudDriveSubtitleTrack translation})
      >{};

  CloudDriveCredential _effectiveCredential(CloudDriveCredential credential) {
    final changes = _sessions[cloudDriveCredentialStamp(credential)];
    if (changes == null || changes.isEmpty) return credential;
    final cookies = <String, CloudDriveCookie>{
      for (final cookie in credential.cookies) _cookieKey(cookie): cookie,
      ...changes,
    };
    return CloudDriveCredential(
      cookies: cookies.values.toList(),
      capturedAt: credential.capturedAt,
      secrets: credential.secrets,
    );
  }

  String _cookieKey(CloudDriveCookie cookie) =>
      '${cookie.name}|${(cookie.domain.startsWith('.') ? cookie.domain.substring(1) : cookie.domain).toLowerCase()}|${cookie.path}';

  @override
  CloudDriveHttp get thumbnailHttp => _http;

  @override
  String get thumbnailUserAgent => requestUserAgent;

  @override
  String get id => providerId;

  @override
  String get displayName => '夸克网盘';

  @override
  Uri get loginUri => Uri.https('pan.quark.cn', '/');

  @override
  CloudDriveCapabilities get capabilities =>
      const CloudDriveCapabilities(serverDateSort: true);

  @override
  Future<CloudDriveVerifiedSession> verifySession(
    CloudDriveCredential credential, {
    Object? cancelToken,
  }) async {
    // The website confirms the profile here, but current responses contain
    // nickname/avatarUri/mobilekps/config and no uid. The stable identity is
    // then the __uid cookie sent with that same account request. Neither
    // the cookie alone nor /member entitlement data proves a usable login.
    final accountUri = loginUri.replace(
      path: '/account/info',
      queryParameters: {'fr': 'pc', 'platform': 'pc'},
    );
    final account = await _getJson(
      credential,
      accountUri,
      cancelToken: cancelToken,
    );
    _throwQuark(account);
    final data = account['data'];
    final map = data is Map
        ? Map<String, dynamic>.from(data)
        : const <String, dynamic>{};
    final remoteId =
        _optional(map['uid']) ??
        _optional(map['user_id']) ??
        _optional(map['ucid']) ??
        _cookieAccountId(credential, accountUri);
    if (map.isEmpty || remoteId == null || remoteId == '0') {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '夸克网页会话还不能确认账号',
      );
    }
    await listChildren(
      CloudDriveListRequest(
        credential: credential,
        accountLocalId: '',
        remoteAccountId: remoteId,
        driveId: '0',
        parentFileId: '0',
      ),
      cancelToken: cancelToken,
    );
    final name = '${map['nickname'] ?? map['nick_name'] ?? ''}'.trim();
    return CloudDriveVerifiedSession(
      remoteAccountId: remoteId,
      displayName: name.isEmpty ? displayName : name,
      avatar: _optional(map['avatarUri']) ?? _optional(map['avatar']),
      driveId: '0',
      refreshedCredential: _effectiveCredential(credential),
    );
  }

  String? _cookieAccountId(CloudDriveCredential credential, Uri accountUri) {
    // headerFor applies domain/path/security checks, removes unsafe values,
    // and resolves duplicate names exactly as the account request did.
    for (final pair in credential.headerFor(accountUri).split(';')) {
      final entry = pair.trim();
      if (!entry.startsWith('__uid=')) continue;
      final value = _optional(entry.substring('__uid='.length));
      if (value == null || value == 'null' || value == 'undefined') return null;
      return value;
    }
    return null;
  }

  @override
  Future<CloudDrivePage> listChildren(
    CloudDriveListRequest request, {
    Object? cancelToken,
  }) async {
    final page = int.tryParse(request.cursor ?? '') ?? 1;
    final sortField = request.sort == CloudDriveSort.modified
        ? 'updated_at'
        : 'file_name';
    final direction = request.descending ? 'desc' : 'asc';
    final json = await _getJson(
      request.credential,
      _uri('/file/sort', {
        'pdir_fid': request.parentFileId.isEmpty ? '0' : request.parentFileId,
        '_size': '${capabilities.pageSize}',
        '_page': '$page',
        '_fetch_total': '1',
        '_sort': 'file_type:asc,$sortField:$direction',
        'fetch_all_file': '1',
        'fetch_risk_file_name': '1',
      }),
      cancelToken: cancelToken,
    );
    _throwQuark(json);
    final data = json['data'];
    final raw = data is Map ? data['list'] : null;
    final entries = raw is List
        ? raw.whereType<Map>().map((item) {
            return _entry(request, Map<String, dynamic>.from(item));
          }).toList()
        : const <CloudDriveEntry>[];
    final metadata = json['metadata'];
    final total = metadata is Map
        ? int.tryParse('${metadata['_total']}')
        : null;
    final hasMore = total != null
        ? page * capabilities.pageSize < total
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
      _uri('/file/info', {'fid': request.fileId}),
      cancelToken: cancelToken,
    );
    _throwQuark(json);
    final data = json['data'];
    if (data is! Map) {
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
        parentFileId: '${data['pdir_fid'] ?? ''}',
      ),
      Map<String, dynamic>.from(data),
    );
  }

  @override
  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final kind = classifyCloudDriveFile(
      name: request.name ?? '',
      category: null,
    );
    if (kind == CloudDriveEntryKind.audio) {
      final original = await _original(request, cancelToken);
      if (original == null) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.unsupported,
          '这个音频当前不能播放',
        );
      }
      const audioQuality = CloudDriveQualityChoice(
        id: 'original',
        label: '原始音频',
        transcoded: false,
        complete: true,
      );
      return original.copyWith(
        mediaKind: CloudDriveMediaKind.audio,
        quality: audioQuality,
        qualities: const [audioQuality],
      );
    }
    final wantsTranscode =
        request.preferredQualityId != null &&
        request.preferredQualityId != 'original';
    CloudDriveFailure? originalFailure;
    if (preferTranscodedPlayback && request.preferredQualityId == null) {
      try {
        return await _transcoded(request, cancelToken);
      } on CloudDriveFailure catch (error) {
        if (const {
          CloudDriveFailureKind.notLoggedIn,
          CloudDriveFailureKind.rateLimited,
          CloudDriveFailureKind.fileMissing,
        }.contains(error.kind)) {
          rethrow;
        }
        originalFailure = error;
      }
    }
    if (!wantsTranscode) {
      try {
        final original = await _original(request, cancelToken);
        if (original != null) return original;
      } on CloudDriveFailure catch (error) {
        if (error.kind == CloudDriveFailureKind.notLoggedIn ||
            error.kind == CloudDriveFailureKind.rateLimited ||
            error.kind == CloudDriveFailureKind.fileMissing) {
          rethrow;
        }
        originalFailure = error;
      }
      if (request.preferredQualityId == 'original') {
        throw originalFailure ??
            const CloudDriveFailure(
              CloudDriveFailureKind.unavailable,
              '原画当前不可用',
            );
      }
    }
    return _transcoded(request, cancelToken, fallback: originalFailure);
  }

  @override
  Future<List<CloudDriveQualityChoice>> discoverQualities(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    if (!supportsTranscodeApi) return const [_originalQuality];
    // Original playback must not hide the provider's available transcodes.
    return [
      _originalQuality,
      ...(await _loadTranscodes(request, cancelToken)).choices,
    ];
  }

  @override
  Future<List<int>> readThumbnail(
    CloudDriveFileRequest request,
    Uri uri, {
    Object? cancelToken,
  }) async {
    final response = await _send(
      request.credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: uri,
        headers: const {'Accept': 'image/*'},
        connectionScope: request.accountLocalId,
        readMode: CloudDriveReadMode.text,
        maxBytes: 8 * 1024 * 1024,
        timeout: const Duration(seconds: 12),
      ),
      cancelToken,
    );
    if (response.statusCode != 200) {
      throw mapCloudHttpStatus(response.statusCode);
    }
    return response.body;
  }

  @override
  Future<CloudDriveSubtitleCatalog> discoverSidecarCatalog(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final file = await getFile(
      CloudDriveFileRequest(
        credential: request.credential,
        accountLocalId: request.accountLocalId,
        remoteAccountId: request.remoteAccountId,
        driveId: request.driveId,
        fileId: request.fileId,
      ),
      cancelToken: cancelToken,
    );
    final tracks = <CloudDriveSubtitleTrack>[];
    var truncated = false;
    for (var page = 1; page <= 5; page++) {
      final json = await _getJson(
        request.credential,
        _uri('/file/sort/extension', {
          'pdir_fid': file.parentFileId,
          '_page': '$page',
          '_size': '200',
          '_fetch_total': '1',
          'file_ext': 'srt,vtt,ass,ssa',
          '_sort': 'file_name:asc',
        }),
        cancelToken: cancelToken,
      );
      _throwQuark(json);
      final data = json['data'];
      final list = data is Map ? data['list'] : null;
      if (list is! List) {
        throw CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '$displayName 没有返回可识别的字幕文件目录',
        );
      }
      for (final item in list.whereType<Map>()) {
        final name = '${item['file_name'] ?? ''}';
        final ext = name.split('.').last.toLowerCase();
        if (!const {'srt', 'vtt', 'ass', 'ssa'}.contains(ext)) continue;
        final match = SubtitleFileMatcher.analyzeStems(
          videoStem: _stem(file.name),
          subtitleStem: _stem(name),
        );
        if (match.grade == SubtitleMatchGrade.rejected) continue;
        final fid = _optional(item['fid']);
        if (fid == null) continue;
        tracks.add(
          CloudDriveSubtitleTrack(
            id: 'sidecar-$fid',
            label: name,
            format: ext,
            origin: CloudDriveSubtitleOrigin.sidecar,
            language: match.languageCode,
            fileId: fid,
            revision: _optional(item['updated_at']),
            autoSelect: match.grade == SubtitleMatchGrade.autoMatch,
          ),
        );
      }
      final metadata =
          json['metadata'] ?? (data is Map ? data['metadata'] : null);
      final total = metadata is Map
          ? num.tryParse('${metadata['_total']}')
          : null;
      final more = total != null ? page * 200 < total : list.length >= 200;
      truncated = more && page == 5;
      if (!more) break;
    }
    return CloudDriveSubtitleCatalog(
      tracks: tracks,
      warning: truncated ? '同目录只核对了前 5 页，后面还有字幕文件' : null,
    );
  }

  @override
  Future<CloudDriveOfficialSubtitleDiscovery> discoverOfficialSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    if (!supportsOfficialSubtitleApi) {
      return const CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.unsupported,
      );
    }
    try {
      // support_auto=3 selects the desktop player's existing-subtitle contract.
      // Without it check only returns capabilities, even when subtitles exist.
      // The web session uses fr=pc; fr=win requires a separate native login.
      // Discovery never submits generation, translation or export work.
      final checked = await _subtitleJson(
        request.credential,
        '/video/subtitle/check',
        {'fid': request.fileId, 'entry': 'video_player', 'support_auto': '3'},
        cancelToken,
      );
      final data = checked['data'];
      if (data is! Map) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '夸克没有返回可识别的 AI 字幕目录',
        );
      }
      final tracks = <CloudDriveSubtitleTrack>[];
      _collectOfficialTracks(data, request, 'existing', tracks);
      final taskIds = <String, bool?>{};
      final playInfo = data['subtitle_play_info'];
      if (playInfo is Map) {
        final sourceId = _optional(playInfo['transfer_task_id']);
        final translationId = _optional(playInfo['translate_task_id']);
        if (sourceId != null) taskIds[sourceId] = false;
        if (translationId != null && translationId != sourceId) {
          taskIds[translationId] = true;
        }
      }
      final tasks = data['task_list'];
      if (tasks is List) {
        for (final task in tasks.whereType<Map>().take(8)) {
          final taskId = _optional(task['task_id']);
          final status = '${task['task_status'] ?? ''}'.toLowerCase();
          if (taskId == null ||
              const {
                'failed',
                'error',
                'pending',
                'running',
                'processing',
              }.contains(status)) {
            continue;
          }
          taskIds.putIfAbsent(taskId, () => null);
        }
      }
      CloudDriveFailure? taskFailure;
      var unfinished = false;
      for (final task in taskIds.entries.take(8)) {
        try {
          final result = await _subtitleJson(
            request.credential,
            '/video/subtitle/result',
            {'task_id': task.key, 'entry': 'video_player'},
            cancelToken,
          );
          final content = result['data'];
          if (content is! Map) {
            throw const CloudDriveFailure(
              CloudDriveFailureKind.unavailable,
              '夸克没有返回可识别的 AI 字幕内容',
            );
          }
          final status = content['status'] ?? content['task_status'];
          if (status != null &&
              !const {
                '2',
                'success',
                'completed',
                'complete',
                'done',
              }.contains('$status'.toLowerCase())) {
            unfinished = true;
            continue;
          }
          final before = tracks.length;
          _collectOfficialTracks(
            content,
            request,
            task.key,
            tracks,
            translated: task.value,
          );
          if (tracks.length == before) {
            throw const CloudDriveFailure(
              CloudDriveFailureKind.unavailable,
              '夸克 AI 字幕内容无法识别，请稍后刷新',
            );
          }
        } on CloudDriveFailure catch (error) {
          // A bad translation must not hide an otherwise readable source.
          taskFailure = error;
        }
      }
      if (tracks.isEmpty && taskFailure != null) throw taskFailure;
      if (tracks.isEmpty && unfinished) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '夸克 AI 字幕尚未生成完成，请稍后刷新',
        );
      }
      final sources = tracks.where((t) => t.label.endsWith('（源语言）')).toList();
      if (sources.isNotEmpty) {
        final source = sources.first;
        for (final translation in tracks.toList()) {
          if (translation.label.endsWith('（源语言）') ||
              translation.language == null ||
              translation.language == source.language) {
            continue;
          }
          final id =
              'quark-ai-${sha256.convert(utf8.encode('${source.id}|${translation.id}|bilingual')).toString().substring(0, 24)}';
          if (_bilingualSources.length >= 16 &&
              !_bilingualSources.containsKey(id)) {
            _bilingualSources.remove(_bilingualSources.keys.first);
          }
          _bilingualSources[id] = (source: source, translation: translation);
          final languages = {source.language, translation.language};
          tracks.add(
            CloudDriveSubtitleTrack(
              id: id,
              label: languages.contains('zh-Hans') && languages.contains('en')
                  ? '夸克 AI · 中英双字'
                  : '夸克 AI · ${_subtitleLanguageLabel(source.language)} / ${_subtitleLanguageLabel(translation.language)}双语',
              format: 'srt',
              origin: CloudDriveSubtitleOrigin.provider,
              language: 'mul',
              fileId: request.fileId,
              revision: request.revision,
              isAi: true,
            ),
          );
        }
      }
      final restricted = data['accessible'] == false || data['accessible'] == 0;
      return CloudDriveOfficialSubtitleDiscovery(
        status: restricted && tracks.isEmpty
            ? CloudDriveOfficialSubtitleStatus.restricted
            : CloudDriveOfficialSubtitleStatus.ready,
        tracks: {for (final track in tracks) track.id: track}.values.toList(),
        message: restricted ? '当前夸克账号没有 AI 字幕读取权限' : taskFailure?.message,
      );
    } on CloudDriveFailure catch (error) {
      return CloudDriveOfficialSubtitleDiscovery(
        status: switch (error.kind) {
          CloudDriveFailureKind.notLoggedIn =>
            CloudDriveOfficialSubtitleStatus.loginRequired,
          CloudDriveFailureKind.entitlement =>
            CloudDriveOfficialSubtitleStatus.restricted,
          _ => CloudDriveOfficialSubtitleStatus.failed,
        },
        message: error.message,
      );
    }
  }

  Future<Map<String, dynamic>> _subtitleJson(
    CloudDriveCredential credential,
    String path,
    Map<String, String> params,
    Object? cancelToken,
  ) async {
    final response = await _send(
      credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: Uri.https('quick-note.quark.cn', path, {
          'pr': 'ucpro',
          'fr': 'pc',
          'req_id': const Uuid().v4(),
          ...params,
        }),
      ),
      cancelToken,
    );
    if (response.statusCode == 401 || response.statusCode == 429) {
      throw mapCloudHttpStatus(response.statusCode);
    }
    final json = response.jsonMap;
    if (response.statusCode == 403) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.entitlement,
        '当前夸克账号没有 AI 字幕读取权限',
      );
    }
    if (json == null || '${json['code']}' != '0' || json['success'] == false) {
      final message = '${json?['msg'] ?? json?['message'] ?? ''}'.toLowerCase();
      if (message.contains('login') || message.contains('登录')) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.notLoggedIn,
          '夸克登录已失效，请重新登录',
        );
      }
      if (message.contains('vip') ||
          message.contains('权益') ||
          message.contains('次数')) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.entitlement,
          '当前夸克账号没有 AI 字幕读取权限',
        );
      }
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '夸克 AI 字幕暂时无法读取，请稍后重试',
      );
    }
    return json;
  }

  void _collectOfficialTracks(
    Object? value,
    CloudDrivePlaybackRequest request,
    String taskId,
    List<CloudDriveSubtitleTrack> tracks, {
    String? language,
    bool? translated,
    int depth = 0,
  }) {
    if (depth > 5 || tracks.length >= 16) return;
    if (value is List) {
      for (final item in value.take(16)) {
        _collectOfficialTracks(
          item,
          request,
          taskId,
          tracks,
          language: language,
          translated: translated,
          depth: depth + 1,
        );
      }
      return;
    }
    if (value is! Map) return;
    final lang =
        _optional(value['lang']) ??
        _optional(value['language']) ??
        _optional(value['source_lang']) ??
        language;
    for (final key in [
      'subtitle_content',
      'subtitle_url',
      'subtitle_content_source',
      'subtitle_content_translate',
    ]) {
      final content = value[key];
      if (content is! String || content.trim().isEmpty) continue;
      final uri = Uri.tryParse(content);
      final remote = uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
          ? uri
          : null;
      String? body;
      if (remote == null) {
        try {
          body = decodeQuarkSubtitleBody(content);
        } on CloudDriveFailure {
          continue;
        }
        if (utf8.encode(body).length > 8 * 1024 * 1024) continue;
      }
      final isTranslation =
          key == 'subtitle_content_translate' ||
          (key != 'subtitle_content_source' &&
              (translated ??
                  (value['translate_lang'] != null &&
                      value['translate_lang'] != value['source_lang'])));
      final trackLang = isTranslation
          ? _optional(value['translate_lang']) ??
                _optional(value['target_lang']) ??
                lang
          : lang;
      final identity = [
        request.remoteAccountId,
        request.driveId,
        request.fileId,
        request.revision ?? '',
        taskId,
        key,
        trackLang ?? '',
      ].join('|');
      final id =
          'quark-ai-${sha256.convert(utf8.encode(identity)).toString().substring(0, 24)}';
      if (body != null) {
        if (_subtitleBodies.length >= 16 && !_subtitleBodies.containsKey(id)) {
          _subtitleBodies.remove(_subtitleBodies.keys.first);
        }
        _subtitleBodies[id] = body;
      }
      final normalizedLang =
          const {'cn': 'zh-Hans', 'jp': 'ja'}[trackLang] ?? trackLang;
      tracks.add(
        CloudDriveSubtitleTrack(
          id: id,
          label:
              '夸克 AI · ${_subtitleLanguageLabel(normalizedLang)}${isTranslation ? '' : '（源语言）'}',
          format:
              _optional(value['subtitle_format']) ??
              (body?.startsWith('WEBVTT') == true ? 'vtt' : 'srt'),
          language: normalizedLang,
          origin: CloudDriveSubtitleOrigin.provider,
          fileId: request.fileId,
          revision: request.revision,
          remoteUri: remote,
          isAi: true,
          autoSelect: true,
        ),
      );
    }
    for (final key in [
      'subtitle_list',
      'subtitles',
      'subtitle',
      'result',
      'subtitle_content_source',
      'subtitle_content_translate',
    ]) {
      final child = value[key];
      if (child is Map || child is List) {
        _collectOfficialTracks(
          child,
          request,
          taskId,
          tracks,
          language: lang,
          translated: translated,
          depth: depth + 1,
        );
      }
    }
  }

  @override
  Future<CloudDriveSubtitleCatalog> discoverSubtitleCatalog(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final official = await discoverOfficialSubtitles(
      request,
      cancelToken: cancelToken,
    );
    final sidecar = await discoverSidecarCatalog(
      request,
      cancelToken: cancelToken,
    );
    return CloudDriveSubtitleCatalog(
      tracks: [...official.tracks, ...sidecar.tracks],
      official: official,
      warning: sidecar.warning,
    );
  }

  @override
  Future<List<CloudDriveSubtitleTrack>> discoverSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async =>
      (await discoverSubtitleCatalog(request, cancelToken: cancelToken)).tracks;

  @override
  Future<String> readSubtitleText(
    CloudDriveSubtitleReadRequest request, {
    Object? cancelToken,
  }) async {
    if (request.track.origin == CloudDriveSubtitleOrigin.provider) {
      final pair = _bilingualSources[request.track.id];
      if (pair != null) {
        Future<String> read(CloudDriveSubtitleTrack track) => readSubtitleText(
          CloudDriveSubtitleReadRequest(
            credential: request.credential,
            accountLocalId: request.accountLocalId,
            remoteAccountId: request.remoteAccountId,
            driveId: request.driveId,
            track: track,
          ),
          cancelToken: cancelToken,
        );
        return mergeQuarkBilingualSubtitles(
          await read(pair.source),
          await read(pair.translation),
        );
      }
      final body = _subtitleBodies[request.track.id];
      if (body != null) return body;
      if (request.track.remoteUri == null) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '夸克字幕内容已失效，请刷新字幕列表',
        );
      }
    }
    var uri = request.track.remoteUri;
    if (uri == null && request.track.fileId != null) {
      final json = await _postJson(request.credential, _uri('/file/download'), {
        'fids': [request.track.fileId],
      }, cancelToken);
      _throwQuark(json);
      final data = json['data'];
      final link = data is List && data.isNotEmpty && data.first is Map
          ? _optional(data.first['download_url'])
          : null;
      uri = link == null ? null : Uri.tryParse(link);
    }
    if (uri == null ||
        !const {'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '$displayName 没有返回字幕地址',
      );
    }
    final response = await _send(
      request.credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: uri,
        connectionScope: request.accountLocalId,
        readMode: CloudDriveReadMode.text,
        maxBytes: 8 * 1024 * 1024,
      ),
      cancelToken,
    );
    if (response.statusCode != 200) {
      throw mapCloudHttpStatus(response.statusCode);
    }
    return interpretCloudDriveSubtitleBody(
      SubtitleParser.decodeBytes(response.body),
      format: request.track.format,
    );
  }

  String _subtitleLanguageLabel(String? language) =>
      const {
        'zh-Hans': '中文',
        'cn': '中文',
        'zh': '中文',
        'zh-CN': '中文',
        'zh-Hant': '繁体中文',
        'en': '英文',
        'ja': '日文',
        'ko': '韩文',
        'fr': '法文',
        'de': '德文',
        'es': '西班牙文',
        'ru': '俄文',
      }[language] ??
      language ??
      '字幕';

  Future<CloudDrivePlaybackDescriptor?> _original(
    CloudDrivePlaybackRequest request,
    Object? cancelToken,
  ) async {
    final json = await _postJson(request.credential, _uri('/file/download'), {
      'fids': [request.fileId],
    }, cancelToken);
    _throwQuark(json);
    final data = json['data'];
    if (data is! List || data.isEmpty || data.first is! Map) return null;
    final map = Map<String, dynamic>.from(data.first as Map);
    final link = _optional(map['download_url']);
    if (link == null) return null;
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final response = await _send(
      request.credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: uri,
        range: (0, 1),
        readMode: CloudDriveReadMode.probe,
        maxBytes: 512,
      ),
      cancelToken,
    );
    if (response.statusCode == 401) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '$displayName 登录已失效，请重新登录',
      );
    }
    if (response.statusCode == 403) return null;
    if (response.statusCode != 200 && response.statusCode != 206) return null;
    if (looksLikeHtmlOrJsonError(response)) return null;
    return _descriptor(
      request: request,
      uri: response.finalUri,
      transport: CloudDriveTransport.progressive,
      qualityId: 'original',
      label: '原画',
      transcoded: false,
      seekable:
          response.statusCode == 206 ||
          (response.headers['accept-ranges'] ?? '').contains('bytes'),
      revision: request.revision ?? request.fileId,
    ).copyWith(
      durationMs: _durationMs(map['duration']) ?? request.durationMs,
      sizeBytes: num.tryParse('${map['size']}')?.round() ?? request.size,
    );
  }

  Future<_QuarkTranscodes> _loadTranscodes(
    CloudDrivePlaybackRequest request,
    Object? cancelToken,
  ) async {
    if (!supportsTranscodeApi) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.unsupported,
        '$displayName 当前未提供可验证的转码画质，请使用原画',
      );
    }
    final json = await _postJson(request.credential, _uri('/file/v2/play'), {
      'fid': request.fileId,
      'resolutions': 'low,normal,high,super,2k,4k',
      'supports': 'fmp4,m3u8',
    }, cancelToken);
    _throwQuark(json);
    final data = json['data'];
    final raw = data is Map ? data['video_list'] : null;
    if (raw is! List || raw.isEmpty) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unsupported,
        '这个文件当前不能用原生播放器播放',
      );
    }
    final choices = <CloudDriveQualityChoice>[];
    final infos = <String, Map>{};
    final meta = data is Map ? data['meta'] : null;
    final durationMs = meta is Map ? _durationMs(meta['duration']) : null;
    for (final item in raw.whereType<Map>()) {
      final map = Map<String, dynamic>.from(item);
      final id = '${map['resolution'] ?? 'transcode'}';
      final status = '${map['trans_status'] ?? ''}'.toLowerCase();
      final pending =
          status.contains('transcoding') ||
          status == 'doing' ||
          status == 'pending';
      final denied = map['accessable'] == false || map['accessible'] == false;
      if (pending || denied) {
        choices.add(
          CloudDriveQualityChoice(
            id: id,
            label: '${_qualityLabel(id, null)} 转码',
            transcoded: true,
            complete: false,
            availability: CloudDriveQualityAvailability.unavailable,
            statusDetail: denied ? '当前账号没有此画质权益' : '视频正在转码，请稍后重试',
          ),
        );
        continue;
      }
      final info = map['video_info'];
      if (info is! Map) continue;
      final url = _optional(info['url']);
      if (url == null) continue;
      final uri = Uri.tryParse(url);
      if (uri == null) continue;
      final streamDuration = _durationMs(info['duration']);
      final expected = durationMs ?? request.durationMs;
      if (expected != null &&
          streamDuration != null &&
          streamDuration < expected * 0.8) {
        continue;
      }
      final height = num.tryParse('${info['height'] ?? ''}')?.round();
      final label = _qualityLabel(id, height);
      final choice = CloudDriveQualityChoice(
        id: id,
        label: '$label 转码',
        transcoded: true,
        complete: true,
      );
      choices.add(choice);
      infos[id] = info;
    }
    return _QuarkTranscodes(
      sortCloudDriveQualities(choices),
      infos,
      durationMs ?? request.durationMs,
    );
  }

  Future<CloudDrivePlaybackDescriptor> _transcoded(
    CloudDrivePlaybackRequest request,
    Object? cancelToken, {
    CloudDriveFailure? fallback,
  }) async {
    final catalog = await _loadTranscodes(request, cancelToken);
    final choices = catalog.choices;
    final infos = catalog.infos;
    if (infos.isEmpty) {
      if (choices.isNotEmpty) {
        throw CloudDriveFailure(
          choices.any((q) => q.statusDetail?.contains('权益') == true)
              ? CloudDriveFailureKind.entitlement
              : CloudDriveFailureKind.transcoding,
          choices.first.statusDetail ?? '当前没有可用的转码画质',
        );
      }
      throw fallback ??
          const CloudDriveFailure(
            CloudDriveFailureKind.previewOnly,
            '当前只拿到试看流，不能当作完整视频播放',
          );
    }
    final preferred = request.preferredQualityId;
    if (preferred != null &&
        preferred != 'original' &&
        !infos.containsKey(preferred)) {
      final unavailable = choices.where((q) => q.id == preferred).firstOrNull;
      throw CloudDriveFailure(
        unavailable?.statusDetail?.contains('权益') == true
            ? CloudDriveFailureKind.entitlement
            : CloudDriveFailureKind.unavailable,
        unavailable?.statusDetail ?? '没有可用的所选画质',
      );
    }
    final selected = preferred != null && infos.containsKey(preferred)
        ? choices.firstWhere((item) => item.id == preferred)
        : choices.firstWhere((q) => q.selectable);
    final info = infos[selected.id]!;
    final uri = Uri.parse(info['url'] as String);
    final hls =
        '${info['format']}'.toLowerCase() == 'm3u8' ||
        uri.path.toLowerCase().contains('.m3u8');
    final response = await _send(
      request.credential,
      CloudDriveHttpRequest(
        method: 'GET',
        uri: uri,
        readMode: hls ? CloudDriveReadMode.text : CloudDriveReadMode.probe,
        range: hls ? null : (0, 1),
        maxBytes: hls ? 2 * 1024 * 1024 : 512,
        connectionScope: request.accountLocalId,
      ),
      cancelToken,
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw mapCloudHttpStatus(response.statusCode);
    }
    if (looksLikeHtmlOrJsonError(response) ||
        (hls && !response.text.trimLeft().startsWith('#EXTM3U'))) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '夸克返回的内容不是可播放的视频',
      );
    }
    var measured = 0.0;
    if (hls) {
      for (final match in RegExp(
        r'#EXTINF:([0-9.]+)',
      ).allMatches(response.text)) {
        measured += double.tryParse(match.group(1)!) ?? 0;
      }
      if (catalog.durationMs != null &&
          measured > 0 &&
          measured * 1000 < catalog.durationMs! * 0.8) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.previewOnly,
          '夸克只返回了试看片段，无法作为完整视频播放',
        );
      }
    }
    return CloudDrivePlaybackDescriptor(
      upstreamUri: response.finalUri,
      transport: hls
          ? CloudDriveTransport.hls
          : CloudDriveTransport.progressive,
      quality: selected,
      fileId: request.fileId,
      revision: request.revision ?? request.fileId,
      complete: true,
      seekable: true,
      userAgent: requestUserAgent,
      referer: loginUri.toString(),
      cookies: _effectiveCredential(request.credential).cookies,
      providerId: id,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      pathHint: request.pathHint,
      transcoded: true,
      qualities: [_originalQuality, ...choices],
      durationMs: catalog.durationMs,
      verifiedComplete: hls && measured > 0 && catalog.durationMs != null,
      manifest: hls
          ? CloudDriveManifestSnapshot(
              text: response.text,
              baseUri: response.finalUri,
              fetchedAt: DateTime.now().toUtc(),
              mutable: !response.text.contains('#EXT-X-ENDLIST'),
            )
          : null,
    );
  }

  CloudDrivePlaybackDescriptor _descriptor({
    required CloudDrivePlaybackRequest request,
    required Uri uri,
    required CloudDriveTransport transport,
    required String qualityId,
    required String label,
    required bool transcoded,
    required bool seekable,
    required String revision,
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
      revision: revision,
      complete: true,
      seekable: seekable,
      userAgent: requestUserAgent,
      referer: loginUri.toString(),
      cookies: _effectiveCredential(request.credential).cookies,
      providerId: id,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      pathHint: request.pathHint,
      transcoded: transcoded,
      qualities: [quality],
    );
  }

  CloudDriveEntry _entry(
    CloudDriveListRequest request,
    Map<String, dynamic> map,
  ) {
    final fileType = map['file_type'];
    final isDir = map['dir'] == true || map['file'] == false || fileType == 0;
    final name = '${map['file_name'] ?? ''}'.trim();
    final category = map['category'];
    final parsedCategory = category is int
        ? category
        : int.tryParse('$category');
    final kind = isDir
        ? CloudDriveEntryKind.folder
        : classifyCloudDriveFile(name: name, category: parsedCategory);
    final updated = map['updated_at'];
    final millis = updated is int ? updated : int.tryParse('$updated');
    return CloudDriveEntry(
      providerId: id,
      accountLocalId: request.accountLocalId,
      remoteAccountId: request.remoteAccountId,
      driveId: request.driveId,
      fileId: '${map['fid'] ?? ''}',
      parentFileId: '${map['pdir_fid'] ?? request.parentFileId}',
      name: name.isEmpty ? '未命名' : name,
      kind: kind,
      size: map['size'] is int
          ? map['size'] as int
          : int.tryParse('${map['size']}'),
      modifiedAt: millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
      durationMs: _durationMs(map['duration']),
      thumbnailRef: quarkThumbnailUrl(map),
      revision: _optional(map['updated_at']),
    );
  }

  Uri _uri(String path, [Map<String, String>? extra]) {
    return Uri.parse(
      '$apiBase$path',
    ).replace(queryParameters: {'pr': clientProduct, 'fr': 'pc', ...?extra});
  }

  Future<Map<String, dynamic>> _getJson(
    CloudDriveCredential credential,
    Uri uri, {
    Object? cancelToken,
  }) async {
    final response = await _send(
      credential,
      CloudDriveHttpRequest(method: 'GET', uri: uri),
      cancelToken,
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _postJson(
    CloudDriveCredential credential,
    Uri uri,
    Map<String, dynamic> body,
    Object? cancelToken,
  ) async {
    final response = await _send(
      credential,
      CloudDriveHttpRequest(
        method: 'POST',
        uri: uri,
        headers: {'Content-Type': 'application/json'},
        body: utf8.encode(jsonEncode(body)),
      ),
      cancelToken,
    );
    return _decode(response);
  }

  Map<String, dynamic> _decode(CloudDriveHttpResponse response) {
    if (response.statusCode == 401) {
      throw mapCloudHttpStatus(401);
    }
    if (response.statusCode == 429) {
      throw mapCloudHttpStatus(
        429,
        retryAfter: response.headers['retry-after'],
      );
    }
    final json = response.jsonMap;
    if (json == null) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '$displayName 返回了无法识别的内容',
      );
    }
    if (response.statusCode >= 400) {
      _throwQuark({...json, 'status': response.statusCode});
      throw mapCloudHttpStatus(response.statusCode);
    }
    return json;
  }

  Future<CloudDriveHttpResponse> _send(
    CloudDriveCredential credential,
    CloudDriveHttpRequest request,
    Object? cancelToken,
  ) async {
    Map<String, String> headersFor(Uri uri) {
      final cookie = _effectiveCredential(credential).headerFor(uri);
      return {
        'User-Agent': requestUserAgent,
        'Referer': loginUri.toString(),
        'Origin': loginUri.origin,
        'Accept': 'application/json, text/plain, */*',
        if (cookie.isNotEmpty) 'Cookie': cookie,
        ...request.headers,
      };
    }

    final response = await _http.send(
      CloudDriveHttpRequest(
        method: request.method,
        uri: request.uri,
        headers: headersFor(request.uri),
        headersFor: headersFor,
        body: request.body,
        range: request.range,
        timeout: request.timeout,
        readMode: request.readMode,
        maxBytes: request.maxBytes,
        connectionScope: request.connectionScope,
      ),
      cancelToken: cancelToken,
    );
    if (response.cookies.isNotEmpty) {
      final previous = _effectiveCredential(credential);
      final stamp = cloudDriveCredentialStamp(credential);
      if (!_sessions.containsKey(stamp) && _sessions.length >= 16) {
        _sessions.remove(_sessions.keys.first);
      }
      final changes = _sessions.putIfAbsent(stamp, () => {});
      for (final cookie in response.cookies) {
        if (cookie.matches(response.finalUri) &&
            (cookie.domain == cookieRoot ||
                cookie.domain.endsWith('.$cookieRoot'))) {
          changes[_cookieKey(cookie)] = cookie;
        }
      }
      final next = _effectiveCredential(credential);
      if (cloudDriveCredentialStamp(previous) !=
          cloudDriveCredentialStamp(next)) {
        _sessions[cloudDriveCredentialStamp(next)] = changes;
        await onCredentialRefreshed?.call(previous, next);
      }
    }
    return response;
  }

  void _throwQuark(Map<String, dynamic> json) {
    final status = json['status'];
    final code = json['code'];
    final numeric = code is int ? code : int.tryParse('$code');
    final http = status is int ? status : int.tryParse('$status') ?? 200;
    final codeText = code?.toString().toUpperCase();
    // /account/info returns {success: true, code: "OK"}; drive APIs use 0.
    // An unknown textual error must not silently become numeric success.
    if (json['success'] != false &&
        (code == null || numeric == 0 || codeText == 'OK') &&
        http < 400) {
      return;
    }
    final message = '${json['message'] ?? ''}'.toLowerCase();
    if (http == 401 ||
        numeric == 14001 ||
        numeric == 31001 ||
        codeText == 'NOT_LOGIN' ||
        codeText == 'UNAUTHORIZED' ||
        message.contains('login') ||
        message.contains('登录')) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '$displayName 登录已失效，请重新登录',
      );
    }
    if (http == 404 || numeric == 21001 || message.contains('not exist')) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.fileMissing,
        '网盘里找不到这个文件',
      );
    }
    if (http == 429 || numeric == 429 || message.contains('too many')) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.rateLimited,
        '$displayName 请求过于频繁，请稍后再试',
      );
    }
    if (message.contains('member') || message.contains('vip')) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.entitlement,
        '当前账号没有播放这个文件的权限',
      );
    }
    if (message.contains('transcod')) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.transcoding,
        '视频还在转码，请稍后再试',
      );
    }
    throw CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      numeric == null
          ? '$displayName 拒绝了这次请求，请稍后重试'
          : '$displayName 拒绝了这次请求（$numeric）',
    );
  }
}

int? _durationMs(Object? raw) {
  final value = num.tryParse('$raw');
  if (value == null || !value.isFinite || value <= 0) return null;
  return (value * 1000).round();
}

String _stem(String name) =>
    name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

String _qualityLabel(String id, int? height) => height != null && height > 0
    ? '${height}P'
    : const {
            'low': '流畅',
            'normal': '标清',
            'high': '高清',
            'super': '超清',
            '2k': '2K',
            '4k': '4K',
          }[id] ??
          id;

class _QuarkTranscodes {
  const _QuarkTranscodes(this.choices, this.infos, this.durationMs);
  final List<CloudDriveQualityChoice> choices;
  final Map<String, Map> infos;
  final int? durationMs;
}

String? _optional(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
