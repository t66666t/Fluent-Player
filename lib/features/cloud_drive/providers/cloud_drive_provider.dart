import '../models/cloud_drive_models.dart';
import 'cloud_drive_http.dart';

/// One cloud vendor. Requests must be cancellable via [cancelToken].
abstract class CloudDriveProvider {
  String get rootFileId => '/';
  Future<void> Function(
    CloudDriveCredential previous,
    CloudDriveCredential next,
  )?
  onCredentialRefreshed;
  String get id;
  String get displayName;
  Uri get loginUri;
  CloudDriveCapabilities get capabilities;

  /// Providers can reuse their authenticated transport for cover images.
  CloudDriveHttp get thumbnailHttp => NetworkCloudDriveHttp();
  String get thumbnailUserAgent => 'Mozilla/5.0';
  String get thumbnailReferer => loginUri.toString();

  Future<List<int>> readThumbnail(
    CloudDriveFileRequest request,
    Uri uri, {
    Object? cancelToken,
  }) async {
    final response = await thumbnailHttp.send(
      CloudDriveHttpRequest(
        method: 'GET',
        uri: uri,
        headersFor: (target) {
          final cookie = request.credential.headerFor(target);
          return {
            'User-Agent': thumbnailUserAgent,
            'Referer': thumbnailReferer,
            'Accept': 'image/*',
            if (cookie.isNotEmpty) 'Cookie': cookie,
          };
        },
        connectionScope: request.accountLocalId,
        readMode: CloudDriveReadMode.text,
        maxBytes: 8 * 1024 * 1024,
        timeout: const Duration(seconds: 12),
      ),
      cancelToken: cancelToken,
    );
    if (response.statusCode != 200) {
      throw mapCloudHttpStatus(response.statusCode);
    }
    return response.body;
  }

  /// Confirms the browser session by calling the account and the root folder.
  /// A single cookie name is not proof of a usable login.
  Future<CloudDriveVerifiedSession> verifySession(
    CloudDriveCredential credential, {
    Object? cancelToken,
  });

  Future<CloudDrivePage> listChildren(
    CloudDriveListRequest request, {
    Object? cancelToken,
  });

  Future<CloudDriveEntry> getFile(
    CloudDriveFileRequest request, {
    Object? cancelToken,
  });

  Future<CloudDrivePlaybackDescriptor> resolvePlayback(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  });

  /// Background probe of rungs other than the one already playing.
  ///
  /// The default does nothing so a vendor without a ladder does not pretend
  /// to offer 1080P or 4K.
  Future<List<CloudDriveQualityChoice>> discoverQualities(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async => const <CloudDriveQualityChoice>[];

  /// Starts the same probe as [discoverQualities], but [firstVerified]
  /// completes when the first playable rung is known.
  ///
  /// Callers that only need a fallback must not wait for the rest of the
  /// ladder. Vendors without a ladder complete [firstVerified] with null.
  CloudDriveQualityDiscovery beginQualityDiscovery(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) {
    final choices = discoverQualities(request, cancelToken: cancelToken);
    return CloudDriveQualityDiscovery(
      choices: choices,
      firstVerified: choices.then((_) => null),
    );
  }

  /// Rungs that are about to be probed. They are not selectable yet.
  List<CloudDriveQualityChoice> qualityPlaceholders(
    CloudDrivePlaybackRequest request,
  ) => const <CloudDriveQualityChoice>[];

  Future<List<CloudDriveSubtitleTrack>> discoverSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async => const <CloudDriveSubtitleTrack>[];

  Future<String> readSubtitleText(
    CloudDriveSubtitleReadRequest request, {
    Object? cancelToken,
  }) async {
    throw const CloudDriveFailure(
      CloudDriveFailureKind.unsupported,
      '这个网盘没有提供字幕文本',
    );
  }

  /// Directory plus warnings. A truncated scan must not look like "no subtitles".
  Future<CloudDriveSubtitleCatalog> discoverSubtitleCatalog(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    return CloudDriveSubtitleCatalog(
      tracks: await discoverSubtitles(request, cancelToken: cancelToken),
    );
  }

  /// Official tracks only. The default vendor has none, so playback does not
  /// pretend a directory walk answered the question.
  Future<CloudDriveOfficialSubtitleDiscovery> discoverOfficialSubtitles(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    return const CloudDriveOfficialSubtitleDiscovery(
      status: CloudDriveOfficialSubtitleStatus.unsupported,
    );
  }

  /// Sibling subtitle files only. Official tracks stay on
  /// [discoverOfficialSubtitles] so a multi-page walk cannot delay them.
  Future<CloudDriveSubtitleCatalog> discoverSidecarCatalog(
    CloudDrivePlaybackRequest request, {
    Object? cancelToken,
  }) async {
    return const CloudDriveSubtitleCatalog(tracks: <CloudDriveSubtitleTrack>[]);
  }
}

/// What an official subtitle directory request actually established.
enum CloudDriveOfficialSubtitleStatus {
  unsupported,
  ready,
  failed,
  loginRequired,
  restricted,
}

class CloudDriveOfficialSubtitleDiscovery {
  const CloudDriveOfficialSubtitleDiscovery({
    required this.status,
    this.tracks = const <CloudDriveSubtitleTrack>[],
    this.message,
  });

  final CloudDriveOfficialSubtitleStatus status;
  final List<CloudDriveSubtitleTrack> tracks;
  final String? message;

  /// The directory was read and contained no usable track.
  bool get confirmedEmpty =>
      status == CloudDriveOfficialSubtitleStatus.ready && tracks.isEmpty;
}

class CloudDriveVerifiedSession {
  const CloudDriveVerifiedSession({
    required this.remoteAccountId,
    required this.displayName,
    this.avatar,
    this.driveId = '0',
    this.refreshedCredential,
  });

  final String remoteAccountId;
  final String displayName;
  final String? avatar;
  final String driveId;
  final CloudDriveCredential? refreshedCredential;
}

class CloudDriveListRequest {
  const CloudDriveListRequest({
    required this.credential,
    required this.accountLocalId,
    required this.remoteAccountId,
    required this.driveId,
    required this.parentFileId,
    this.cursor,
    this.sort = CloudDriveSort.name,
    this.descending = false,
    this.pathHint,
  });

  final CloudDriveCredential credential;
  final String accountLocalId;
  final String remoteAccountId;
  final String driveId;
  final String parentFileId;
  final String? cursor;
  final CloudDriveSort sort;
  final bool descending;
  final String? pathHint;
}

class CloudDriveFileRequest {
  const CloudDriveFileRequest({
    required this.credential,
    required this.accountLocalId,
    required this.remoteAccountId,
    required this.driveId,
    required this.fileId,
    this.pathHint,
    this.name,
  });

  final CloudDriveCredential credential;
  final String accountLocalId;
  final String remoteAccountId;
  final String driveId;
  final String fileId;
  final String? pathHint;
  final String? name;
}

class CloudDrivePlaybackRequest {
  const CloudDrivePlaybackRequest({
    required this.credential,
    required this.accountLocalId,
    required this.remoteAccountId,
    required this.driveId,
    required this.fileId,
    this.pathHint,
    this.name,
    this.durationMs,
    this.size,
    this.preferredQualityId,
    this.revision,
    this.playbackSessionId,
  });

  final CloudDriveCredential credential;
  final String accountLocalId;
  final String remoteAccountId;
  final String driveId;
  final String fileId;
  final String? pathHint;
  final String? name;
  final int? durationMs;
  final int? size;
  final String? preferredQualityId;
  final String? revision;
  final String? playbackSessionId;
}

/// Background quality probe. [choices] is the finished ladder.
/// [firstVerified] may complete earlier with a descriptor the next open can
/// reuse, so a fallback does not repeat metadata and streaming.
class CloudDriveQualityDiscovery {
  const CloudDriveQualityDiscovery({
    required this.choices,
    required this.firstVerified,
  });

  final Future<List<CloudDriveQualityChoice>> choices;
  final Future<CloudDrivePlaybackDescriptor?> firstVerified;
}

class CloudDriveSubtitleCatalog {
  const CloudDriveSubtitleCatalog({
    required this.tracks,
    this.warning,
    this.official = const CloudDriveOfficialSubtitleDiscovery(
      status: CloudDriveOfficialSubtitleStatus.unsupported,
    ),
  });

  final List<CloudDriveSubtitleTrack> tracks;
  final String? warning;
  final CloudDriveOfficialSubtitleDiscovery official;
}

class CloudDriveProviderRegistry {
  CloudDriveProviderRegistry(Iterable<CloudDriveProvider> providers)
    : _providers = {for (final provider in providers) provider.id: provider};

  final Map<String, CloudDriveProvider> _providers;

  List<CloudDriveProvider> get all => List.unmodifiable(_providers.values);

  CloudDriveProvider? operator [](String id) => _providers[id];
}

/// Shared response classification for both vendors.
CloudDriveFailure mapCloudHttpStatus(int status, {String? retryAfter}) {
  if (status == 401 || status == 403) {
    return const CloudDriveFailure(
      CloudDriveFailureKind.notLoggedIn,
      '登录已失效，请重新登录',
    );
  }
  if (status == 404) {
    return const CloudDriveFailure(
      CloudDriveFailureKind.fileMissing,
      '网盘里找不到这个文件',
    );
  }
  if (status == 429) {
    return CloudDriveFailure(
      CloudDriveFailureKind.rateLimited,
      '请求过于频繁，请稍后再试',
      retryAfter: parseRetryAfter(retryAfter),
    );
  }
  return const CloudDriveFailure(
    CloudDriveFailureKind.unavailable,
    '网盘暂时没有返回可用结果',
  );
}

Duration? parseRetryAfter(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  final seconds = int.tryParse(raw.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(seconds: seconds.clamp(0, 120));
}

bool looksLikeHtmlOrJsonError(CloudDriveHttpResponse response) {
  final type = response.headers['content-type'] ?? '';
  if (type.contains('text/html') || type.contains('application/json')) {
    return true;
  }
  if (response.body.isEmpty) return false;
  final start = response.text.trimLeft();
  return start.startsWith('<') ||
      start.startsWith('{') ||
      start.startsWith('[');
}
