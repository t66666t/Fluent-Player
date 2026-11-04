import 'media_source_ref.dart';
import 'package:path/path.dart' as p;
import 'bilibili_video_shot.dart';
import 'bilibili_pending_card_data.dart';
import 'managed_subtitle_asset.dart';
import 'media_chapter.dart';

enum MediaType { video, audio }

class VideoItem {
  final String id;
  String path;
  String? playbackPath;
  /// Provenance of a download promoted to a Bilibili source card. The cache
  /// registry owns this file; sync uses the locator to retain its old identity.
  String? bilibiliDownloadPath;
  String title;
  String? thumbnailPath;
  int durationMs;
  int lastPositionMs;
  String? subtitlePath;
  bool isSubtitleCached;
  String? secondarySubtitlePath;
  String? danmakuPath;
  bool isSecondarySubtitleCached;
  int lastUpdated;
  String? parentId;
  bool isRecycled;
  int? recycleTime;
  Map<String, String>? additionalSubtitles;
  Map<String, String>? localSubtitles;
  List<ManagedSubtitleAsset> managedSubtitleAssets;
  String? codec;
  MediaType type;
  bool showFloatingSubtitles;
  List<String>? recycledSelectedSubtitlePaths;
  Map<String, String>? recycledAdditionalSubtitles;
  Map<String, String>? recycledLocalSubtitles;
  bool isBilibiliExported;
  bool usesManagedAssociatedSubtitles;
  bool blockAutoAssociatedSubtitleSelection;
  bool hasAttemptedAutoEmbeddedSubtitleLoad;
  double? portraitDisplayAspectRatio;
  double? portraitCustomAspectWidth;
  double? portraitCustomAspectHeight;
  bool hasPortraitAspectPreferenceInitialized;
  bool isVideoMirroredH;
  bool isVideoMirroredV;
  String? sourceFingerprint;
  MediaSourceRef? sourceRef;
  BilibiliVideoShot? bilibiliVideoShot;
  BilibiliPendingCardData? bilibiliPendingCardData;
  List<MediaChapter> chapters;
  bool hasProbedChapters;

  /// True after an audio import tried to read embedded or sibling cover art.
  /// Stops startup from scanning the same cover-less files on every launch.
  bool hasProbedAudioCover;

  /// A watch-only card: playable like any other card, but never part of the
  /// media library (no folder, no lists, not saved). It is removed with its
  /// cache once nothing plays it any more. Importing it clears the flag
  /// ([LibraryService.promoteTransientVideo]).
  bool isTransient;

  VideoItem({
    required this.id,
    required this.path,
    this.playbackPath,
    this.bilibiliDownloadPath,
    required this.title,
    this.thumbnailPath,
    required this.durationMs,
    this.lastPositionMs = 0,
    this.subtitlePath,
    this.isSubtitleCached = false,
    this.secondarySubtitlePath,
    this.danmakuPath,
    this.isSecondarySubtitleCached = false,
    required this.lastUpdated,
    this.parentId,
    this.isRecycled = false,
    this.recycleTime,
    this.additionalSubtitles,
    this.localSubtitles,
    this.managedSubtitleAssets = const <ManagedSubtitleAsset>[],
    this.codec,
    this.type = MediaType.video,
    this.showFloatingSubtitles = true,
    this.recycledSelectedSubtitlePaths,
    this.recycledAdditionalSubtitles,
    this.recycledLocalSubtitles,
    this.isBilibiliExported = false,
    this.usesManagedAssociatedSubtitles = false,
    this.blockAutoAssociatedSubtitleSelection = false,
    this.hasAttemptedAutoEmbeddedSubtitleLoad = false,
    this.portraitDisplayAspectRatio,
    this.portraitCustomAspectWidth,
    this.portraitCustomAspectHeight,
    this.hasPortraitAspectPreferenceInitialized = false,
    this.isVideoMirroredH = false,
    this.isVideoMirroredV = false,
    this.sourceFingerprint,
    this.sourceRef,
    this.bilibiliVideoShot,
    this.bilibiliPendingCardData,
    this.chapters = const <MediaChapter>[],
    this.hasProbedChapters = false,
    this.hasProbedAudioCover = false,
    this.isTransient = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'path': path,
      'playbackPath': playbackPath,
      'bilibiliDownloadPath': bilibiliDownloadPath,
      'title': title,
      'thumbnailPath': thumbnailPath,
      'durationMs': durationMs,
      'lastPositionMs': lastPositionMs,
      'subtitlePath': subtitlePath,
      'isSubtitleCached': isSubtitleCached,
      'secondarySubtitlePath': secondarySubtitlePath,
      'danmakuPath': danmakuPath,
      'isSecondarySubtitleCached': isSecondarySubtitleCached,
      'lastUpdated': lastUpdated,
      'parentId': parentId,
      'isRecycled': isRecycled,
      'recycleTime': recycleTime,
      // Legacy key kept for backward compatibility. Its meaning is now limited
      // to subtitles created and bound by a media download task.
      'extraSubtitles': additionalSubtitles,
      'localSubtitles': localSubtitles,
      'managedSubtitleAssets': managedSubtitleAssets
          .map((asset) => asset.toJson())
          .toList(),
      'codec': codec,
      'type': type.name,
      'showFloatingSubtitles': showFloatingSubtitles,
      'recycledSelectedSubtitlePaths': recycledSelectedSubtitlePaths,
      'recycledExtraSubtitles': recycledAdditionalSubtitles,
      'recycledLocalSubtitles': recycledLocalSubtitles,
      'isBilibiliExported': isBilibiliExported,
      'usesManagedAssociatedSubtitles': usesManagedAssociatedSubtitles,
      'blockAutoAssociatedSubtitleSelection':
          blockAutoAssociatedSubtitleSelection,
      'hasAttemptedAutoEmbeddedSubtitleLoad':
          hasAttemptedAutoEmbeddedSubtitleLoad,
      'portraitDisplayAspectRatio': portraitDisplayAspectRatio,
      'portraitCustomAspectWidth': portraitCustomAspectWidth,
      'portraitCustomAspectHeight': portraitCustomAspectHeight,
      'hasPortraitAspectPreferenceInitialized':
          hasPortraitAspectPreferenceInitialized,
      'isVideoMirroredH': isVideoMirroredH,
      'isVideoMirroredV': isVideoMirroredV,
      'sourceFingerprint': sourceFingerprint,
      'sourceRef': sourceRef?.toJson(),
      'bilibiliVideoShot': bilibiliVideoShot?.toJson(),
      if (bilibiliPendingCardData != null)
        'bilibiliPendingCardData': bilibiliPendingCardData!.toJson(),
      'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
      'hasProbedChapters': hasProbedChapters,
      'hasProbedAudioCover': hasProbedAudioCover,
      'isTransient': isTransient,
    };
  }

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    final additionalSubtitles =
        (json['extraSubtitles'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, value as String),
        );
    final isBilibiliExported = json['isBilibiliExported'] as bool? ?? false;
    // Older Bilibili records predate usesManagedAssociatedSubtitles. Their
    // extraSubtitles were produced by the download task, so migrate that fact.
    final storedManagedAssociation =
        json['usesManagedAssociatedSubtitles'] as bool? ?? false;
    final usesManagedAssociatedSubtitles =
        storedManagedAssociation ||
        (isBilibiliExported && additionalSubtitles?.isNotEmpty == true);
    return VideoItem(
      id: json['id'] as String,
      path: json['path'] as String,
      playbackPath: _normalizeLocalFilePath(json['playbackPath'] as String?),
      bilibiliDownloadPath: _normalizeLocalFilePath(json['bilibiliDownloadPath'] as String?),
      title: json['title'] as String,
      thumbnailPath: _normalizeLocalFilePath(json['thumbnailPath'] as String?),
      durationMs: json['durationMs'] as int? ?? 0,
      lastPositionMs: json['lastPositionMs'] as int? ?? 0,
      subtitlePath: json['subtitlePath'] as String?,
      isSubtitleCached: json['isSubtitleCached'] as bool? ?? false,
      secondarySubtitlePath: json['secondarySubtitlePath'] as String?,
      danmakuPath: _normalizeLocalFilePath(json['danmakuPath'] as String?),
      isSecondarySubtitleCached:
          json['isSecondarySubtitleCached'] as bool? ?? false,
      lastUpdated:
          json['lastUpdated'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      parentId: json['parentId'] as String?,
      isRecycled: json['isRecycled'] as bool? ?? false,
      recycleTime: json['recycleTime'] as int?,
      additionalSubtitles: additionalSubtitles,
      localSubtitles: (json['localSubtitles'] as Map<String, dynamic>?)?.map(
        (key, value) => MapEntry(key, value as String),
      ),
      managedSubtitleAssets:
          (json['managedSubtitleAssets'] as List<dynamic>?)
              ?.whereType<Map<String, dynamic>>()
              .map(ManagedSubtitleAsset.fromJson)
              .where(
                (asset) => asset.assetId.isNotEmpty && asset.path.isNotEmpty,
              )
              .toList() ??
          const <ManagedSubtitleAsset>[],
      codec: json['codec'] as String?,
      type: json['type'] != null
          ? MediaType.values.firstWhere(
              (e) => e.name == json['type'],
              orElse: () => MediaType.video,
            )
          : MediaType.video,
      showFloatingSubtitles: json['showFloatingSubtitles'] as bool? ?? true,
      recycledSelectedSubtitlePaths:
          (json['recycledSelectedSubtitlePaths'] as List?)
              ?.map((e) => e.toString())
              .toList(),
      recycledAdditionalSubtitles:
          (json['recycledExtraSubtitles'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v as String),
          ),
      recycledLocalSubtitles:
          (json['recycledLocalSubtitles'] as Map<String, dynamic>?)?.map(
            (key, value) => MapEntry(key, value as String),
          ),
      isBilibiliExported: isBilibiliExported,
      usesManagedAssociatedSubtitles: usesManagedAssociatedSubtitles,
      blockAutoAssociatedSubtitleSelection:
          json['blockAutoAssociatedSubtitleSelection'] as bool? ?? false,
      hasAttemptedAutoEmbeddedSubtitleLoad:
          json['hasAttemptedAutoEmbeddedSubtitleLoad'] as bool? ?? false,
      portraitDisplayAspectRatio: (json['portraitDisplayAspectRatio'] as num?)
          ?.toDouble(),
      portraitCustomAspectWidth: (json['portraitCustomAspectWidth'] as num?)
          ?.toDouble(),
      portraitCustomAspectHeight: (json['portraitCustomAspectHeight'] as num?)
          ?.toDouble(),
      hasPortraitAspectPreferenceInitialized:
          json['hasPortraitAspectPreferenceInitialized'] as bool? ?? false,
      isVideoMirroredH: json['isVideoMirroredH'] as bool? ?? false,
      isVideoMirroredV: json['isVideoMirroredV'] as bool? ?? false,
      sourceFingerprint: json['sourceFingerprint'] as String?,
      sourceRef: MediaSourceRef.fromJsonOrNull(json['sourceRef']),
      bilibiliVideoShot: BilibiliVideoShot.fromJsonOrNull(
        json['bilibiliVideoShot'],
      ),
      bilibiliPendingCardData: BilibiliPendingCardData.fromJsonOrNull(
        json['bilibiliPendingCardData'],
      ),
      chapters: MediaChapter.normalize(
        (json['chapters'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map>()
            .map(
              (chapter) =>
                  MediaChapter.fromJson(Map<String, dynamic>.from(chapter)),
            ),
        durationMs: json['durationMs'] as int? ?? 0,
      ),
      hasProbedChapters:
          json['hasProbedChapters'] as bool? ??
          ((json['chapters'] as List<dynamic>?)?.isNotEmpty ?? false),
      hasProbedAudioCover: json['hasProbedAudioCover'] as bool? ?? false,
      isTransient: json['isTransient'] as bool? ?? false,
    );
  }

  /// Subtitles downloaded and bound by Bilibili/yt-dlp import flows.
  Map<String, String> get downloadAssociatedSubtitles {
    if (!usesManagedAssociatedSubtitles || additionalSubtitles == null) {
      return const <String, String>{};
    }
    return Map<String, String>.fromEntries(
      additionalSubtitles!.entries.where(
        (entry) => !_isClearlyLocalLegacySubtitle(entry.value),
      ),
    );
  }

  /// Locally created/managed subtitle groups. For old non-download records,
  /// extraSubtitles was historically used for this purpose, so expose it as a
  /// local group without ever treating it as a download association.
  Map<String, String> get localSubtitleGroups {
    final groups = <String, String>{};
    if (additionalSubtitles != null) {
      if (!usesManagedAssociatedSubtitles) {
        groups.addAll(additionalSubtitles!);
      } else {
        groups.addEntries(
          additionalSubtitles!.entries.where(
            (entry) => _isClearlyLocalLegacySubtitle(entry.value),
          ),
        );
      }
    }
    if (localSubtitles != null) {
      groups.addAll(localSubtitles!);
    }
    return groups;
  }

  bool get prefersManagedAssociatedSubtitles =>
      downloadAssociatedSubtitles.isNotEmpty;

  static bool _isClearlyLocalLegacySubtitle(String path) {
    final name = p.basename(path).toLowerCase();
    return name.contains('.stream_') ||
        name.contains('.manual.') ||
        name.contains('.ai.') ||
        name.contains('.ocr.');
  }
}

String? _normalizeLocalFilePath(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.startsWith('file://')) {
    try {
      return Uri.parse(trimmed).toFilePath();
    } catch (_) {
      return trimmed.replaceFirst(RegExp(r'^file:/+'), '');
    }
  }
  return trimmed;
}
