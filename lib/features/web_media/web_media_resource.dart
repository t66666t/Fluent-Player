/// The transport of a discovered candidate, not a guarantee of playability.
enum WebMediaKind { video, audio, hls, dash }

enum WebMediaProbeState { untested, probing, complete, unavailable }

/// These CDNs serve byte windows of a complete adaptive track. Keep every
/// signing/track parameter; do not generalize this to arbitrary segment URLs.
String webMediaDownloadUrl(String value) {
  final uri = safeWebMediaUri(value);
  if (uri == null) return value;
  final host = uri.host.toLowerCase();
  final keys = <String>{};
  if (host.endsWith('.googlevideo.com') &&
      uri.path.endsWith('/videoplayback') &&
      uri.queryParameters.containsKey('itag') &&
      !uri.queryParameters.containsKey('sq') &&
      uri.queryParameters['sabr'] != '1' &&
      uri.queryParameters['ump'] != '1') {
    keys.add('range');
  }
  if (host.endsWith('.fbcdn.net') || host.endsWith('.cdninstagram.com')) {
    keys.addAll(['bytestart', 'byteend', '_nc_rmd']);
  }
  if (!keys.any(uri.queryParameters.containsKey)) return value;
  // Preserve the raw signed query rather than decoding/re-encoding it.
  return uri
      .replace(
        query: uri.query
            .split('&')
            .where(
              (part) => !keys.contains(part.split('=').first.toLowerCase()),
            )
            .join('&'),
      )
      .toString();
}

/// Only signing parameters are ignored when matching a fresh capture to a
/// queued resource. Track IDs, quality and every other query stay significant.
String webMediaResourceIdentity(String value) {
  final uri = safeWebMediaUri(value);
  if (uri == null) return value;
  const volatile = {
    'token',
    'sign',
    'signature',
    'sig',
    'expires',
    'expire',
    'deadline',
    'wssecret',
    'wstime',
    'auth_key',
    'hdnts',
    'policy',
    'key-pair-id',
    'x-amz-signature',
    'x-amz-date',
    'x-amz-expires',
    'x-amz-credential',
    'x-amz-security-token',
  };
  final parameters =
      uri.queryParametersAll.entries
          .where((e) => !volatile.contains(e.key.toLowerCase()))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key));
  return uri
      .replace(
        queryParameters: {
          for (final entry in parameters) entry.key: entry.value,
        },
      )
      .toString();
}

class WebMediaMetadata {
  const WebMediaMetadata({
    this.mimeType,
    this.format,
    this.byteSize,
    this.sizeEstimated = false,
    this.hasVideo,
    this.hasAudio,
    this.width,
    this.height,
    this.videoCodec,
    this.audioCodec,
    this.state = WebMediaProbeState.untested,
  });
  final String? mimeType;
  final String? format;
  final int? byteSize;
  final bool sizeEstimated;
  final bool? hasVideo;
  final bool? hasAudio;
  final int? width;
  final int? height;
  final String? videoCodec;
  final String? audioCodec;
  final WebMediaProbeState state;

  WebMediaMetadata copyWith({
    String? mimeType,
    String? format,
    int? byteSize,
    bool? sizeEstimated,
    bool? hasVideo,
    bool? hasAudio,
    int? width,
    int? height,
    String? videoCodec,
    String? audioCodec,
    WebMediaProbeState? state,
  }) => WebMediaMetadata(
    mimeType: mimeType ?? this.mimeType,
    format: format ?? this.format,
    byteSize: byteSize ?? this.byteSize,
    sizeEstimated: sizeEstimated ?? this.sizeEstimated,
    hasVideo: hasVideo ?? this.hasVideo,
    hasAudio: hasAudio ?? this.hasAudio,
    width: width ?? this.width,
    height: height ?? this.height,
    videoCodec: videoCodec ?? this.videoCodec,
    audioCodec: audioCodec ?? this.audioCodec,
    state: state ?? this.state,
  );
}

class WebMediaPagePlayer {
  const WebMediaPagePlayer({
    required this.id,
    required this.title,
    required this.isAudio,
    this.duration,
    this.isActive = false,
    this.isVisible = true,
    this.sourceKey,
    this.frameUrl,
    this.videoPageUrl,
    this.currentUrl,
    this.height,
    this.audioLanguage,
  });
  final String id;
  final String title;
  final bool isAudio;
  final Duration? duration;
  final bool isActive;
  final bool isVisible;
  final String? sourceKey;
  final Uri? frameUrl;
  final Uri? videoPageUrl;
  final String? currentUrl;
  final int? height;
  final String? audioLanguage;
}

/// Accept only web resources. Object URLs belong to a page's JS environment.
Uri? safeWebMediaUri(String value, {Uri? baseUrl}) {
  if (value.length > 8192 || RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
    return null;
  }
  var uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (!uri.hasScheme && baseUrl != null) uri = baseUrl.resolveUri(uri);
  if ((uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.removeFragment();
}

/// Keep the per-resource authentication context, but let the consumer generate
/// its own Range/transport headers. Never persist this map or pass it to logs.
Map<String, String> sanitizeWebMediaHeaders(Map<String, String> headers) {
  const omitted = <String>{
    'host',
    'connection',
    'content-length',
    'transfer-encoding',
    'accept-encoding',
    'range',
    'if-range',
    'upgrade',
    'te',
    'trailer',
  };
  final result = <String, String>{};
  for (final entry in headers.entries.take(64)) {
    final name = entry.key.trim().toLowerCase();
    final value = entry.value;
    if (name.isEmpty ||
        name.length > 128 ||
        !RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$").hasMatch(name) ||
        omitted.contains(name) ||
        name.startsWith('sec-') ||
        name.startsWith('proxy-') ||
        value.length > 8192 ||
        RegExp(r'[\r\n\x00]').hasMatch(value)) {
      continue;
    }
    result[name] = value;
  }
  return Map<String, String>.unmodifiable(result);
}

/// Replay the exact resource's browser context, including an embedded frame's
/// referrer and partitioned cookies. Invent defaults only for missing fields.
Map<String, String> webMediaReplayHeaders(
  WebMediaResource resource, {
  String? userAgent,
}) {
  final uri = safeWebMediaUri(resource.url);
  if (uri == null) throw const FormatException('Unsupported resource');
  final headers = Map<String, String>.of(resource.headers);
  final downgrade =
      resource.sourcePage.scheme == 'https' && uri.scheme == 'http';
  if (downgrade) {
    headers.removeWhere(
      (key, _) => !{'user-agent', 'accept', 'accept-language'}.contains(key),
    );
  } else {
    headers.putIfAbsent(
      'referer',
      () => uri.origin == resource.sourcePage.origin
          ? resource.sourcePage.toString()
          : '${resource.sourcePage.origin}/',
    );
  }
  if (userAgent?.isNotEmpty == true) {
    headers.putIfAbsent('user-agent', () => userAgent!);
  }
  return Map.of(sanitizeWebMediaHeaders(headers));
}

class WebMediaSubtitleCue {
  final Duration start;
  final Duration end;
  final String text;

  const WebMediaSubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });
}

class WebMediaSubtitleTrack {
  final String? url;
  final String label;
  final String language;
  final String kind;
  final List<WebMediaSubtitleCue> cues;

  /// False when the page could expose only a bounded or partial cue snapshot.
  final bool cuesComplete;

  WebMediaSubtitleTrack({
    this.url,
    this.label = '',
    this.language = '',
    this.kind = 'subtitles',
    List<WebMediaSubtitleCue> cues = const [],
    this.cuesComplete = false,
  }) : cues = List<WebMediaSubtitleCue>.unmodifiable(cues);
}

class WebMediaResource {
  final String url;
  final Uri sourcePage;
  final String title;
  final Duration? duration;
  final Map<String, String> headers;
  final List<WebMediaSubtitleTrack> subtitles;
  final bool isActive;
  final WebMediaKind kind;
  final WebMediaMetadata metadata;
  final List<String> playerIds;
  final String? representationId;
  final String? audioGroup;

  /// Positive evidence that this rendition needs a separate audio track.
  final bool requiresAudio;
  final String? language;
  final bool isDefaultAudio;

  WebMediaResource({
    required this.url,
    required this.sourcePage,
    required this.title,
    required this.kind,
    this.duration,
    Map<String, String> headers = const {},
    List<WebMediaSubtitleTrack> subtitles = const [],
    this.isActive = false,
    this.metadata = const WebMediaMetadata(),
    List<String> playerIds = const [],
    this.representationId,
    this.audioGroup,
    this.requiresAudio = false,
    this.language,
    this.isDefaultAudio = false,
  }) : headers = sanitizeWebMediaHeaders(headers),
       playerIds = List<String>.unmodifiable(playerIds),
       subtitles = List<WebMediaSubtitleTrack>.unmodifiable(subtitles);

  Uri get pageUrl => sourcePage;
  String get selectionKey => '$url|${representationId ?? ''}';
  bool get isAudio => metadata.hasVideo == null
      ? kind == WebMediaKind.audio
      : metadata.hasVideo == false && metadata.hasAudio == true;

  /// These candidates may be attempted with the native player. A successful
  /// probe/playback is still needed, particularly for protected or split tracks.
  bool get nativePlayable => true;

  /// Request credentials are intentionally excluded from disk snapshots.
  Map<String, dynamic> toPersistedJson() => {
    'url': url,
    'sourcePage': sourcePage.toString(),
    'title': title,
    'durationMs': duration?.inMilliseconds,
    'kind': kind.name,
    'playerIds': playerIds,
    'representationId': representationId,
    'audioGroup': audioGroup,
    'requiresAudio': requiresAudio,
    'language': language,
    'isDefaultAudio': isDefaultAudio,
    'metadata': {
      'mimeType': metadata.mimeType,
      'format': metadata.format,
      'byteSize': metadata.byteSize,
      'sizeEstimated': metadata.sizeEstimated,
      'hasVideo': metadata.hasVideo,
      'hasAudio': metadata.hasAudio,
      'width': metadata.width,
      'height': metadata.height,
      'videoCodec': metadata.videoCodec,
      'audioCodec': metadata.audioCodec,
      'state': metadata.state.name,
    },
  };

  factory WebMediaResource.fromPersistedJson(Map<String, dynamic> json) {
    final info = Map<String, dynamic>.from(json['metadata'] as Map? ?? {});
    final url = safeWebMediaUri(json['url'] as String? ?? '');
    final page = safeWebMediaUri(json['sourcePage'] as String? ?? '');
    if (url == null || page == null) throw const FormatException('无效的媒体任务');
    return WebMediaResource(
      url: url.toString(),
      sourcePage: page,
      title: json['title'] as String? ?? '网页媒体',
      duration: json['durationMs'] is int
          ? Duration(milliseconds: json['durationMs'])
          : null,
      kind: WebMediaKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => WebMediaKind.video,
      ),
      playerIds: (json['playerIds'] as List? ?? [])
          .whereType<String>()
          .toList(),
      headers: {'Referer': page.toString()},
      representationId: json['representationId'] as String?,
      audioGroup: json['audioGroup'] as String?,
      requiresAudio: json['requiresAudio'] == true,
      language: json['language'] as String?,
      isDefaultAudio: json['isDefaultAudio'] == true,
      metadata: WebMediaMetadata(
        mimeType: info['mimeType'],
        format: info['format'],
        byteSize: info['byteSize'],
        sizeEstimated: info['sizeEstimated'] == true,
        hasVideo: info['hasVideo'],
        hasAudio: info['hasAudio'],
        width: info['width'],
        height: info['height'],
        videoCodec: info['videoCodec'],
        audioCodec: info['audioCodec'],
        state: WebMediaProbeState.values.firstWhere(
          (v) => v.name == info['state'],
          orElse: () => WebMediaProbeState.untested,
        ),
      ),
    );
  }

  WebMediaResource copyWith({
    String? url,
    Uri? sourcePage,
    String? title,
    WebMediaKind? kind,
    Duration? duration,
    Map<String, String>? headers,
    List<WebMediaSubtitleTrack>? subtitles,
    bool? isActive,
    WebMediaMetadata? metadata,
    List<String>? playerIds,
    String? representationId,
    String? audioGroup,
    bool? requiresAudio,
    String? language,
    bool? isDefaultAudio,
  }) => WebMediaResource(
    url: url ?? this.url,
    sourcePage: sourcePage ?? this.sourcePage,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    duration: duration ?? this.duration,
    headers: headers ?? this.headers,
    subtitles: subtitles ?? this.subtitles,
    isActive: isActive ?? this.isActive,
    metadata: metadata ?? this.metadata,
    playerIds: playerIds ?? this.playerIds,
    representationId: representationId ?? this.representationId,
    audioGroup: audioGroup ?? this.audioGroup,
    requiresAudio: requiresAudio ?? this.requiresAudio,
    language: language ?? this.language,
    isDefaultAudio: isDefaultAudio ?? this.isDefaultAudio,
  );
}
