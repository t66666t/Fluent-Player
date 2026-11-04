import 'dart:convert';
import '../../../models/import_card_placement.dart';
import '../../../models/download_import_context.dart';

import 'package:video_player_app/models/media_source_ref.dart';

const Object _unset = Object();

enum YtDlpTaskStatus {
  pending,
  queued,
  resolving,
  pausing,
  downloading,
  postProcessing,
  paused,
  completed,
  exported,
  failed,
  cancelled,
}

enum YtDlpFailureType {
  none,
  networkTimeout,
  extractionFailed,
  authFailed,
  proxyFailed,
  postProcessingFailed,
  noFormatAvailable,
  fileWriteFailed,
  userCancelled,
  unsupported,
  unknown,
}

enum YtDlpFallbackStep {
  originalRetry,
  reduceConcurrentFragments,
  increaseTimeout,
  applyRateLimit,
  switchPlayerClient,
  enableCookies,
  applyCustomUserAgent,
  injectVisitorData,
  injectPoToken,
  switchProxy,
}

class ThumbnailInfo {
  final String url;
  final int? width;
  final int? height;
  final String? id;

  const ThumbnailInfo({required this.url, this.width, this.height, this.id});

  Map<String, dynamic> toJson() => {
    'url': url,
    'width': width,
    'height': height,
    'id': id,
  };

  factory ThumbnailInfo.fromJson(Map<String, dynamic> json) {
    return ThumbnailInfo(
      url: (json['url'] ?? '').toString(),
      width: _toInt(json['width']),
      height: _toInt(json['height']),
      id: json['id']?.toString(),
    );
  }
}

class ChapterInfo {
  final String title;
  final double? startTimeSeconds;
  final double? endTimeSeconds;

  const ChapterInfo({
    required this.title,
    this.startTimeSeconds,
    this.endTimeSeconds,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'startTimeSeconds': startTimeSeconds,
    'endTimeSeconds': endTimeSeconds,
  };

  factory ChapterInfo.fromJson(Map<String, dynamic> json) {
    return ChapterInfo(
      title: (json['title'] ?? '').toString(),
      startTimeSeconds: _toDouble(json['startTimeSeconds']),
      endTimeSeconds: _toDouble(json['endTimeSeconds']),
    );
  }
}

class VideoFormat {
  final String formatId;
  final String ext;
  final String? container;
  final String? videoCodec;
  final String? audioCodec;
  final int? width;
  final int? height;
  final double? fps;
  final int? bitrate;
  final int? fileSize;
  final String? formatNote;
  final bool hasAudio;
  final bool isHdr;

  const VideoFormat({
    required this.formatId,
    required this.ext,
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.width,
    this.height,
    this.fps,
    this.bitrate,
    this.fileSize,
    this.formatNote,
    this.hasAudio = false,
    this.isHdr = false,
  });

  String get displayLabel {
    final resolution = height != null ? '${height}p' : '未知分辨率';
    final codec = (videoCodec == null || videoCodec!.isEmpty)
        ? 'unknown'
        : videoCodec!;
    return '$resolution + $ext + $codec';
  }

  Map<String, dynamic> toJson() => {
    'formatId': formatId,
    'ext': ext,
    'container': container,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'width': width,
    'height': height,
    'fps': fps,
    'bitrate': bitrate,
    'fileSize': fileSize,
    'formatNote': formatNote,
    'hasAudio': hasAudio,
    'isHdr': isHdr,
  };

  factory VideoFormat.fromJson(Map<String, dynamic> json) {
    return VideoFormat(
      formatId: (json['formatId'] ?? '').toString(),
      ext: (json['ext'] ?? '').toString(),
      container: json['container']?.toString(),
      videoCodec: json['videoCodec']?.toString(),
      audioCodec: json['audioCodec']?.toString(),
      width: _toInt(json['width']),
      height: _toInt(json['height']),
      fps: _toDouble(json['fps']),
      bitrate: _toInt(json['bitrate']),
      fileSize: _toInt(json['fileSize']),
      formatNote: json['formatNote']?.toString(),
      hasAudio: json['hasAudio'] == true,
      isHdr: json['isHdr'] == true,
    );
  }
}

class AudioFormat {
  final String formatId;
  final String ext;
  final String? audioCodec;
  final int? audioSampleRate;
  final int? bitrate;
  final int? fileSize;
  final String? language;
  final bool isDefaultTrack;
  final String? protocol;
  final int? qualityRank;

  const AudioFormat({
    required this.formatId,
    required this.ext,
    this.audioCodec,
    this.audioSampleRate,
    this.bitrate,
    this.fileSize,
    this.language,
    this.isDefaultTrack = false,
    this.protocol,
    this.qualityRank,
  });

  /// YouTube DRC renditions share a bitrate with the normal track (`140-drc`).
  bool get isDynamicRangeCompressed {
    final id = formatId.toLowerCase();
    return id.contains('-drc') || id.contains('.drc');
  }

  Map<String, dynamic> toJson() => {
    'formatId': formatId,
    'ext': ext,
    'audioCodec': audioCodec,
    'audioSampleRate': audioSampleRate,
    'bitrate': bitrate,
    'fileSize': fileSize,
    'language': language,
    'isDefaultTrack': isDefaultTrack,
    'protocol': protocol,
    'qualityRank': qualityRank,
  };

  factory AudioFormat.fromJson(Map<String, dynamic> json) {
    return AudioFormat(
      formatId: (json['formatId'] ?? '').toString(),
      ext: (json['ext'] ?? '').toString(),
      audioCodec: json['audioCodec']?.toString(),
      audioSampleRate: _toInt(json['audioSampleRate']),
      bitrate: _toInt(json['bitrate']),
      fileSize: _toInt(json['fileSize']),
      language: json['language']?.toString(),
      isDefaultTrack: json['isDefaultTrack'] == true,
      protocol: json['protocol']?.toString(),
      qualityRank: _toInt(json['qualityRank']),
    );
  }
}

class SubtitleTrack {
  final String languageCode;
  final String displayName;
  final bool isAutoGenerated;
  final List<String> extCandidates;

  const SubtitleTrack({
    required this.languageCode,
    required this.displayName,
    this.isAutoGenerated = false,
    this.extCandidates = const [],
  });

  String get selectionKey =>
      '$languageCode|${isAutoGenerated ? 'auto' : 'manual'}';

  Map<String, dynamic> toJson() => {
    'languageCode': languageCode,
    'displayName': displayName,
    'isAutoGenerated': isAutoGenerated,
    'extCandidates': extCandidates,
  };

  factory SubtitleTrack.fromJson(Map<String, dynamic> json) {
    return SubtitleTrack(
      languageCode: (json['languageCode'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      isAutoGenerated: json['isAutoGenerated'] == true,
      extCandidates: (json['extCandidates'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(),
    );
  }
}

class PoTokenConfig {
  final String client;
  final String context;
  final String token;
  final bool enabled;

  const PoTokenConfig({
    required this.client,
    required this.context,
    required this.token,
    this.enabled = true,
  });

  bool get hasValue => token.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
    'client': client,
    'context': context,
    'token': token,
    'enabled': enabled,
  };

  factory PoTokenConfig.fromJson(Map<String, dynamic> json) {
    return PoTokenConfig(
      client: (json['client'] ?? '').toString(),
      context: (json['context'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      enabled: json['enabled'] != false,
    );
  }
}

class DownloadSessionConfig {
  final bool singleVideo;
  final String? referer;
  final bool useCookies;
  final String? cookiesFilePath;
  final bool useCustomUserAgent;
  final String? userAgent;
  final bool useProxy;
  final String? proxy;
  final int? socketTimeoutSeconds;
  final int? retries;
  final int? fragmentRetries;
  final int? concurrentFragments;
  final String? rateLimit;
  final bool forceIpv4;
  final List<String> enabledPlayerClients;
  final List<PoTokenConfig> poTokens;
  final String? visitorData;
  final bool debugLoggingEnabled;
  final String? outputDirectory;

  const DownloadSessionConfig({
    this.singleVideo = false,
    this.referer,
    this.useCookies = false,
    this.cookiesFilePath,
    this.useCustomUserAgent = false,
    this.userAgent,
    this.useProxy = false,
    this.proxy,
    this.socketTimeoutSeconds,
    this.retries = 2,
    this.fragmentRetries = 2,
    this.concurrentFragments = 16,
    this.rateLimit,
    this.forceIpv4 = false,
    this.enabledPlayerClients = const [],
    this.poTokens = const [],
    this.visitorData,
    this.debugLoggingEnabled = false,
    this.outputDirectory,
  });

  factory DownloadSessionConfig.defaults() => const DownloadSessionConfig();

  DownloadSessionConfig copyWith({
    bool? singleVideo,
    String? referer,
    bool? useCookies,
    Object? cookiesFilePath = _unset,
    bool? useCustomUserAgent,
    Object? userAgent = _unset,
    bool? useProxy,
    Object? proxy = _unset,
    Object? socketTimeoutSeconds = _unset,
    Object? retries = _unset,
    Object? fragmentRetries = _unset,
    Object? concurrentFragments = _unset,
    Object? rateLimit = _unset,
    bool? forceIpv4,
    List<String>? enabledPlayerClients,
    List<PoTokenConfig>? poTokens,
    Object? visitorData = _unset,
    bool? debugLoggingEnabled,
    Object? outputDirectory = _unset,
  }) {
    return DownloadSessionConfig(
      singleVideo: singleVideo ?? this.singleVideo,
      referer: referer ?? this.referer,
      useCookies: useCookies ?? this.useCookies,
      cookiesFilePath: identical(cookiesFilePath, _unset)
          ? this.cookiesFilePath
          : cookiesFilePath as String?,
      useCustomUserAgent: useCustomUserAgent ?? this.useCustomUserAgent,
      userAgent: identical(userAgent, _unset)
          ? this.userAgent
          : userAgent as String?,
      useProxy: useProxy ?? this.useProxy,
      proxy: identical(proxy, _unset) ? this.proxy : proxy as String?,
      socketTimeoutSeconds: identical(socketTimeoutSeconds, _unset)
          ? this.socketTimeoutSeconds
          : socketTimeoutSeconds as int?,
      retries: identical(retries, _unset) ? this.retries : retries as int?,
      fragmentRetries: identical(fragmentRetries, _unset)
          ? this.fragmentRetries
          : fragmentRetries as int?,
      concurrentFragments: identical(concurrentFragments, _unset)
          ? this.concurrentFragments
          : concurrentFragments as int?,
      rateLimit: identical(rateLimit, _unset)
          ? this.rateLimit
          : rateLimit as String?,
      forceIpv4: forceIpv4 ?? this.forceIpv4,
      enabledPlayerClients: enabledPlayerClients ?? this.enabledPlayerClients,
      poTokens: poTokens ?? this.poTokens,
      visitorData: identical(visitorData, _unset)
          ? this.visitorData
          : visitorData as String?,
      debugLoggingEnabled: debugLoggingEnabled ?? this.debugLoggingEnabled,
      outputDirectory: identical(outputDirectory, _unset)
          ? this.outputDirectory
          : outputDirectory as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'singleVideo': singleVideo,
    'referer': referer,
    'useCookies': useCookies,
    'cookiesFilePath': cookiesFilePath,
    'useCustomUserAgent': useCustomUserAgent,
    'userAgent': userAgent,
    'socketTimeoutSeconds': socketTimeoutSeconds,
    'retries': retries,
    'fragmentRetries': fragmentRetries,
    'concurrentFragments': concurrentFragments,
    'rateLimit': rateLimit,
    'forceIpv4': forceIpv4,
    'enabledPlayerClients': enabledPlayerClients,
    'poTokens': poTokens.map((item) => item.toJson()).toList(),
    'visitorData': visitorData,
    'debugLoggingEnabled': debugLoggingEnabled,
    'outputDirectory': outputDirectory,
  };

  /// Used only for an active native invocation. Persistent snapshots never
  /// retain proxy credentials or the ephemeral loopback bridge address.
  Map<String, dynamic> toRuntimeJson() => {
    ...toJson(),
    'useProxy': useProxy,
    'proxy': proxy,
  };

  factory DownloadSessionConfig.fromJson(Map<String, dynamic> json) {
    return DownloadSessionConfig(
      singleVideo: json['singleVideo'] == true,
      referer: _nullableString(json['referer']),
      useCookies: json['useCookies'] == true,
      cookiesFilePath: _nullableString(json['cookiesFilePath']),
      useCustomUserAgent: json['useCustomUserAgent'] == true,
      userAgent: _nullableString(json['userAgent']),
      useProxy: json['useProxy'] == true,
      proxy: _nullableString(json['proxy']),
      socketTimeoutSeconds: _toInt(json['socketTimeoutSeconds']),
      retries: _toInt(json['retries']),
      fragmentRetries: _toInt(json['fragmentRetries']),
      concurrentFragments: _toInt(json['concurrentFragments']),
      rateLimit: _nullableString(json['rateLimit']),
      forceIpv4: json['forceIpv4'] == true,
      enabledPlayerClients: (json['enabledPlayerClients'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(),
      poTokens: (json['poTokens'] as List? ?? const [])
          .map(
            (item) => PoTokenConfig.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      visitorData: _nullableString(json['visitorData']),
      debugLoggingEnabled: json['debugLoggingEnabled'] == true,
      outputDirectory: _nullableString(json['outputDirectory']),
    );
  }
}

class YtDlpDownloadPreferences {
  static int normalizeConcurrentDownloads(int? value) =>
      value == null || value < 1 ? 1 : value;

  final int maxConcurrentDownloads;
  final String preferredQuality;
  final List<String> preferredSubtitleLanguages;
  final bool autoDeleteTaskAfterImport;
  final bool autoExpandTaskOptions;

  const YtDlpDownloadPreferences({
    this.maxConcurrentDownloads = 1,
    this.preferredQuality = 'best',
    this.preferredSubtitleLanguages = const [],
    this.autoDeleteTaskAfterImport = false,
    this.autoExpandTaskOptions = true,
  });

  factory YtDlpDownloadPreferences.defaults() =>
      const YtDlpDownloadPreferences();

  YtDlpDownloadPreferences copyWith({
    int? maxConcurrentDownloads,
    String? preferredQuality,
    List<String>? preferredSubtitleLanguages,
    bool? autoDeleteTaskAfterImport,
    bool? autoExpandTaskOptions,
  }) {
    return YtDlpDownloadPreferences(
      maxConcurrentDownloads: normalizeConcurrentDownloads(
        maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      ),
      preferredQuality: preferredQuality ?? this.preferredQuality,
      preferredSubtitleLanguages:
          preferredSubtitleLanguages ?? this.preferredSubtitleLanguages,
      autoDeleteTaskAfterImport:
          autoDeleteTaskAfterImport ?? this.autoDeleteTaskAfterImport,
      autoExpandTaskOptions:
          autoExpandTaskOptions ?? this.autoExpandTaskOptions,
    );
  }

  Map<String, dynamic> toJson() => {
    'maxConcurrentDownloads': maxConcurrentDownloads,
    'preferredQuality': preferredQuality,
    'preferredSubtitleLanguages': preferredSubtitleLanguages,
    'autoDeleteTaskAfterImport': autoDeleteTaskAfterImport,
    'autoExpandTaskOptions': autoExpandTaskOptions,
  };

  factory YtDlpDownloadPreferences.fromJson(Map<String, dynamic> json) {
    return YtDlpDownloadPreferences(
      maxConcurrentDownloads: normalizeConcurrentDownloads(
        _toInt(json['maxConcurrentDownloads']),
      ),
      preferredQuality: (json['preferredQuality'] ?? 'best').toString(),
      preferredSubtitleLanguages:
          (json['preferredSubtitleLanguages'] as List? ?? const [])
              .map((item) => item.toString())
              .toList(),
      autoDeleteTaskAfterImport: json['autoDeleteTaskAfterImport'] == true,
      autoExpandTaskOptions: json['autoExpandTaskOptions'] != false,
    );
  }
}

class DownloadSelection {
  final bool audioOnly;
  final String? selectedVideoFormatId;
  final List<String> selectedAudioFormatIds;
  final List<String> selectedSubtitleTrackKeys;
  final List<String> subtitleLanguages;
  final bool writeSubtitles;
  final bool writeAutoSubtitles;
  final bool embedSubtitles;
  final bool removeAudio;
  final String outputContainer;
  final bool enableCompatibilityMode;

  const DownloadSelection({
    this.audioOnly = false,
    this.selectedVideoFormatId,
    this.selectedAudioFormatIds = const [],
    this.selectedSubtitleTrackKeys = const [],
    this.subtitleLanguages = const [],
    this.writeSubtitles = false,
    this.writeAutoSubtitles = false,
    this.embedSubtitles = false,
    this.removeAudio = false,
    this.outputContainer = 'mkv',
    this.enableCompatibilityMode = false,
  });

  DownloadSelection copyWith({
    bool? audioOnly,
    String? selectedVideoFormatId,
    List<String>? selectedAudioFormatIds,
    List<String>? selectedSubtitleTrackKeys,
    List<String>? subtitleLanguages,
    bool? writeSubtitles,
    bool? writeAutoSubtitles,
    bool? embedSubtitles,
    bool? removeAudio,
    String? outputContainer,
    bool? enableCompatibilityMode,
  }) {
    return DownloadSelection(
      audioOnly: audioOnly ?? this.audioOnly,
      selectedVideoFormatId:
          selectedVideoFormatId ?? this.selectedVideoFormatId,
      selectedAudioFormatIds:
          selectedAudioFormatIds ?? this.selectedAudioFormatIds,
      selectedSubtitleTrackKeys:
          selectedSubtitleTrackKeys ?? this.selectedSubtitleTrackKeys,
      subtitleLanguages: subtitleLanguages ?? this.subtitleLanguages,
      writeSubtitles: writeSubtitles ?? this.writeSubtitles,
      writeAutoSubtitles: writeAutoSubtitles ?? this.writeAutoSubtitles,
      embedSubtitles: embedSubtitles ?? this.embedSubtitles,
      removeAudio: removeAudio ?? this.removeAudio,
      outputContainer: outputContainer ?? this.outputContainer,
      enableCompatibilityMode:
          enableCompatibilityMode ?? this.enableCompatibilityMode,
    );
  }

  Map<String, dynamic> toJson() => {
    'audioOnly': audioOnly,
    'selectedVideoFormatId': selectedVideoFormatId,
    'selectedAudioFormatIds': selectedAudioFormatIds,
    'selectedSubtitleTrackKeys': selectedSubtitleTrackKeys,
    'subtitleLanguages': subtitleLanguages,
    'writeSubtitles': writeSubtitles,
    'writeAutoSubtitles': writeAutoSubtitles,
    'embedSubtitles': embedSubtitles,
    'removeAudio': removeAudio,
    'outputContainer': outputContainer,
    'enableCompatibilityMode': enableCompatibilityMode,
  };

  factory DownloadSelection.fromJson(Map<String, dynamic> json) {
    return DownloadSelection(
      audioOnly: json['audioOnly'] == true,
      selectedVideoFormatId: _nullableString(json['selectedVideoFormatId']),
      selectedAudioFormatIds:
          (json['selectedAudioFormatIds'] as List? ?? const [])
              .map((item) => item.toString())
              .toList(),
      selectedSubtitleTrackKeys:
          (json['selectedSubtitleTrackKeys'] as List? ?? const [])
              .map((item) => item.toString())
              .toList(),
      subtitleLanguages: (json['subtitleLanguages'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(),
      writeSubtitles: json['writeSubtitles'] == true,
      writeAutoSubtitles: json['writeAutoSubtitles'] == true,
      embedSubtitles: json['embedSubtitles'] == true,
      removeAudio: json['removeAudio'] == true,
      outputContainer: (json['outputContainer'] ?? 'mp4').toString(),
      enableCompatibilityMode: json['enableCompatibilityMode'] == true,
    );
  }
}

class NativeDownloadRequest {
  final String taskId;
  final String url;
  final String outputDir;
  final String outputTemplate;
  final List<String> args;
  final Map<String, dynamic> debugContext;

  const NativeDownloadRequest({
    required this.taskId,
    required this.url,
    required this.outputDir,
    required this.outputTemplate,
    required this.args,
    this.debugContext = const {},
  });

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'url': url,
    'outputDir': outputDir,
    'outputTemplate': outputTemplate,
    'args': args,
    'debugContext': debugContext,
  };

  Map<String, dynamic> toPersistedJson() {
    final safe = <String>[];
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--proxy') {
        i++;
        continue;
      }
      if (args[i].startsWith('--proxy=')) continue;
      safe.add(args[i]);
    }
    return {
      ...toJson(),
      'args': safe,
      'debugContext': _withoutProxyDetails(debugContext),
    };
  }

  static Object? _withoutProxyDetails(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!const {
            'proxy',
            'useProxy',
            'proxyPassword',
            'proxyUsername',
          }.contains(entry.key))
            entry.key: _withoutProxyDetails(entry.value),
      };
    }
    if (value is List) return value.map(_withoutProxyDetails).toList();
    return value;
  }

  factory NativeDownloadRequest.fromJson(Map<String, dynamic> json) {
    return NativeDownloadRequest(
      taskId: (json['taskId'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      outputDir: (json['outputDir'] ?? '').toString(),
      outputTemplate: (json['outputTemplate'] ?? '').toString(),
      args: (json['args'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(),
      debugContext: Map<String, dynamic>.from(
        json['debugContext'] as Map? ?? const {},
      ),
    );
  }
}

class DownloadTaskEvent {
  final bool autoResume;
  final String taskId;
  final int? generation;
  final String type;
  final double? progress;
  final int? downloadedBytes;
  final int? totalBytes;
  final String? speedText;
  final String? etaText;
  final String? outputPath;
  final List<String> producedPaths;
  final String? errorCode;
  final String? message;
  final String? stderrTail;

  const DownloadTaskEvent({
    this.autoResume = false,
    required this.taskId,
    this.generation,
    required this.type,
    this.progress,
    this.downloadedBytes,
    this.totalBytes,
    this.speedText,
    this.etaText,
    this.outputPath,
    this.producedPaths = const [],
    this.errorCode,
    this.message,
    this.stderrTail,
  });

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'generation': generation,
    'autoResume': autoResume,
    'type': type,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'speedText': speedText,
    'etaText': etaText,
    'outputPath': outputPath,
    'producedPaths': producedPaths,
    'errorCode': errorCode,
    'message': message,
    'stderrTail': stderrTail,
  };

  factory DownloadTaskEvent.fromJson(Map<String, dynamic> json) {
    return DownloadTaskEvent(
      taskId: (json['taskId'] ?? '').toString(),
      generation: _toInt(json['generation']),
      autoResume: json['autoResume'] == true,
      type: (json['type'] ?? '').toString(),
      progress: _toDouble(json['progress']),
      downloadedBytes: _toInt(json['downloadedBytes']),
      totalBytes: _toInt(json['totalBytes']),
      speedText: _nullableString(json['speedText']),
      etaText: _nullableString(json['etaText']),
      outputPath: _nullableString(json['outputPath']),
      producedPaths: (json['producedPaths'] as List? ?? const [])
          .map((item) => item.toString())
          .where((item) => item.trim().isNotEmpty)
          .toList(),
      errorCode: _nullableString(json['errorCode']),
      message: _nullableString(json['message']),
      stderrTail: _nullableString(json['stderrTail']),
    );
  }
}

class DownloadFailureContext {
  final String url;
  final String? extractor;
  final String? selectedPlayerClient;
  final bool hasCookies;
  final bool hasProxy;
  final bool hasUserAgent;
  final bool hasVisitorData;
  final bool hasPoToken;
  final int retryCount;
  final String? stderrTail;
  final int? exitCode;

  const DownloadFailureContext({
    required this.url,
    this.extractor,
    this.selectedPlayerClient,
    this.hasCookies = false,
    this.hasProxy = false,
    this.hasUserAgent = false,
    this.hasVisitorData = false,
    this.hasPoToken = false,
    this.retryCount = 0,
    this.stderrTail,
    this.exitCode,
  });

  Map<String, dynamic> toJson() => {
    'url': url,
    'extractor': extractor,
    'selectedPlayerClient': selectedPlayerClient,
    'hasCookies': hasCookies,
    'hasProxy': hasProxy,
    'hasUserAgent': hasUserAgent,
    'hasVisitorData': hasVisitorData,
    'hasPoToken': hasPoToken,
    'retryCount': retryCount,
    'stderrTail': stderrTail,
    'exitCode': exitCode,
  };

  factory DownloadFailureContext.fromJson(Map<String, dynamic> json) {
    return DownloadFailureContext(
      url: (json['url'] ?? '').toString(),
      extractor: _nullableString(json['extractor']),
      selectedPlayerClient: _nullableString(json['selectedPlayerClient']),
      hasCookies: json['hasCookies'] == true,
      hasProxy: json['hasProxy'] == true,
      hasUserAgent: json['hasUserAgent'] == true,
      hasVisitorData: json['hasVisitorData'] == true,
      hasPoToken: json['hasPoToken'] == true,
      retryCount: _toInt(json['retryCount']) ?? 0,
      stderrTail: _nullableString(json['stderrTail']),
      exitCode: _toInt(json['exitCode']),
    );
  }
}

class VideoMeta {
  final String id;
  final String source;
  final String webpageUrl;
  final String title;
  final String uploader;
  final int? durationSeconds;
  final List<ThumbnailInfo> thumbnails;
  final List<VideoFormat> videoFormats;
  final List<AudioFormat> audioFormats;
  final List<SubtitleTrack> subtitles;
  final List<ChapterInfo> chapters;
  final Map<String, List<String>> videoFormatGroups;
  final Map<String, List<String>> audioFormatGroups;
  final String? recommendedVideoFormatId;
  final String? recommendedAudioFormatId;
  final List<String> recommendedSubtitleLanguages;
  final Map<String, dynamic> rawInfo;

  const VideoMeta({
    required this.id,
    required this.source,
    required this.webpageUrl,
    required this.title,
    required this.uploader,
    this.durationSeconds,
    this.thumbnails = const [],
    this.videoFormats = const [],
    this.audioFormats = const [],
    this.subtitles = const [],
    this.chapters = const [],
    this.videoFormatGroups = const {},
    this.audioFormatGroups = const {},
    this.recommendedVideoFormatId,
    this.recommendedAudioFormatId,
    this.recommendedSubtitleLanguages = const [],
    this.rawInfo = const {},
  });

  List<String> get thumbnailCandidateUrls {
    final discovered = <ThumbnailInfo>[
      ...thumbnails,
      ..._thumbnailCandidatesFromRawInfo(rawInfo),
    ];
    if (discovered.isEmpty) return const [];
    final sorted = [...discovered]
      ..sort((a, b) {
        final scoreCompare = _thumbnailCandidateScore(
          b,
        ).compareTo(_thumbnailCandidateScore(a));
        if (scoreCompare != 0) {
          return scoreCompare;
        }
        final widthCompare = (b.width ?? 0).compareTo(a.width ?? 0);
        if (widthCompare != 0) {
          return widthCompare;
        }
        return (b.height ?? 0).compareTo(a.height ?? 0);
      });
    final deduped = <String>[];
    final seen = <String>{};
    for (final item in sorted) {
      final url = _normalizeThumbnailCandidateUrl(
        item.url,
        webpageUrl: webpageUrl,
      );
      if (url.isEmpty || !seen.add(url)) {
        continue;
      }
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
        continue;
      }
      deduped.add(url);
    }
    return deduped;
  }

  String get bestThumbnailUrl =>
      thumbnailCandidateUrls.isEmpty ? '' : thumbnailCandidateUrls.first;

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'webpageUrl': webpageUrl,
    'title': title,
    'uploader': uploader,
    'durationSeconds': durationSeconds,
    'thumbnails': thumbnails.map((item) => item.toJson()).toList(),
    'videoFormats': videoFormats.map((item) => item.toJson()).toList(),
    'audioFormats': audioFormats.map((item) => item.toJson()).toList(),
    'subtitles': subtitles.map((item) => item.toJson()).toList(),
    'chapters': chapters.map((item) => item.toJson()).toList(),
    'videoFormatGroups': videoFormatGroups,
    'audioFormatGroups': audioFormatGroups,
    'recommendedVideoFormatId': recommendedVideoFormatId,
    'recommendedAudioFormatId': recommendedAudioFormatId,
    'recommendedSubtitleLanguages': recommendedSubtitleLanguages,
    'rawInfo': rawInfo,
  };

  factory VideoMeta.fromJson(Map<String, dynamic> json) {
    return VideoMeta(
      id: (json['id'] ?? '').toString(),
      source: (json['source'] ?? '').toString(),
      webpageUrl: (json['webpageUrl'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      uploader: (json['uploader'] ?? '').toString(),
      durationSeconds: _toInt(json['durationSeconds']),
      thumbnails: (json['thumbnails'] as List? ?? const [])
          .map(
            (item) => ThumbnailInfo.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      videoFormats: (json['videoFormats'] as List? ?? const [])
          .map((item) => VideoFormat.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      audioFormats: (json['audioFormats'] as List? ?? const [])
          .map((item) => AudioFormat.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      subtitles: (json['subtitles'] as List? ?? const [])
          .map(
            (item) => SubtitleTrack.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(),
      chapters: (json['chapters'] as List? ?? const [])
          .map((item) => ChapterInfo.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      videoFormatGroups: _stringListMap(json['videoFormatGroups']),
      audioFormatGroups: _stringListMap(json['audioFormatGroups']),
      recommendedVideoFormatId: _nullableString(
        json['recommendedVideoFormatId'],
      ),
      recommendedAudioFormatId: _nullableString(
        json['recommendedAudioFormatId'],
      ),
      recommendedSubtitleLanguages:
          (json['recommendedSubtitleLanguages'] as List? ?? const [])
              .map((item) => item.toString())
              .toList(),
      rawInfo: Map<String, dynamic>.from(json['rawInfo'] as Map? ?? const {}),
    );
  }
}

Object? _browserPersistedValue(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (!const {
          'cookie',
          'cookies',
          'set-cookie',
          'authorization',
          'proxy-authorization',
        }.contains(entry.key.toString().toLowerCase()))
          entry.key: _browserPersistedValue(entry.value),
    };
  }
  if (value is List) return value.map(_browserPersistedValue).toList();
  return value;
}

class BrowserDownloadOptions {
  const BrowserDownloadOptions({
    this.targetFolderId,
    this.sourcePage,
    this.autoImport = true,
  });
  final String? targetFolderId;
  final String? sourcePage;
  final bool autoImport;
  Map<String, dynamic> toJson() => {
    'targetFolderId': targetFolderId,
    'sourcePage': sourcePage,
    'autoImport': autoImport,
    'singleVideo': true,
  };
  factory BrowserDownloadOptions.fromJson(Map<String, dynamic> json) =>
      BrowserDownloadOptions(
        targetFolderId: json['targetFolderId'] as String?,
        sourcePage: json['sourcePage'] as String?,
        autoImport: json['autoImport'] != false,
      );
}

class YtDlpTaskRecord {
  final String taskId;

  /// Last successful card import, retained through retries and redownloads.
  final String? importedVideoId;
  final String sourceUrl;
  final String? customTitle;
  final MediaSourceRef? sourceRef;
  final VideoMeta? meta;
  final DownloadSelection selection;
  final NativeDownloadRequest? request;
  final String? tempArtifactKey;

  /// Downloads are complete; resume only local processing, without yt-dlp.
  final bool pendingLocalPostProcess;

  /// The desktop download finished; resume its integrity check without yt-dlp.
  final bool pendingIntegrityVerification;
  final List<String> producedPaths;
  final String createdAtIso;
  final YtDlpTaskStatus status;
  final bool isSelected;
  final double progress;
  final int? downloadedBytes;
  final int? totalBytes;
  final String? speedText;
  final String? etaText;
  final String? outputPath;
  final String? statusMessage;
  final List<String> stepMessages;
  final String? errorMessage;
  final YtDlpFailureType failureType;
  final int retryCount;
  final int fallbackAttemptCount;
  final List<YtDlpFallbackStep> appliedFallbackSteps;
  final DownloadSessionConfig? executionSessionConfig;
  final DownloadFailureContext? failureContext;
  final String? completedAtIso;
  final String? lastFailedAtIso;
  final String? taskThumbnailPath;
  final BrowserDownloadOptions? browserDownload;
  final ImportPlacementRequest? importPlacement;
  final DownloadImportContext? importContext;

  const YtDlpTaskRecord({
    required this.taskId,
    this.importedVideoId,
    required this.sourceUrl,
    this.customTitle,
    this.sourceRef,
    required this.selection,
    required this.createdAtIso,
    this.meta,
    this.request,
    this.tempArtifactKey,
    this.pendingLocalPostProcess = false,
    this.pendingIntegrityVerification = false,
    this.producedPaths = const [],
    this.status = YtDlpTaskStatus.pending,
    this.isSelected = false,
    this.progress = 0,
    this.downloadedBytes,
    this.totalBytes,
    this.speedText,
    this.etaText,
    this.outputPath,
    this.statusMessage,
    this.stepMessages = const [],
    this.errorMessage,
    this.failureType = YtDlpFailureType.none,
    this.retryCount = 0,
    this.fallbackAttemptCount = 0,
    this.appliedFallbackSteps = const [],
    this.executionSessionConfig,
    this.failureContext,
    this.completedAtIso,
    this.lastFailedAtIso,
    this.taskThumbnailPath,
    this.browserDownload,
    this.importPlacement,
    this.importContext,
  });

  String get title => customTitle ?? meta?.title ?? sourceUrl;
  String get thumbnailUrl => meta?.bestThumbnailUrl ?? '';
  List<String> get thumbnailCandidateUrls => meta?.thumbnailCandidateUrls ?? [];
  String? get localThumbnailPath => taskThumbnailPath;
  bool get canStart =>
      status == YtDlpTaskStatus.pending ||
      status == YtDlpTaskStatus.paused ||
      status == YtDlpTaskStatus.failed ||
      status == YtDlpTaskStatus.cancelled;
  bool get canPause =>
      status == YtDlpTaskStatus.queued ||
      status == YtDlpTaskStatus.downloading ||
      status == YtDlpTaskStatus.postProcessing;
  bool get canCancel =>
      canPause ||
      status == YtDlpTaskStatus.pausing ||
      status == YtDlpTaskStatus.paused;
  bool get canRetry =>
      status == YtDlpTaskStatus.failed || status == YtDlpTaskStatus.cancelled;

  YtDlpTaskRecord copyWith({
    String? importedVideoId,
    String? sourceUrl,
    String? customTitle,
    VideoMeta? meta,
    Object? sourceRef = _unset,
    DownloadSelection? selection,
    Object? request = _unset,
    Object? tempArtifactKey = _unset,
    bool? pendingLocalPostProcess,
    bool? pendingIntegrityVerification,
    List<String>? producedPaths,
    YtDlpTaskStatus? status,
    bool? isSelected,
    double? progress,
    Object? downloadedBytes = _unset,
    Object? totalBytes = _unset,
    Object? speedText = _unset,
    Object? etaText = _unset,
    Object? outputPath = _unset,
    Object? statusMessage = _unset,
    List<String>? stepMessages,
    Object? errorMessage = _unset,
    YtDlpFailureType? failureType,
    int? retryCount,
    int? fallbackAttemptCount,
    List<YtDlpFallbackStep>? appliedFallbackSteps,
    Object? executionSessionConfig = _unset,
    Object? failureContext = _unset,
    Object? completedAtIso = _unset,
    Object? lastFailedAtIso = _unset,
    Object? taskThumbnailPath = _unset,
    BrowserDownloadOptions? browserDownload,
    ImportPlacementRequest? importPlacement,
    DownloadImportContext? importContext,
  }) {
    return YtDlpTaskRecord(
      taskId: taskId,
      importedVideoId: importedVideoId ?? this.importedVideoId,
      browserDownload: browserDownload ?? this.browserDownload,
      importPlacement: importPlacement ?? this.importPlacement,
      importContext: importContext ?? this.importContext,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      customTitle: customTitle ?? this.customTitle,
      sourceRef: identical(sourceRef, _unset)
          ? this.sourceRef
          : sourceRef as MediaSourceRef?,
      meta: meta ?? this.meta,
      selection: selection ?? this.selection,
      request: identical(request, _unset)
          ? this.request
          : request as NativeDownloadRequest?,
      tempArtifactKey: identical(tempArtifactKey, _unset)
          ? this.tempArtifactKey
          : tempArtifactKey as String?,
      pendingLocalPostProcess:
          tempArtifactKey == null && pendingLocalPostProcess != true
          ? false
          : pendingLocalPostProcess ?? this.pendingLocalPostProcess,
      pendingIntegrityVerification:
          pendingIntegrityVerification ?? this.pendingIntegrityVerification,
      producedPaths: producedPaths ?? this.producedPaths,
      createdAtIso: createdAtIso,
      status: status ?? this.status,
      isSelected: isSelected ?? this.isSelected,
      progress: progress ?? this.progress,
      downloadedBytes: identical(downloadedBytes, _unset)
          ? this.downloadedBytes
          : downloadedBytes as int?,
      totalBytes: identical(totalBytes, _unset)
          ? this.totalBytes
          : totalBytes as int?,
      speedText: identical(speedText, _unset)
          ? this.speedText
          : speedText as String?,
      etaText: identical(etaText, _unset) ? this.etaText : etaText as String?,
      outputPath: identical(outputPath, _unset)
          ? this.outputPath
          : outputPath as String?,
      statusMessage: identical(statusMessage, _unset)
          ? this.statusMessage
          : statusMessage as String?,
      stepMessages: stepMessages ?? this.stepMessages,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
      failureType: failureType ?? this.failureType,
      retryCount: retryCount ?? this.retryCount,
      fallbackAttemptCount: fallbackAttemptCount ?? this.fallbackAttemptCount,
      appliedFallbackSteps: appliedFallbackSteps ?? this.appliedFallbackSteps,
      executionSessionConfig: identical(executionSessionConfig, _unset)
          ? this.executionSessionConfig
          : executionSessionConfig as DownloadSessionConfig?,
      failureContext: identical(failureContext, _unset)
          ? this.failureContext
          : failureContext as DownloadFailureContext?,
      completedAtIso: identical(completedAtIso, _unset)
          ? this.completedAtIso
          : completedAtIso as String?,
      lastFailedAtIso: identical(lastFailedAtIso, _unset)
          ? this.lastFailedAtIso
          : lastFailedAtIso as String?,
      taskThumbnailPath: identical(taskThumbnailPath, _unset)
          ? this.taskThumbnailPath
          : taskThumbnailPath as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'importedVideoId': importedVideoId,
    'sourceUrl': sourceUrl,
    'customTitle': customTitle,
    'sourceRef': sourceRef?.toJson(),
    'meta': browserDownload == null
        ? meta?.toJson()
        : _browserPersistedValue(meta?.toJson()),
    'selection': selection.toJson(),
    'request': request?.toPersistedJson(),
    'tempArtifactKey': tempArtifactKey,
    'pendingLocalPostProcess': pendingLocalPostProcess,
    if (pendingIntegrityVerification) 'pendingIntegrityVerification': true,
    'producedPaths': producedPaths,
    'createdAtIso': createdAtIso,
    'status': status.name,
    'isSelected': isSelected,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'speedText': speedText,
    'etaText': etaText,
    'outputPath': outputPath,
    'statusMessage': statusMessage,
    'stepMessages': stepMessages,
    'errorMessage': errorMessage,
    'failureType': failureType.name,
    'retryCount': retryCount,
    'fallbackAttemptCount': fallbackAttemptCount,
    'appliedFallbackSteps': appliedFallbackSteps
        .map((item) => item.name)
        .toList(),
    'executionSessionConfig': browserDownload == null
        ? executionSessionConfig?.toJson()
        : null,
    'failureContext': failureContext?.toJson(),
    'completedAtIso': completedAtIso,
    'lastFailedAtIso': lastFailedAtIso,
    'taskThumbnailPath': taskThumbnailPath,
    'browserDownload': browserDownload?.toJson(),
    'importPlacement': importPlacement?.toJson(),
    'importContext': importContext?.toJson(),
  };

  factory YtDlpTaskRecord.fromJson(Map<String, dynamic> json) {
    return YtDlpTaskRecord(
      taskId: (json['taskId'] ?? '').toString(),
      importedVideoId: _nullableString(json['importedVideoId']),
      importPlacement: ImportPlacementRequest.fromJson(json['importPlacement']),
      importContext: DownloadImportContext.fromJson(json['importContext']),
      browserDownload: json['browserDownload'] is Map
          ? BrowserDownloadOptions.fromJson(
              Map<String, dynamic>.from(json['browserDownload']),
            )
          : null,

      sourceUrl: (json['sourceUrl'] ?? '').toString(),
      customTitle: _nullableString(json['customTitle']),
      sourceRef: MediaSourceRef.fromJsonOrNull(json['sourceRef']),
      meta: json['meta'] is Map<String, dynamic>
          ? VideoMeta.fromJson(Map<String, dynamic>.from(json['meta']))
          : null,
      selection: DownloadSelection.fromJson(
        Map<String, dynamic>.from(json['selection'] as Map? ?? const {}),
      ),
      request: json['request'] is Map<String, dynamic>
          ? NativeDownloadRequest.fromJson(
              Map<String, dynamic>.from(json['request']),
            )
          : null,
      tempArtifactKey: _nullableString(json['tempArtifactKey']),
      pendingLocalPostProcess: json['pendingLocalPostProcess'] == true,
      pendingIntegrityVerification:
          json['pendingIntegrityVerification'] == true,
      producedPaths: (json['producedPaths'] as List? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(),
      createdAtIso: (json['createdAtIso'] ?? DateTime.now().toIso8601String())
          .toString(),
      status: _taskStatusFromName(json['status']?.toString()),
      isSelected: json['isSelected'] == true,
      progress: _toDouble(json['progress']) ?? 0,
      downloadedBytes: _toInt(json['downloadedBytes']),
      totalBytes: _toInt(json['totalBytes']),
      speedText: _nullableString(json['speedText']),
      etaText: _nullableString(json['etaText']),
      outputPath: _nullableString(json['outputPath']),
      statusMessage: _nullableString(json['statusMessage']),
      stepMessages: (json['stepMessages'] as List? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(),
      errorMessage: _nullableString(json['errorMessage']),
      failureType: _failureTypeFromName(json['failureType']?.toString()),
      retryCount: _toInt(json['retryCount']) ?? 0,
      fallbackAttemptCount: _toInt(json['fallbackAttemptCount']) ?? 0,
      appliedFallbackSteps: (json['appliedFallbackSteps'] as List? ?? const [])
          .map((item) => _fallbackStepFromName(item?.toString()))
          .whereType<YtDlpFallbackStep>()
          .toList(),
      executionSessionConfig:
          json['executionSessionConfig'] is Map<String, dynamic>
          ? DownloadSessionConfig.fromJson(
              Map<String, dynamic>.from(json['executionSessionConfig']),
            )
          : null,
      failureContext: json['failureContext'] is Map<String, dynamic>
          ? DownloadFailureContext.fromJson(
              Map<String, dynamic>.from(json['failureContext']),
            )
          : null,
      completedAtIso: _nullableString(json['completedAtIso']),
      lastFailedAtIso: _nullableString(json['lastFailedAtIso']),
      taskThumbnailPath: _nullableString(json['taskThumbnailPath']),
    );
  }

  static YtDlpTaskRecord fromMeta({
    required String taskId,
    required String sourceUrl,
    MediaSourceRef? sourceRef,
    required VideoMeta meta,
    required DownloadSelection selection,
    String? taskThumbnailPath,
  }) {
    return YtDlpTaskRecord(
      taskId: taskId,
      sourceUrl: sourceUrl,
      sourceRef: sourceRef,
      meta: meta,
      selection: selection,
      createdAtIso: DateTime.now().toIso8601String(),
      taskThumbnailPath: taskThumbnailPath,
    );
  }
}

int _thumbnailCandidateScore(ThumbnailInfo item) {
  final url = _normalizeThumbnailCandidateUrl(item.url).toLowerCase();
  if (url.isEmpty) {
    return -1000;
  }
  var score = 0;
  final uri = Uri.tryParse(url);
  if (uri != null && (uri.isScheme('http') || uri.isScheme('https'))) {
    score += 100;
  }
  final ext = _thumbnailExtensionFromPath(uri?.path ?? url);
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      score += 40;
    case 'png':
      score += 35;
    case 'webp':
      score += 25;
    default:
      score += 10;
  }
  final id = item.id?.trim().toLowerCase() ?? '';
  if (id.contains('maxres')) {
    score -= 60;
  } else if (id.contains('sddefault')) {
    score += 35;
  } else if (id.contains('hqdefault')) {
    score += 30;
  } else if (id.contains('mqdefault')) {
    score += 20;
  } else if (id.contains('default')) {
    score += 10;
  }
  final width = item.width ?? 0;
  if (width > 0) {
    score += (width / 64).round().clamp(0, 40);
    if (width >= 1920) {
      score -= 10;
    }
  }
  return score;
}

String _thumbnailExtensionFromPath(String path) {
  final lower = path.toLowerCase();
  for (final ext in const ['.jpg', '.jpeg', '.png', '.webp']) {
    if (lower.endsWith(ext)) {
      return ext.substring(1);
    }
  }
  return '';
}

List<ThumbnailInfo> _thumbnailCandidatesFromRawInfo(
  Map<String, dynamic> rawInfo,
) {
  final candidates = <ThumbnailInfo>[];
  final thumbnail = rawInfo['thumbnail']?.toString().trim();
  if (thumbnail != null && thumbnail.isNotEmpty) {
    candidates.add(ThumbnailInfo(url: thumbnail));
  }
  final thumbnailUrl = rawInfo['thumbnail_url']?.toString().trim();
  if (thumbnailUrl != null && thumbnailUrl.isNotEmpty) {
    candidates.add(ThumbnailInfo(url: thumbnailUrl));
  }
  return candidates;
}

String _normalizeThumbnailCandidateUrl(String? url, {String? webpageUrl}) {
  final trimmed = url?.trim() ?? '';
  if (trimmed.isEmpty) {
    return '';
  }
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('//')) {
    return 'https:$trimmed';
  }
  if (trimmed.startsWith('/')) {
    final baseUri = Uri.tryParse((webpageUrl ?? '').trim());
    if (baseUri != null &&
        (baseUri.scheme == 'http' || baseUri.scheme == 'https') &&
        baseUri.host.isNotEmpty) {
      return '${baseUri.scheme}://${baseUri.host}$trimmed';
    }
    return '';
  }
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.hasScheme) {
    return trimmed;
  }
  final looksLikeHostPath =
      !trimmed.startsWith('.') &&
      !trimmed.startsWith('data:') &&
      RegExp(r'^[^/\s]+\.[^/\s]+/').hasMatch(trimmed);
  if (looksLikeHostPath) {
    return 'https://$trimmed';
  }
  return '';
}

String encodeTaskList(List<YtDlpTaskRecord> tasks) {
  return jsonEncode(tasks.map((item) => item.toJson()).toList());
}

List<YtDlpTaskRecord> decodeTaskList(String raw) {
  final decoded = jsonDecode(raw) as List<dynamic>;
  return decoded
      .map((item) => YtDlpTaskRecord.fromJson(Map<String, dynamic>.from(item)))
      .toList();
}

YtDlpTaskStatus _taskStatusFromName(String? name) {
  return YtDlpTaskStatus.values.firstWhere(
    (item) => item.name == name,
    orElse: () => YtDlpTaskStatus.pending,
  );
}

YtDlpFailureType _failureTypeFromName(String? name) {
  return YtDlpFailureType.values.firstWhere(
    (item) => item.name == name,
    orElse: () => YtDlpFailureType.unknown,
  );
}

YtDlpFallbackStep? _fallbackStepFromName(String? name) {
  if (name == null || name.isEmpty) {
    return null;
  }
  for (final step in YtDlpFallbackStep.values) {
    if (step.name == name) {
      return step;
    }
  }
  return null;
}

int? _toInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.round();
  return int.tryParse(value.toString());
}

double? _toDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  return double.tryParse(value.toString());
}

Map<String, List<String>> _stringListMap(Object? value) {
  if (value is! Map) {
    return const {};
  }
  return value.map(
    (key, rawList) => MapEntry(
      key.toString(),
      (rawList as List? ?? const []).map((item) => item.toString()).toList(),
    ),
  );
}

String? _nullableString(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}
