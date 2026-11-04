import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../utils/subtitle_file_matcher.dart';
import '../../../utils/subtitle_parser.dart';
import '../auth/aliyun_device_session.dart';
import '../models/cloud_drive_media_kind.dart';
import '../models/cloud_drive_models.dart';
import '../services/cloud_drive_subtitle_text.dart';
import 'cloud_drive_http.dart';
import 'cloud_drive_provider.dart';

/// Personal web sessions only. No third-party developer app or token service.
class AliyunCloudDriveProvider extends CloudDriveProvider {
  AliyunCloudDriveProvider({CloudDriveHttp? http, DateTime Function()? clock})
    : _http = http ?? NetworkCloudDriveHttp(),
      _clock = clock ?? DateTime.now;

  static const providerId = 'aliyun';
  static const webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const _webReferer = 'https://www.alipan.com/';
  static const _legacyMediaReferer = 'https://www.aliyundrive.com/';
  static const _original = CloudDriveQualityChoice(
    id: 'original',
    label: '原画',
    transcoded: false,
    complete: true,
  );
  final CloudDriveHttp _http;
  final DateTime Function() _clock;
  final _sessions = <String, _AliSession>{};

  @override
  String get id => providerId;
  @override
  String get displayName => '阿里云盘';
  @override
  String get rootFileId => '@aliyun';
  @override
  Uri get loginUri => Uri.https('www.alipan.com', '/drive/file/all');
  @override
  CloudDriveHttp get thumbnailHttp => _http;
  @override
  String get thumbnailUserAgent => webUserAgent;
  @override
  String get thumbnailReferer => 'https://www.alipan.com/';
  @override
  CloudDriveCapabilities get capabilities =>
      const CloudDriveCapabilities(serverDateSort: true, remoteSubtitles: true);

  Future<_AliSession> _session(
    CloudDriveCredential credential,
    Object? cancel,
  ) async {
    final stamp = cloudDriveCredentialStamp(credential);
    var session = _sessions[stamp];
    if (session == null) {
      if (credential.secrets['refresh_token']?.isNotEmpty != true) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.notLoggedIn,
          '请在阿里云盘官方页面完成登录',
        );
      }
      if (_sessions.length >= 64) _sessions.remove(_sessions.keys.first);
      session = _AliSession(credential);
      _sessions[stamp] = session;
    }
    final current = session;
    await (current.initializing ??= _initialize(current, cancel).catchError((
      Object e,
      StackTrace st,
    ) {
      current.initializing = null;
      Error.throwWithStackTrace(e, st);
    }));
    await _ensureAccess(current, cancel);
    return current;
  }

  Future<void> _initialize(_AliSession s, Object? cancel) async {
    await _ensureAccess(s, cancel);
    final user = await _api(s, '/v2/user/get', const {}, cancel);
    final uid = _text(user['user_id']);
    if (uid == null || uid == '0') {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '阿里云盘网页会话还不能确认账号',
      );
    }
    final expected = _text(s.credential.secrets['user_id']);
    if (expected != null && expected != uid) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '阿里云盘登录账号已变化，请重新登录',
      );
    }
    s.user = user;
    await _update(s, {
      'user_id': uid,
      for (final key in [
        'default_drive_id',
        'resource_drive_id',
        'backup_drive_id',
      ])
        if (_text(user[key]) != null) key: _text(user[key])!,
      'device_id': s.device.deviceId,
      'private_key': s.device.privateKey,
    });
    if (_text(s.credential.secrets['resource_drive_id']) == null ||
        _text(s.credential.secrets['backup_drive_id']) == null) {
      try {
        final drives = await _api(
          s,
          '/adrive/v1/user/driveInfo',
          const {},
          cancel,
        );
        await _update(s, {
          for (final key in [
            'resource_drive_id',
            'backup_drive_id',
            'default_drive_id',
          ])
            if (_text(drives[key]) != null) key: _text(drives[key])!,
        });
      } on CloudDriveFailure catch (e) {
        if (e.kind == CloudDriveFailureKind.notLoggedIn ||
            e.kind == CloudDriveFailureKind.rateLimited ||
            e.kind == CloudDriveFailureKind.network) {
          rethrow;
        }
        // Older accounts may expose only the default drive via /v2/user/get.
      }
    }
  }

  Future<void> _ensureAccess(_AliSession s, Object? cancel) async {
    final expiry = DateTime.tryParse(s.credential.secrets['expire_time'] ?? '');
    if (_text(s.credential.secrets['access_token']) == null ||
        expiry != null &&
            !expiry.isAfter(_clock().add(const Duration(minutes: 2)))) {
      await _refresh(s, cancel);
    }
  }

  Future<void> _refresh(_AliSession s, Object? cancel) => s.refreshing ??=
      _refreshNow(s, cancel).whenComplete(() => s.refreshing = null);

  Future<void> _refreshNow(_AliSession s, Object? cancel) async {
    final response = await _http.send(
      CloudDriveHttpRequest(
        method: 'POST',
        uri: Uri.https('auth.alipan.com', '/v2/account/token'),
        headersFor: (uri) => _publicHeaders(uri),
        headers: _publicHeaders(Uri.https('auth.alipan.com', '/')),
        body: utf8.encode(
          jsonEncode({
            'grant_type': 'refresh_token',
            'refresh_token': s.credential.secrets['refresh_token'],
          }),
        ),
        connectionScope: 'aliyun:${cloudDriveCredentialStamp(s.credential)}',
      ),
      cancelToken: cancel,
    );
    final json = _json(response);
    _throwApi(json, response.statusCode, path: '/v2/account/token');
    if (_text(json['access_token']) == null ||
        _text(json['refresh_token']) == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '阿里云盘登录已失效，请重新登录',
      );
    }
    final expectedUser = _text(s.credential.secrets['user_id']);
    final refreshedUser = _text(json['user_id']);
    if (expectedUser != null &&
        refreshedUser != null &&
        expectedUser != refreshedUser) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '阿里云盘登录账号已变化，请重新登录',
      );
    }
    final expires = num.tryParse('${json['expires_in']}')?.toInt() ?? 7200;
    await _update(s, {
      'access_token': _text(json['access_token'])!,
      'refresh_token': _text(json['refresh_token'])!,
      if (_text(json['expire_time']) != null)
        'expire_time': _text(json['expire_time'])!
      else
        'expire_time': _clock()
            .toUtc()
            .add(Duration(seconds: expires))
            .toIso8601String(),
      for (final key in [
        'user_id',
        'default_drive_id',
        'resource_drive_id',
        'backup_drive_id',
      ])
        if (_text(json[key]) != null) key: _text(json[key])!,
      'device_id': s.device.deviceId,
      'private_key': s.device.privateKey,
    });
  }

  Future<void> _update(_AliSession s, Map<String, String> values) async {
    final previous = s.credential;
    final next = CloudDriveCredential(
      cookies: previous.cookies,
      capturedAt: previous.capturedAt,
      secrets: Map.unmodifiable({...previous.secrets, ...values}),
    );
    s.credential = next;
    _sessions[cloudDriveCredentialStamp(next)] = s;
    await onCredentialRefreshed?.call(previous, next);
  }

  Map<String, String> _publicHeaders(Uri uri) => {
    'User-Agent': webUserAgent,
    if (uri.scheme == 'https' &&
        const {'api.alipan.com', 'auth.alipan.com'}.contains(uri.host)) ...{
      'Content-Type': 'application/json',
      'Origin': 'https://www.alipan.com',
      'Referer': 'https://www.alipan.com/',
    },
  };

  Future<Map<String, dynamic>> _api(
    _AliSession s,
    String path,
    Map<String, dynamic> body,
    Object? cancel, {
    bool recoverDevice = true,
    Map<String, dynamic> Function()? bodyForAttempt,
  }) async {
    var refreshed = false;
    var recreated = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final uri = Uri.https('api.alipan.com', path);
      final uid = _text(s.credential.secrets['user_id']);
      final accessToken = s.credential.secrets['access_token'];
      final deviceGeneration = s.deviceGeneration;
      // Only exact API hosts receive bearer credentials or device proof.
      Map<String, String> headersFor(Uri target) => {
        ..._publicHeaders(target),
        if (target.scheme == 'https' && target.host == 'api.alipan.com') ...{
          'Authorization': 'Bearer $accessToken',
          'X-Device-Id': s.device.deviceId,
          'X-Request-Id': const Uuid().v4(),
          if (uid != null) 'X-Signature': s.device.signature(uid),
        },
      };
      final response = await _http.send(
        CloudDriveHttpRequest(
          method: 'POST',
          uri: uri,
          headers: headersFor(uri),
          headersFor: headersFor,
          body: utf8.encode(jsonEncode(bodyForAttempt?.call() ?? body)),
          connectionScope: 'aliyun:${s.device.deviceId}',
        ),
        cancelToken: cancel,
      );
      final json = _json(response);
      final code = '${json['code'] ?? ''}';
      final deviceError = const {
        'DeviceSessionSignatureInvalid',
        'DeviceSessionSignatureNotFound',
        'DeviceSessionNotFound',
        'DeviceSessionExpired',
      }.contains(code);
      if (recoverDevice && !recreated && deviceError) {
        recreated = true;
        if (uid == null) _throwApi(json, response.statusCode, path: path);
        if (s.deviceGeneration == deviceGeneration) {
          await (s.creatingDevice ??= _createDevice(
            s,
            cancel,
          ).whenComplete(() => s.creatingDevice = null));
        }
        continue;
      }
      // Creating a device must still recover an expired bearer token. Only
      // recursive device creation is disabled for that endpoint. A late 401
      // from a concurrent request must reuse a token already refreshed by it.
      if (!refreshed &&
          !deviceError &&
          (response.statusCode == 401 ||
              const {
                'AccessTokenInvalid',
                'AccessTokenExpired',
                'InvalidAccessToken',
              }.contains(code))) {
        refreshed = true;
        if (s.credential.secrets['access_token'] == accessToken) {
          await _refresh(s, cancel);
        }
        continue;
      }
      _throwApi(json, response.statusCode, path: path);
      return json;
    }
    throw const CloudDriveFailure(
      CloudDriveFailureKind.notLoggedIn,
      '阿里云盘设备会话已失效，请重新登录',
    );
  }

  Future<void> _createDevice(_AliSession s, Object? cancel) async {
    await _api(
      s,
      '/users/v1/users/device/create_session',
      const {},
      cancel,
      recoverDevice: false,
      // Token recovery rotates refresh_token too. Rebuild the proof body on
      // each attempt so its refreshToken agrees with the Authorization header.
      bodyForAttempt: () => {
        'deviceName': 'Fluent Player',
        'modelName': 'Fluent Player',
        'nonce': 0,
        'pubKey': s.device.publicKey,
        'refreshToken': s.credential.secrets['refresh_token'],
      },
    );
    s.deviceGeneration++;
  }

  @override
  Future<CloudDriveVerifiedSession> verifySession(
    CloudDriveCredential credential, {
    Object? cancelToken,
  }) async {
    final s = await _session(credential, cancelToken);
    final drive = _defaultDrive(s);
    await _list(
      s,
      drive,
      'root',
      null,
      CloudDriveSort.name,
      false,
      cancelToken,
    );
    return CloudDriveVerifiedSession(
      remoteAccountId: s.credential.secrets['user_id']!,
      displayName:
          _text(s.user['nick_name']) ?? _text(s.user['name']) ?? displayName,
      avatar: _text(s.user['avatar']),
      driveId: drive,
      refreshedCredential: s.credential,
    );
  }

  String _defaultDrive(_AliSession s) =>
      _text(s.credential.secrets['resource_drive_id']) ??
      _text(s.credential.secrets['default_drive_id']) ??
      _text(s.credential.secrets['backup_drive_id']) ??
      (throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '阿里云盘未返回可用的存储空间',
      ));

  String _drive(_AliSession s, String requested) =>
      requested.isEmpty || requested == '0' ? _defaultDrive(s) : requested;

  static String _directory(String drive, String file) =>
      '@aliyun:${Uri.encodeComponent(drive)}:${Uri.encodeComponent(file)}';
  (String, String) _location(_AliSession s, String drive, String file) {
    if (file.startsWith('@aliyun:')) {
      final parts = file.split(':');
      if (parts.length == 3) {
        return (Uri.decodeComponent(parts[1]), Uri.decodeComponent(parts[2]));
      }
    }
    return (_drive(s, drive), file.isEmpty || file == '/' ? 'root' : file);
  }

  @override
  Future<CloudDrivePage> listChildren(
    CloudDriveListRequest request, {
    Object? cancelToken,
  }) async {
    final s = await _session(request.credential, cancelToken);
    _checkAccount(s, request.remoteAccountId);
    if (request.parentFileId == rootFileId) {
      final seen = <String>{};
      final entries = <CloudDriveEntry>[];
      for (final item in [
        ('resource_drive_id', '资源库'),
        ('backup_drive_id', '备份盘'),
        ('default_drive_id', '我的文件'),
      ]) {
        final drive = _text(s.credential.secrets[item.$1]);
        if (drive == null || !seen.add(drive)) continue;
        entries.add(
          CloudDriveEntry(
            providerId: id,
            accountLocalId: request.accountLocalId,
            remoteAccountId: request.remoteAccountId,
            driveId: drive,
            fileId: _directory(drive, 'root'),
            parentFileId: rootFileId,
            name: item.$2,
            kind: CloudDriveEntryKind.folder,
          ),
        );
      }
      return CloudDrivePage(
        entries: entries,
        nextCursor: null,
        hasMore: false,
        sort: request.sort,
      );
    }
    final (drive, parent) = _location(s, request.driveId, request.parentFileId);
    final json = await _list(
      s,
      drive,
      parent,
      request.cursor,
      request.sort,
      request.descending,
      cancelToken,
    );
    final raw = json['items'];
    if (raw is! List) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '阿里云盘未返回可识别的文件列表',
      );
    }
    final next = _text(json['next_marker']);
    return CloudDrivePage(
      entries: raw
          .whereType<Map>()
          .map(
            (item) => _entry(
              Map<String, dynamic>.from(item),
              request.accountLocalId,
              request.remoteAccountId,
              drive,
              parent,
            ),
          )
          .toList(),
      nextCursor: next,
      hasMore: next != null,
      sort: request.sort,
    );
  }

  Future<Map<String, dynamic>> _list(
    _AliSession s,
    String drive,
    String parent,
    String? marker,
    CloudDriveSort sort,
    bool descending,
    Object? cancel,
  ) => _api(s, '/adrive/v3/file/list', {
    'drive_id': drive,
    'parent_file_id': parent,
    'limit': capabilities.pageSize,
    'marker': marker ?? '',
    'all': false,
    'fields': '*',
    'order_by': sort == CloudDriveSort.modified ? 'updated_at' : 'name',
    'order_direction': descending ? 'DESC' : 'ASC',
    'image_thumbnail_process': 'image/resize,w_400/format,jpeg',
    'video_thumbnail_process': 'video/snapshot,t_1000,f_jpg,ar_auto,w_400',
  }, cancel);

  @override
  Future<CloudDriveEntry> getFile(
    CloudDriveFileRequest request, {
    Object? cancelToken,
  }) async {
    final s = await _session(request.credential, cancelToken);
    _checkAccount(s, request.remoteAccountId);
    final (drive, file) = _location(s, request.driveId, request.fileId);
    final json = await _api(s, '/v2/file/get', {
      'drive_id': drive,
      'file_id': file,
      'fields': '*',
      'video_thumbnail_process': 'video/snapshot,t_1000,f_jpg,ar_auto,w_400',
    }, cancelToken);
    if (_text(json['file_id']) == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.fileMissing,
        '阿里云盘里找不到这个文件',
      );
    }
    return _entry(
      json,
      request.accountLocalId,
      request.remoteAccountId,
      drive,
      'root',
    );
  }

  CloudDriveEntry _entry(
    Map<String, dynamic> item,
    String local,
    String remote,
    String drive,
    String parent,
  ) {
    final folder = item['type'] == 'folder';
    final name = _text(item['name']) ?? '未命名';
    final file = _text(item['file_id']) ?? '';
    final metadata = item['video_media_metadata'];
    final kind = folder
        ? CloudDriveEntryKind.folder
        : classifyCloudDriveFile(name: name, category: null);
    return CloudDriveEntry(
      providerId: id,
      accountLocalId: local,
      remoteAccountId: remote,
      driveId: drive,
      fileId: folder ? _directory(drive, file) : file,
      parentFileId: _directory(drive, _text(item['parent_file_id']) ?? parent),
      name: name,
      kind: kind,
      size: _integer(item['size']),
      modifiedAt: DateTime.tryParse('${item['updated_at'] ?? ''}'),
      durationMs: metadata is Map ? _milliseconds(metadata['duration']) : null,
      thumbnailRef: _mediaUri(item['thumbnail'])?.toString(),
      revision:
          _text(item['content_hash']) ?? _text(item['updated_at']) ?? file,
    );
  }

  @override
  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final s = await _session(request.credential, cancelToken);
    _checkAccount(s, request.remoteAccountId);
    final preferred = request.preferredQualityId;
    CloudDriveFailure? failure;
    if (preferred == null || preferred == 'original') {
      try {
        final link = await _download(
          s,
          _drive(s, request.driveId),
          request.fileId,
          cancelToken,
        );
        return await _probe(
          s,
          request,
          link.$1,
          _original,
          expires: link.$2,
          cancel: cancelToken,
        );
      } on CloudDriveFailure catch (e) {
        if (preferred == 'original' ||
            const {
              CloudDriveFailureKind.notLoggedIn,
              CloudDriveFailureKind.fileMissing,
              CloudDriveFailureKind.rateLimited,
            }.contains(e.kind)) {
          rethrow;
        }
        failure = e;
      }
    }
    if (classifyCloudDriveFile(name: request.name ?? '', category: null) ==
        CloudDriveEntryKind.audio) {
      throw failure ??
          const CloudDriveFailure(
            CloudDriveFailureKind.unsupported,
            '这个音频当前没有可用的播放地址',
          );
    }
    final preview = await _preview(s, request, cancelToken);
    final choices = _choices(preview);
    final selected = preferred == null
        ? choices.where((q) => q.selectable).firstOrNull
        : choices.where((q) => q.id == preferred && q.selectable).firstOrNull;
    if (selected == null) {
      final unavailable = choices.where((q) => q.id == preferred).firstOrNull;
      throw failure ??
          CloudDriveFailure(
            choices.any((q) => q.statusDetail == '视频正在转码')
                ? CloudDriveFailureKind.transcoding
                : CloudDriveFailureKind.entitlement,
            unavailable?.statusDetail ?? '阿里云盘当前没有可用的完整视频画质',
          );
    }
    final tasks = preview['live_transcoding_task_list'] as List? ?? const [];
    final task = tasks.whereType<Map>().firstWhere(
      (t) => t['template_id'] == selected.id,
    );
    var durationMs = request.durationMs ?? _milliseconds(preview['duration']);
    if (durationMs == null || durationMs <= 0) {
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
      durationMs = file.durationMs;
    }
    return _probe(
      s,
      request,
      _mediaUri(task['url'])!,
      selected,
      choices: [_original, ...choices],
      durationMs: durationMs,
      cancel: cancelToken,
    );
  }

  Future<(Uri, DateTime?)> _download(
    _AliSession s,
    String drive,
    String file,
    Object? cancel,
  ) async {
    final json = await _api(s, '/v2/file/get_download_url', {
      'drive_id': drive,
      'file_id': file,
      'expire_sec': 14400,
    }, cancel);
    final uri = _mediaUri(json['url']);
    if (uri == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.entitlement,
        '阿里云盘没有提供原始文件下载地址',
      );
    }
    return (uri, DateTime.tryParse('${json['expiration'] ?? ''}'));
  }

  Future<Map<String, dynamic>> _preview(
    _AliSession s,
    CloudDrivePlaybackRequest r,
    Object? cancel,
  ) async {
    final json = await _api(s, '/v2/file/get_video_preview_play_info', {
      'drive_id': _drive(s, r.driveId),
      'file_id': r.fileId,
      'category': 'live_transcoding',
      'template_id': '',
      'get_subtitle_info': true,
    }, cancel);
    final data = json['video_preview_play_info'];
    if (data is! Map) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unsupported,
        '阿里云盘当前没有可用的视频预览信息',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  List<CloudDriveQualityChoice> _choices(Map<String, dynamic> preview) {
    final tasks = preview['live_transcoding_task_list'];
    if (tasks is! List) return const [];
    final seen = <String>{};
    final choices = [
      for (final task in tasks.whereType<Map>())
        if (_text(task['template_id']) != null &&
            seen.add('${task['template_id']}'))
          CloudDriveQualityChoice(
            id: '${task['template_id']}',
            label:
                '${const {'LD': '360P', 'SD': '540P', 'HD': '720P', 'FHD': '1080P', 'QHD': '2K', 'UHD': '4K'}[task['template_id']] ?? task['template_id']} 转码',
            transcoded: true,
            complete:
                task['status'] == 'finished' && _mediaUri(task['url']) != null,
            availability:
                task['status'] == 'finished' && _mediaUri(task['url']) != null
                ? CloudDriveQualityAvailability.available
                : CloudDriveQualityAvailability.unavailable,
            statusDetail:
                task['status'] == 'finished' && _mediaUri(task['url']) != null
                ? null
                : const {
                    'queued',
                    'running',
                    'processing',
                  }.contains(task['status'])
                ? '视频正在转码'
                : '当前账号没有此画质权益',
          ),
    ];
    const ranks = {
      'LD': 360,
      'SD': 540,
      'HD': 720,
      'FHD': 1080,
      'QHD': 1440,
      'UHD': 2160,
    };
    choices.sort((a, b) => (ranks[b.id] ?? 0).compareTo(ranks[a.id] ?? 0));
    return choices;
  }

  @override
  Future<List<CloudDriveQualityChoice>> discoverQualities(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    if (classifyCloudDriveFile(name: request.name ?? '', category: null) ==
        CloudDriveEntryKind.audio) {
      return const [_original];
    }
    final s = await _session(request.credential, cancelToken);
    _checkAccount(s, request.remoteAccountId);
    return [_original, ..._choices(await _preview(s, request, cancelToken))];
  }

  Future<CloudDrivePlaybackDescriptor> _probe(
    _AliSession s,
    CloudDrivePlaybackRequest r,
    Uri uri,
    CloudDriveQualityChoice quality, {
    DateTime? expires,
    List<CloudDriveQualityChoice>? choices,
    int? durationMs,
    Object? cancel,
  }) async {
    final hls = quality.transcoded || uri.path.toLowerCase().endsWith('.m3u8');
    final (response, referer) = await _readMedia(
      uri,
      range: hls ? null : (0, 1),
      readMode: hls ? CloudDriveReadMode.text : CloudDriveReadMode.probe,
      maxBytes: hls ? 2 * 1024 * 1024 : 512,
      accountLocalId: r.accountLocalId,
      cancel: cancel,
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      final code = _mediaErrorCode(response);
      final diagnostic =
          'media=${hls ? 'manifest' : 'original'} '
          'http=${response.statusCode} code=$code';
      if (code == 'SignatureDoesNotMatch' || code == 'RequestTimeTooSkewed') {
        throw CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '阿里云盘播放地址校验失败，请刷新后重试',
          diagnostic: diagnostic,
        );
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw CloudDriveFailure(
          CloudDriveFailureKind.entitlement,
          '阿里云盘播放地址不可用或账号没有此画质权益',
          diagnostic: diagnostic,
        );
      }
      throw mapCloudHttpStatus(response.statusCode);
    }
    if (looksLikeHtmlOrJsonError(response) ||
        hls && !response.text.trimLeft().startsWith('#EXTM3U')) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '阿里云盘返回的内容不是可播放的视频',
      );
    }
    final measured = hls
        ? RegExp(r'#EXTINF:([0-9.]+)')
              .allMatches(response.text)
              .fold<double>(0, (sum, m) => sum + (double.tryParse(m[1]!) ?? 0))
        : 0.0;
    final expected = durationMs ?? r.durationMs;
    if (hls &&
        (response.text.contains('#EXT-X-PLAYLIST-TYPE:EVENT') ||
            measured > 0 &&
                expected != null &&
                expected > 0 &&
                measured * 1000 < expected * 0.9)) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.previewOnly,
        '阿里云盘只返回了试看片段，无法作为完整视频播放',
      );
    }
    final originalSize = _contentSize(response);
    final audio =
        classifyCloudDriveFile(name: r.name ?? '', category: null) ==
        CloudDriveEntryKind.audio;
    final selected = audio
        ? const CloudDriveQualityChoice(
            id: 'original',
            label: '原始音频',
            transcoded: false,
            complete: true,
          )
        : quality;
    return CloudDrivePlaybackDescriptor(
      upstreamUri: response.finalUri,
      transport: hls
          ? CloudDriveTransport.hls
          : CloudDriveTransport.progressive,
      quality: selected,
      fileId: r.fileId,
      revision: r.revision ?? r.fileId,
      complete: true,
      seekable:
          hls ||
          response.statusCode == 206 ||
          (response.headers['accept-ranges'] ?? '').contains('bytes'),
      userAgent: webUserAgent,
      referer: referer,
      cookies: const [],
      providerId: id,
      accountLocalId: r.accountLocalId,
      remoteAccountId: r.remoteAccountId,
      driveId: _drive(s, r.driveId),
      pathHint: r.pathHint,
      expiresAt: expires ?? _mediaUrlExpiry(response.finalUri),
      transcoded: quality.transcoded,
      qualities: choices ?? [selected],
      durationMs: expected,
      sizeBytes: quality.transcoded ? null : originalSize ?? r.size,
      mediaKind: audio ? CloudDriveMediaKind.audio : CloudDriveMediaKind.video,
      verifiedComplete: hls && measured > 0 && expected != null,
      playbackSessionId: r.playbackSessionId ?? '',
      manifest: hls
          ? CloudDriveManifestSnapshot(
              text: response.text,
              baseUri: response.finalUri,
              fetchedAt: _clock().toUtc(),
              mutable: !response.text.contains('#EXT-X-ENDLIST'),
            )
          : null,
    );
  }

  bool _signedReferer(Uri uri) =>
      (uri.queryParameters['x-oss-additional-headers'] ?? '')
          .toLowerCase()
          .split(';')
          .contains('referer');

  /// Personal preview URLs still sign the old web origin, even when the API
  /// and thumbnails use alipan.com. Keep the successful proof on the descriptor
  /// so the gateway sends it for manifests, segments and keys as well.
  Future<(CloudDriveHttpResponse, String)> _readMedia(
    Uri uri, {
    required String accountLocalId,
    required CloudDriveReadMode readMode,
    required int maxBytes,
    (int, int?)? range,
    Object? cancel,
  }) async {
    var referer =
        _signedReferer(uri) &&
            (uri.host == 'aliyundrive.net' ||
                uri.host.endsWith('.aliyundrive.net'))
        ? _legacyMediaReferer
        : _webReferer;
    for (var attempt = 0; ; attempt++) {
      final currentReferer = referer;
      Map<String, String> headers(Uri _) => {
        'User-Agent': webUserAgent,
        'Referer': currentReferer,
      };
      final response = await _http.send(
        CloudDriveHttpRequest(
          method: 'GET',
          uri: uri,
          headers: headers(uri),
          headersFor: headers,
          range: range,
          readMode: readMode,
          maxBytes: maxBytes,
          connectionScope: accountLocalId,
        ),
        cancelToken: cancel,
      );
      // Allow either official origin during a server migration, only when a
      // signed Referer is explicitly rejected. Other 403s keep their meaning.
      if (attempt == 0 &&
          response.statusCode == 403 &&
          _signedReferer(uri) &&
          _mediaErrorCode(response) == 'SignatureDoesNotMatch') {
        referer = currentReferer == _legacyMediaReferer
            ? _webReferer
            : _legacyMediaReferer;
        continue;
      }
      return (response, currentReferer);
    }
  }

  @override
  Future<CloudDriveOfficialSubtitleDiscovery> discoverOfficialSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    try {
      final s = await _session(request.credential, cancelToken);
      _checkAccount(s, request.remoteAccountId);
      final preview = await _preview(s, request, cancelToken);
      final tasks = preview['live_transcoding_subtitle_task_list'];
      final tracks = <CloudDriveSubtitleTrack>[];
      if (tasks is List) {
        for (final task in tasks.whereType<Map>()) {
          final uri = _mediaUri(task['url']);
          if (uri == null ||
              task['status'] != null && task['status'] != 'finished') {
            continue;
          }
          final lang = _text(task['language']);
          final format =
              _text(task['format']) ??
              (uri.path.endsWith('.vtt') ? 'vtt' : 'srt');
          final identity =
              _text(task['task_id']) ??
              _text(task['template_id']) ??
              '$lang:$format';
          tracks.add(
            CloudDriveSubtitleTrack(
              id: 'aliyun:${request.driveId}:${request.fileId}:$identity',
              label: '阿里云盘 · ${_text(task['name']) ?? lang ?? '字幕'}',
              format: format,
              language: lang,
              origin: CloudDriveSubtitleOrigin.provider,
              fileId: request.fileId,
              revision: request.revision,
              remoteUri: uri,
              isAi: task['is_ai'] == true || task['source'] == 'AI',
              autoSelect: true,
            ),
          );
        }
      }
      return CloudDriveOfficialSubtitleDiscovery(
        status: CloudDriveOfficialSubtitleStatus.ready,
        tracks: tracks,
      );
    } on CloudDriveFailure catch (e) {
      return CloudDriveOfficialSubtitleDiscovery(
        status: e.kind == CloudDriveFailureKind.notLoggedIn
            ? CloudDriveOfficialSubtitleStatus.loginRequired
            : e.kind == CloudDriveFailureKind.entitlement
            ? CloudDriveOfficialSubtitleStatus.restricted
            : CloudDriveOfficialSubtitleStatus.failed,
        message: e.message,
      );
    }
  }

  @override
  Future<CloudDriveSubtitleCatalog> discoverSidecarCatalog(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    final r = request;
    final file = await getFile(
      CloudDriveFileRequest(
        credential: r.credential,
        accountLocalId: r.accountLocalId,
        remoteAccountId: r.remoteAccountId,
        driveId: r.driveId,
        fileId: r.fileId,
      ),
      cancelToken: cancelToken,
    );
    final tracks = <CloudDriveSubtitleTrack>[];
    String? cursor;
    var more = false;
    for (var i = 0; i < 5; i++) {
      final page = await listChildren(
        CloudDriveListRequest(
          credential: r.credential,
          accountLocalId: r.accountLocalId,
          remoteAccountId: r.remoteAccountId,
          driveId: file.driveId,
          parentFileId: file.parentFileId,
          cursor: cursor,
        ),
        cancelToken: cancelToken,
      );
      for (final sibling in page.entries) {
        final ext = sibling.name.split('.').last.toLowerCase();
        if (!const {'srt', 'vtt', 'ass', 'ssa'}.contains(ext)) continue;
        final match = SubtitleFileMatcher.analyzeStems(
          videoStem: _stem(file.name),
          subtitleStem: _stem(sibling.name),
        );
        if (match.grade == SubtitleMatchGrade.rejected) continue;
        tracks.add(
          CloudDriveSubtitleTrack(
            id: 'sidecar-${sibling.fileId}',
            label: sibling.name,
            format: ext,
            language: match.languageCode,
            origin: CloudDriveSubtitleOrigin.sidecar,
            fileId: sibling.fileId,
            revision: sibling.revision,
            autoSelect: match.grade == SubtitleMatchGrade.autoMatch,
          ),
        );
      }
      more = page.hasMore;
      if (!more) break;
      if (page.nextCursor == null || page.nextCursor == cursor) {
        throw const CloudDriveFailure(
          CloudDriveFailureKind.unavailable,
          '阿里云盘字幕目录分页未能继续，请重试',
        );
      }
      cursor = page.nextCursor;
    }
    return CloudDriveSubtitleCatalog(
      tracks: tracks,
      warning: more ? '同目录只核对了前 5 页，后面可能还有字幕文件' : null,
    );
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
    final s = await _session(request.credential, cancelToken);
    _checkAccount(s, request.remoteAccountId);
    var uri = request.track.remoteUri;
    if (request.track.origin == CloudDriveSubtitleOrigin.sidecar &&
        request.track.fileId != null) {
      uri = (await _download(
        s,
        _drive(s, request.driveId),
        request.track.fileId!,
        cancelToken,
      )).$1;
    }
    if (uri == null) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.unavailable,
        '阿里云盘字幕地址已过期，请刷新字幕列表',
      );
    }
    final (response, _) = await _readMedia(
      uri,
      readMode: CloudDriveReadMode.text,
      maxBytes: 8 * 1024 * 1024,
      accountLocalId: request.accountLocalId,
      cancel: cancelToken,
    );
    if (response.statusCode != 200) {
      throw mapCloudHttpStatus(response.statusCode);
    }
    return interpretCloudDriveSubtitleBody(
      SubtitleParser.decodeBytes(response.body),
      format: request.track.format,
    );
  }

  void _checkAccount(_AliSession s, String expected) {
    if (expected.isNotEmpty && s.credential.secrets['user_id'] != expected) {
      throw const CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '阿里云盘登录账号与文件所属账号不一致，请重新登录',
      );
    }
  }

  Map<String, dynamic> _json(CloudDriveHttpResponse response) {
    if (response.statusCode == 429) {
      throw mapCloudHttpStatus(
        429,
        retryAfter: response.headers['retry-after'],
      );
    }
    final json = response.jsonMap;
    if (json == null) throw mapCloudHttpStatus(response.statusCode);
    return json;
  }

  void _throwApi(Map<String, dynamic> json, int http, {required String path}) {
    final code = '${json['code'] ?? ''}';
    if (http < 400 && (code.isEmpty || code == '0')) return;
    final safeCode = RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(code)
        ? code
        : 'unknown';
    final diagnostic = 'api=$path http=$http code=$safeCode';
    final lower = code.toLowerCase();
    if (http == 429 ||
        lower.contains('toomany') ||
        lower.contains('flowcontrol') ||
        lower.contains('ratelimit')) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.rateLimited,
        '阿里云盘请求过于频繁，请稍后再试',
        diagnostic: diagnostic,
      );
    }
    if (http == 401 ||
        lower.contains('token') ||
        lower.contains('devicesession') ||
        lower.contains('notlogin')) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.notLoggedIn,
        '阿里云盘登录已失效，请重新登录',
        diagnostic: diagnostic,
      );
    }
    if (http == 404 ||
        lower.contains('filenotfound') ||
        lower.contains('fileidnotfound')) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.fileMissing,
        '阿里云盘里找不到这个文件',
        diagnostic: diagnostic,
      );
    }
    if (http == 403 ||
        lower.contains('forbidden') ||
        lower.contains('vip') ||
        lower.contains('permission')) {
      throw CloudDriveFailure(
        CloudDriveFailureKind.entitlement,
        '当前阿里云盘账号没有此功能或画质的权益',
        diagnostic: diagnostic,
      );
    }
    throw CloudDriveFailure(
      CloudDriveFailureKind.unavailable,
      '阿里云盘暂时无法完成这次请求，请稍后重试',
      diagnostic: diagnostic,
    );
  }
}

String _mediaErrorCode(CloudDriveHttpResponse response) {
  final code =
      _text(response.jsonMap?['code']) ??
      RegExp(
        r'<Code>\s*([A-Za-z0-9_.-]{1,80})\s*</Code>',
      ).firstMatch(response.text)?.group(1);
  return code != null && RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(code)
      ? code
      : 'unknown';
}

DateTime? _mediaUrlExpiry(Uri uri) {
  final seconds = int.tryParse(uri.queryParameters['x-oss-expires'] ?? '');
  if (seconds == null || seconds <= 0 || seconds > 8640000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

class _AliSession {
  _AliSession(this.credential)
    : device = AliyunDeviceSession(
        privateKey: credential.secrets['private_key'],
        deviceId: credential.secrets['device_id'],
      );
  CloudDriveCredential credential;
  final AliyunDeviceSession device;
  Map<String, dynamic> user = const {};
  int deviceGeneration = 0;
  Future<void>? initializing, refreshing, creatingDevice;
}

String? _text(Object? value) {
  final text = value is String || value is num ? '$value'.trim() : '';
  return text.isEmpty ? null : text;
}

int? _integer(Object? value) => num.tryParse('$value')?.round();
int? _milliseconds(Object? value) {
  final seconds = num.tryParse('$value');
  return seconds != null && seconds.isFinite && seconds > 0
      ? (seconds * 1000).round()
      : null;
}

Uri? _mediaUri(Object? value) {
  final text = _text(value);
  final uri = text == null ? null : Uri.tryParse(text);
  return uri != null &&
          const {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty
      ? uri
      : null;
}

int? _contentSize(CloudDriveHttpResponse response) =>
    int.tryParse((response.headers['content-range'] ?? '').split('/').last) ??
    (response.statusCode == 200
        ? int.tryParse(response.headers['content-length'] ?? '')
        : null);
String _stem(String name) =>
    name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
