import 'dart:convert';

const cloudDriveProviderNames = <String, String>{
  'baidu': '百度网盘',
  'quark': '夸克网盘',
  'uc': 'UC网盘',
  'aliyun': '阿里云盘',
};

String cloudDriveRootId(String providerId) => switch (providerId) {
  'quark' || 'uc' => '0',
  'aliyun' => '@aliyun',
  _ => '/',
};

/// Why a cloud operation stopped. UI maps these to a short sentence.
enum CloudDriveFailureKind {
  notLoggedIn,
  fileMissing,
  transcoding,
  previewOnly,
  entitlement,
  rateLimited,
  unsupported,
  network,
  unavailable,

  /// Upstream ignored a non-zero Range and no honest 206 could be formed.
  rangeUnsupported,

  /// The bytes arrived, but the native player could not decode them.
  decode,
}

class CloudDriveFailure implements Exception {
  const CloudDriveFailure(
    this.kind,
    this.message, {
    this.retryAfter,
    this.diagnostic,
  });

  final CloudDriveFailureKind kind;
  final String message;
  final Duration? retryAfter;

  /// Technical context for playback diagnostics, without credentials or URLs.
  /// Kept separate from the message shown in the UI.
  final String? diagnostic;

  @override
  String toString() => message;
}

enum CloudDriveAuthState { signedIn, needsLogin, temporarySession }

enum CloudDriveEntryKind { folder, video, unsupported, audio, subtitle }

enum CloudDriveMediaKind { video, audio, unknown }

/// Availability of one real quality probe. Missing rungs are not invented.
enum CloudDriveQualityAvailability { available, discovering, unavailable }

enum CloudDriveSort { name, modified }

enum CloudDriveTransport { progressive, hls }

/// What the provider can actually do. Buttons for missing abilities stay hidden.
class CloudDriveCapabilities {
  const CloudDriveCapabilities({
    this.pageSize = 100,
    this.serverNameSort = true,
    this.serverDateSort = false,
    this.originalStream = true,
    this.transcodedStream = true,
    this.remoteSubtitles = false,
    this.fullLibrarySearch = false,
  });

  final int pageSize;
  final bool serverNameSort;
  final bool serverDateSort;
  final bool originalStream;
  final bool transcodedStream;
  final bool remoteSubtitles;
  final bool fullLibrarySearch;
}

class CloudDriveAccount {
  const CloudDriveAccount({
    required this.localId,
    required this.providerId,
    required this.remoteAccountId,
    required this.displayName,
    required this.credentialKey,
    required this.authState,
    this.avatar,
    this.lastVerifiedAt,
    this.credentialPersisted = true,
    this.driveId = '0',
  });

  final String localId;
  final String providerId;
  final String remoteAccountId;
  final String displayName;
  final String? avatar;
  final String credentialKey;
  final CloudDriveAuthState authState;
  final DateTime? lastVerifiedAt;

  /// False when secure storage failed and the session lives only in memory.
  final bool credentialPersisted;
  final String driveId;

  CloudDriveAccount copyWith({
    String? displayName,
    Object? avatar = _unset,
    String? credentialKey,
    CloudDriveAuthState? authState,
    Object? lastVerifiedAt = _unset,
    bool? credentialPersisted,
    String? driveId,
  }) {
    return CloudDriveAccount(
      localId: localId,
      providerId: providerId,
      remoteAccountId: remoteAccountId,
      displayName: displayName ?? this.displayName,
      avatar: identical(avatar, _unset) ? this.avatar : avatar as String?,
      credentialKey: credentialKey ?? this.credentialKey,
      authState: authState ?? this.authState,
      lastVerifiedAt: identical(lastVerifiedAt, _unset)
          ? this.lastVerifiedAt
          : lastVerifiedAt as DateTime?,
      credentialPersisted: credentialPersisted ?? this.credentialPersisted,
      driveId: driveId ?? this.driveId,
    );
  }

  Map<String, dynamic> toJson() => {
    'localId': localId,
    'providerId': providerId,
    'remoteAccountId': remoteAccountId,
    'displayName': displayName,
    'avatar': avatar,
    'credentialKey': credentialKey,
    'authState': authState.name,
    'lastVerifiedAt': lastVerifiedAt?.toIso8601String(),
    'credentialPersisted': credentialPersisted,
    'driveId': driveId,
  };

  factory CloudDriveAccount.fromJson(Map<String, dynamic> json) {
    return CloudDriveAccount(
      localId: _text(json['localId']),
      providerId: _text(json['providerId']),
      remoteAccountId: _text(json['remoteAccountId']),
      displayName: _text(json['displayName']),
      avatar: _optional(json['avatar']),
      credentialKey: _text(json['credentialKey']),
      authState: CloudDriveAuthState.values.firstWhere(
        (state) => state.name == json['authState'],
        orElse: () => CloudDriveAuthState.needsLogin,
      ),
      lastVerifiedAt: DateTime.tryParse('${json['lastVerifiedAt'] ?? ''}'),
      credentialPersisted: json['credentialPersisted'] != false,
      driveId: _optional(json['driveId']) ?? '0',
    );
  }
}

class CloudDriveCookie {
  const CloudDriveCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.secure = true,
  });

  final String name;
  final String value;
  final String domain;
  final String path;
  final bool secure;

  bool matches(Uri uri) {
    if (name.isEmpty || value.isEmpty) return false;
    if (secure && uri.scheme != 'https') return false;
    if (!uri.path.startsWith(path.isEmpty ? '/' : path)) return false;
    final host = uri.host.toLowerCase();
    var domain = this.domain.toLowerCase();
    if (domain.startsWith('.')) domain = domain.substring(1);
    return host == domain || host.endsWith('.$domain');
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'secure': secure,
  };

  factory CloudDriveCookie.fromJson(Map<String, dynamic> json) {
    return CloudDriveCookie(
      name: _text(json['name']),
      value: _text(json['value']),
      domain: _text(json['domain']),
      path: _optional(json['path']) ?? '/',
      secure: json['secure'] != false,
    );
  }
}

/// Cookie jar kept out of the account metadata file.
class CloudDriveCredential {
  static const int currentVersion = 2;

  const CloudDriveCredential({
    this.version = currentVersion,
    required this.cookies,
    this.capturedAt,
    this.secrets = const <String, String>{},
  });

  final int version;
  final List<CloudDriveCookie> cookies;
  final DateTime? capturedAt;

  /// Tokens and device keys belong in secure storage, never account metadata.
  final Map<String, String> secrets;

  String headerFor(Uri uri) {
    final pairs = <String>[];
    final seen = <String>{};
    for (final cookie in cookies) {
      if (!cookie.matches(uri) || !seen.add(cookie.name)) continue;
      if (RegExp(r'[\r\n;]').hasMatch('${cookie.name}${cookie.value}')) {
        continue;
      }
      pairs.add('${cookie.name}=${cookie.value}');
    }
    return pairs.join('; ');
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'capturedAt': capturedAt?.toIso8601String(),
    'cookies': cookies.map((cookie) => cookie.toJson()).toList(),
    if (secrets.isNotEmpty) 'secrets': secrets,
  };

  factory CloudDriveCredential.fromJson(Map<String, dynamic> json) {
    final raw = json['cookies'];
    final cookies = raw is List
        ? raw
              .whereType<Map>()
              .map(
                (entry) =>
                    CloudDriveCookie.fromJson(Map<String, dynamic>.from(entry)),
              )
              .where(
                (cookie) => cookie.name.isNotEmpty && cookie.value.isNotEmpty,
              )
              .toList()
        : const <CloudDriveCookie>[];
    return CloudDriveCredential(
      version: json['version'] is int ? json['version'] as int : currentVersion,
      capturedAt: DateTime.tryParse('${json['capturedAt'] ?? ''}'),
      cookies: cookies,
      secrets: json['secrets'] is Map
          ? Map<String, String>.unmodifiable({
              for (final entry in (json['secrets'] as Map).entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            })
          : const {},
    );
  }

  static CloudDriveCredential? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return CloudDriveCredential.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}

class CloudDriveEntry {
  const CloudDriveEntry({
    required this.providerId,
    required this.accountLocalId,
    required this.remoteAccountId,
    required this.driveId,
    required this.fileId,
    required this.parentFileId,
    required this.name,
    required this.kind,
    this.pathHint,
    this.size,
    this.modifiedAt,
    this.durationMs,
    this.thumbnailRef,
    this.revision,
  });

  final String providerId;
  final String accountLocalId;
  final String remoteAccountId;
  final String driveId;
  final String fileId;
  final String parentFileId;
  final String? pathHint;
  final String name;
  final CloudDriveEntryKind kind;
  final int? size;
  final DateTime? modifiedAt;
  final int? durationMs;
  final String? thumbnailRef;
  final String? revision;
}

class CloudDrivePage {
  const CloudDrivePage({
    required this.entries,
    required this.nextCursor,
    required this.hasMore,
    required this.sort,
  });

  final List<CloudDriveEntry> entries;
  final String? nextCursor;
  final bool hasMore;
  final CloudDriveSort sort;
}

class CloudDriveQualityChoice {
  const CloudDriveQualityChoice({
    required this.id,
    required this.label,
    required this.transcoded,
    required this.complete,
    this.availability = CloudDriveQualityAvailability.available,
    this.statusDetail,
  });

  final String id;
  final String label;
  final bool transcoded;
  final bool complete;
  final CloudDriveQualityAvailability availability;

  /// Why a rung is still being probed or cannot be selected.
  final String? statusDetail;

  bool get selectable =>
      availability == CloudDriveQualityAvailability.available && complete;
}

/// Playlist bytes already read while resolving a source.
///
/// The gateway can answer the player's first manifest GET from this snapshot.
/// A URI alone still forces that GET back upstream. Never persist the text:
/// it can embed signed segment URLs.
class CloudDriveManifestSnapshot {
  const CloudDriveManifestSnapshot({
    required this.text,
    required this.baseUri,
    required this.fetchedAt,
    this.contentType = 'application/vnd.apple.mpegurl',
    this.mutable = false,
  });

  final String text;
  final Uri baseUri;
  final DateTime fetchedAt;
  final String contentType;

  /// A live playlist may be served once, then the next GET must refresh it.
  /// VOD snapshots stay reusable until the conservative TTL.
  final bool mutable;
}

/// In-memory playback target. Signed URLs and cookies are never persisted.
class CloudDrivePlaybackDescriptor {
  const CloudDrivePlaybackDescriptor({
    required this.upstreamUri,
    required this.transport,
    required this.quality,
    required this.fileId,
    required this.revision,
    required this.complete,
    required this.seekable,
    required this.userAgent,
    required this.referer,
    required this.cookies,
    this.providerId = '',
    this.accountLocalId = '',
    this.remoteAccountId = '',
    this.driveId = '0',
    this.pathHint,
    this.expiresAt,
    this.transcoded = false,
    this.qualities = const <CloudDriveQualityChoice>[],
    this.durationMs,
    this.sizeBytes,
    this.mediaKind = CloudDriveMediaKind.video,
    this.generation = 0,
    this.verifiedComplete = false,
    this.playbackSessionId = '',
    this.manifest,
  });

  final Uri upstreamUri;
  final CloudDriveTransport transport;
  final CloudDriveQualityChoice quality;
  final String fileId;
  final String revision;
  final bool complete;
  final bool seekable;
  final String userAgent;
  final String referer;
  final List<CloudDriveCookie> cookies;
  final String providerId;
  final String accountLocalId;
  final String remoteAccountId;
  final String driveId;
  final String? pathHint;
  final DateTime? expiresAt;
  final bool transcoded;
  final List<CloudDriveQualityChoice> qualities;

  /// Vendor duration in milliseconds, when the API states the unit.
  final int? durationMs;
  final int? sizeBytes;
  final CloudDriveMediaKind mediaKind;

  /// Bumps on each successful URL refresh so a late reply cannot roll it back.
  final int generation;

  /// True only when a media playlist was measured against a known duration.
  final bool verifiedComplete;
  final String playbackSessionId;

  /// In-memory playlist body from the resolve that produced this descriptor.
  final CloudDriveManifestSnapshot? manifest;

  CloudDrivePlaybackDescriptor copyWith({
    Uri? upstreamUri,
    String? revision,
    bool? seekable,
    bool? complete,
    bool? verifiedComplete,
    List<CloudDriveCookie>? cookies,
    DateTime? expiresAt,
    List<CloudDriveQualityChoice>? qualities,
    CloudDriveQualityChoice? quality,
    int? generation,
    int? durationMs,
    int? sizeBytes,
    String? playbackSessionId,
    CloudDriveMediaKind? mediaKind,
    CloudDriveManifestSnapshot? manifest,
    bool dropManifest = false,
  }) {
    return CloudDrivePlaybackDescriptor(
      upstreamUri: upstreamUri ?? this.upstreamUri,
      transport: transport,
      quality: quality ?? this.quality,
      fileId: fileId,
      revision: revision ?? this.revision,
      complete: complete ?? this.complete,
      seekable: seekable ?? this.seekable,
      userAgent: userAgent,
      referer: referer,
      cookies: cookies ?? this.cookies,
      providerId: providerId,
      accountLocalId: accountLocalId,
      remoteAccountId: remoteAccountId,
      driveId: driveId,
      pathHint: pathHint,
      expiresAt: expiresAt ?? this.expiresAt,
      transcoded: transcoded,
      qualities: qualities ?? this.qualities,
      durationMs: durationMs ?? this.durationMs,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      mediaKind: mediaKind ?? this.mediaKind,
      generation: generation ?? this.generation,
      verifiedComplete: verifiedComplete ?? this.verifiedComplete,
      playbackSessionId: playbackSessionId ?? this.playbackSessionId,
      manifest: dropManifest ? null : manifest ?? this.manifest,
    );
  }
}

/// Stable in-memory identity for a cookie jar. Not a secret log line.
String cloudDriveCredentialStamp(CloudDriveCredential credential) {
  final ordered = [
    ...credential.cookies,
  ]..sort((a, b) => '${a.domain}|${a.name}'.compareTo('${b.domain}|${b.name}'));
  var hash = 0x811c9dc5;
  for (final cookie in ordered) {
    final material =
        '${cookie.domain}\u0000${cookie.name}\u0000${cookie.value}\u0000';
    for (final unit in material.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
  }
  final secretKeys = credential.secrets.keys.toList()..sort();
  for (final key in secretKeys) {
    for (final unit in '$key\u0000${credential.secrets[key]}\u0000'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
  }
  return hash.toRadixString(16);
}

/// One subtitle the provider can actually read. URLs stay out of the library.
class CloudDriveSubtitleTrack {
  const CloudDriveSubtitleTrack({
    required this.id,
    required this.label,
    required this.format,
    required this.origin,
    this.language,
    this.fileId,
    this.pathHint,
    this.revision,
    this.autoSelect = false,
    this.textAvailable = true,
    this.remoteUri,
    this.isAi = false,
  });

  final String id;
  final String label;
  final String? language;
  final String format;
  final CloudDriveSubtitleOrigin origin;
  final String? fileId;
  final String? pathHint;
  final String? revision;
  final bool autoSelect;
  final bool textAvailable;

  /// Set only from an explicit AI marker on the track. A Baidu origin is not one.
  final bool isAi;

  /// In-memory download address. Never written to the library or logs.
  final Uri? remoteUri;

  CloudDriveSubtitleTrack copyWith({Uri? remoteUri, bool? textAvailable}) {
    return CloudDriveSubtitleTrack(
      id: id,
      label: label,
      format: format,
      origin: origin,
      language: language,
      fileId: fileId,
      pathHint: pathHint,
      revision: revision,
      autoSelect: autoSelect,
      textAvailable: textAvailable ?? this.textAvailable,
      remoteUri: remoteUri ?? this.remoteUri,
      isAi: isAi,
    );
  }
}

enum CloudDriveSubtitleOrigin { provider, sidecar, embedded }

class CloudDriveSubtitleReadRequest {
  const CloudDriveSubtitleReadRequest({
    required this.credential,
    required this.accountLocalId,
    required this.remoteAccountId,
    required this.driveId,
    required this.track,
  });

  final CloudDriveCredential credential;
  final String accountLocalId;
  final String remoteAccountId;
  final String driveId;
  final CloudDriveSubtitleTrack track;
}

const Object _unset = Object();

String _text(Object? value) => value?.toString().trim() ?? '';

String? _optional(Object? value) {
  final text = _text(value);
  return text.isEmpty ? null : text;
}

/// Drops cookies, tokens, signed URLs and lease tokens before anything is logged.
///
/// Private file names are not recoverable from the redacted line. Callers that
/// need to correlate a playback use [playbackSessionId] instead of the path.
String redactCloudDriveLog(String input) {
  var text = input.replaceAll(
    RegExp(r'https?://\S+', caseSensitive: false),
    '<url>',
  );
  text = text.replaceAll(RegExp(r'/cd/[A-Za-z0-9_-]+'), '/cd/<lease>');
  text = text.replaceAllMapped(
    RegExp(
      r'(authorization|cookie|bduss|stoken|baiduid|access_token|refresh_token|private_key|x-signature)\s*[:=]\s*[^;\s,]+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=<redacted>',
  );
  const sensitive = [
    'BDUSS',
    'STOKEN',
    '__puus',
    '__pus',
    '__kps',
    '__ktd',
    '__uid',
    'cookie',
    'token',
    'access_token',
    'sign',
  ];
  for (final key in sensitive) {
    final lower = text.toLowerCase();
    final needle = '${key.toLowerCase()}=';
    var start = 0;
    final buffer = StringBuffer();
    var changed = false;
    while (true) {
      final index = lower.indexOf(needle, start);
      if (index < 0) break;
      changed = true;
      buffer.write(text.substring(start, index + needle.length));
      buffer.write('<redacted>');
      var end = index + needle.length;
      while (end < text.length &&
          !'& ;'.contains(text[end]) &&
          text[end] != '\n') {
        end++;
      }
      start = end;
    }
    if (changed) {
      buffer.write(text.substring(start));
      text = buffer.toString();
    }
  }
  return text;
}
