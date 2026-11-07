import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../models/managed_subtitle_asset.dart';
import '../../models/media_chapter.dart';
import '../../models/media_source_ref.dart';
import '../../models/podcast_source_ref.dart';
import '../podcasts/podcast_models.dart';
import '../podcasts/podcast_feed_parser.dart';
import '../../models/video_collection.dart';
import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../../services/community_media_input.dart';
import '../media_cache/media_cache_models.dart';
import 'legacy_download_export_policy.dart';
import 'portable_media_selection.dart';

const _windowsReservedNames = <String>{
  'con',
  'prn',
  'aux',
  'nul',
  'com1',
  'com2',
  'com3',
  'com4',
  'com5',
  'com6',
  'com7',
  'com8',
  'com9',
  'lpt1',
  'lpt2',
  'lpt3',
  'lpt4',
  'lpt5',
  'lpt6',
  'lpt7',
  'lpt8',
  'lpt9',
};

const _mp4Family = <String>{'.mp4', '.m4v', '.mov', '.m4a'};
const _mkvFamily = <String>{'.mkv', '.mka'};
const _audioKeepFamily = <String>{'.mp3', '.flac', '.aac', '.ogg', '.opus'};

/// Header facts read from a media file before deciding whether to remux.
class ZipSourceFacts {
  final bool hasAttachedCover;
  final int videoStreamCount;
  final int subtitleStreamCount;
  final List<String> subtitleCodecs;

  /// Null means the file could not be read, so chapters must be left alone.
  final List<MediaChapter>? fileChapters;

  const ZipSourceFacts({
    this.hasAttachedCover = false,
    this.videoStreamCount = 1,
    this.subtitleStreamCount = 0,
    this.subtitleCodecs = const [],
    this.fileChapters = const <MediaChapter>[],
  });

  const ZipSourceFacts.unknown()
    : hasAttachedCover = true,
      videoStreamCount = 1,
      subtitleStreamCount = 0,
      subtitleCodecs = const [],
      fileChapters = null;
}

class ZipSubtitleTrack {
  final String path;
  final String title;
  final String? language;
  final bool isDefault;
  final bool isDanmaku;

  const ZipSubtitleTrack({
    required this.path,
    required this.title,
    required this.language,
    required this.isDefault,
    required this.isDanmaku,
  });

  String get extension {
    final ext = p.extension(path);
    if (ext.isNotEmpty) return ext;
    return isDanmaku ? '.ass' : '.srt';
  }

  ZipSubtitleTrack copyWith({bool? isDefault}) => ZipSubtitleTrack(
    path: path,
    title: title,
    language: language,
    isDefault: isDefault ?? this.isDefault,
    isDanmaku: isDanmaku,
  );
}

class ZipSidecarPlan {
  final String sourcePath;
  final String archivePath;

  const ZipSidecarPlan({required this.sourcePath, required this.archivePath});
}

const zipPodcastReferencesPath = 'fluent-podcast-references.json';

/// A small generated archive entry. Podcast references never read local media.
class ZipReferenceEntry {
  final String archivePath;
  final String contents;

  const ZipReferenceEntry({required this.archivePath, required this.contents});
}

class ZipCandidate {
  final VideoItem item;
  final String parentDirectory;
  final CacheVariant? cachedVariant;
  String get sourcePath =>
      communityLocalMediaPath(cachedVariant?.path ?? item.path);

  const ZipCandidate({
    required this.item,
    required this.parentDirectory,
    this.cachedVariant,
  });
}

class ZipResolvedMedia {
  final String title;
  final String sourcePath;
  final int sourceBytes;
  final int durationMs;
  final String directory;
  final String stem;
  final String archivePath;
  final bool remux;
  final List<ZipSubtitleTrack> embedTracks;
  final String? coverPath;
  final List<MediaChapter>? replacementChapters;
  final List<ZipSidecarPlan> sidecars;
  final List<ZipSubtitleTrack> fallbackTracks;
  final int existingSubtitleStreams;
  final List<String> existingSubtitleCodecs;
  final int existingVideoStreams;
  final int missingSidecars;

  const ZipResolvedMedia({
    required this.title,
    required this.sourcePath,
    required this.sourceBytes,
    required this.durationMs,
    required this.directory,
    required this.stem,
    required this.archivePath,
    required this.remux,
    required this.embedTracks,
    required this.coverPath,
    required this.replacementChapters,
    required this.sidecars,
    required this.fallbackTracks,
    required this.existingSubtitleStreams,
    this.existingSubtitleCodecs = const [],
    required this.existingVideoStreams,
    this.missingSidecars = 0,
  });

  bool get outputIsMp4Family =>
      _mp4Family.contains(p.extension(archivePath).toLowerCase());
}

class ZipExportLayout {
  final List<ZipResolvedMedia> media;
  final List<ZipReferenceEntry> references;
  final int skippedOnline;
  final int skippedMissing;
  final ZipNameAllocator names;

  const ZipExportLayout({
    required this.media,
    this.references = const [],
    required this.skippedOnline,
    required this.skippedMissing,
    required this.names,
  });

  bool get isEmpty => media.isEmpty && references.isEmpty;
}

class ZipRemuxPlan {
  final List<ZipSubtitleTrack> tracks;
  final bool includeCover;
  final bool includeChapters;

  const ZipRemuxPlan({
    required this.tracks,
    required this.includeCover,
    required this.includeChapters,
  });

  bool get hasSoftPayload => tracks.isNotEmpty;
  bool get hasExtras => includeCover || includeChapters;

  ZipRemuxPlan withoutExtras() =>
      ZipRemuxPlan(tracks: tracks, includeCover: false, includeChapters: false);
}

class ZipNameAllocator {
  final Set<String> _used = <String>{};

  String allocate(String parent, String fileName) {
    final normalizedParent = parent.replaceAll('\\', '/');
    var candidate = normalizedParent.isEmpty
        ? fileName
        : '$normalizedParent/$fileName';
    var index = 2;
    while (!_used.add(candidate.toLowerCase())) {
      final ext = p.posix.extension(fileName);
      final stem = fileName.substring(0, fileName.length - ext.length);
      final next = '$stem ($index)$ext';
      candidate = normalizedParent.isEmpty ? next : '$normalizedParent/$next';
      index++;
    }
    return candidate;
  }

  void release(String path) {
    _used.remove(path.replaceAll('\\', '/').toLowerCase());
  }
}

String sanitizeZipName(String input) {
  var cleaned = input
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned.length > 80) {
    cleaned = cleaned.substring(0, 80).replaceAll(RegExp(r'[. ]+$'), '');
  }
  if (_windowsReservedNames.contains(cleaned.toLowerCase())) {
    cleaned = '_$cleaned';
  }
  return cleaned.isEmpty ? '未命名' : cleaned;
}

bool zipItemIsOnline(VideoItem item) => !communityMediaIsLocal(item.path);

bool zipChaptersMatch(
  List<MediaChapter> appChapters,
  List<MediaChapter> fileChapters,
) {
  if (appChapters.isEmpty || appChapters.length != fileChapters.length) {
    return false;
  }
  for (var index = 0; index < appChapters.length; index++) {
    final appChapter = appChapters[index];
    final fileChapter = fileChapters[index];
    if (appChapter.title.trim() != fileChapter.title.trim()) return false;
    if ((appChapter.startMs - fileChapter.startMs).abs() > 1000) return false;
  }
  return true;
}

String escapeZipFfmeta(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('=', r'\=')
    .replaceAll(';', r'\;')
    .replaceAll('#', r'\#')
    .replaceAll('\r', '')
    .replaceAll('\n', r'\n');

String buildZipChapterMetadata(
  List<MediaChapter> chapters, {
  required int durationMs,
}) {
  final buffer = StringBuffer(';FFMETADATA1\n');
  for (final chapter in chapters) {
    var end = chapter.endMs;
    if (end <= chapter.startMs) {
      end = durationMs > chapter.startMs ? durationMs : chapter.startMs + 1;
    }
    buffer
      ..writeln('[CHAPTER]')
      ..writeln('TIMEBASE=1/1000')
      ..writeln('START=${chapter.startMs}')
      ..writeln('END=$end')
      ..writeln('title=${escapeZipFfmeta(chapter.title)}');
  }
  return buffer.toString();
}

/// [failures] is how many attempts have already failed.
ZipRemuxPlan? zipRemuxAttemptAfterFailures(ZipRemuxPlan full, int failures) {
  if (failures <= 1) return full;
  if (failures == 2 && full.hasExtras && full.hasSoftPayload) {
    return full.withoutExtras();
  }
  return null;
}

double? zipFfmpegProgressFraction(String line, int durationMs) {
  if (durationMs <= 0) return null;
  final separator = line.indexOf('=');
  if (separator <= 0) return null;
  final key = line.substring(0, separator).trim();
  final value = int.tryParse(line.substring(separator + 1).trim());
  if (value == null || value < 0) return null;
  final int timeMs;
  if (key == 'out_time_us') {
    timeMs = value ~/ 1000;
  } else if (key == 'out_time_ms') {
    timeMs = value > durationMs * 5 ? value ~/ 1000 : value;
  } else {
    return null;
  }
  return (timeMs / durationMs).clamp(0.0, 0.99);
}

String formatZipBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String buildZipExportSummary({
  required int mediaCount,
  required int outputBytes,
  required int skippedOnline,
  required int skippedMissing,
  required int sidecarFallbacks,
  required int keptOriginals,
  required int droppedExtras,
  int referenceCount = 0,
  int missingSidecars = 0,
}) {
  final parts = <String>['$mediaCount 个媒体', formatZipBytes(outputBytes)];
  if (referenceCount > 0) parts.add('$referenceCount 个播客卡片引用');
  if (skippedOnline > 0) parts.add('已跳过 $skippedOnline 个不支持的条目');
  if (skippedMissing > 0) parts.add('已跳过 $skippedMissing 个缺失文件');
  if (missingSidecars > 0) parts.add('$missingSidecars 个字幕或弹幕文件缺失，未打包');
  if (sidecarFallbacks > 0) parts.add('$sidecarFallbacks 个改为外挂字幕');
  if (droppedExtras > 0) parts.add('$droppedExtras 个未写入封面或章节');
  if (keptOriginals > 0) parts.add('$keptOriginals 个保留原文件');
  return parts.join(' · ');
}

int countMissingZipSidecars(
  VideoItem item, {
  required bool includeSubtitles,
  required bool includeDanmaku,
}) {
  final paths = <String, String>{};
  final embeddedPaths = {
    for (final asset in item.managedSubtitleAssets)
      if (asset.kind == ManagedSubtitleAssetKind.embedded &&
          asset.path.trim().isNotEmpty)
        _normalizePath(asset.path),
  };
  void add(String? rawPath, {bool isDanmaku = false}) {
    final path = rawPath?.trim() ?? '';
    if (path.isEmpty) return;
    final key = _normalizePath(path);
    // Extracted copies of streams already in the source container are optional.
    if (!isDanmaku && embeddedPaths.contains(key)) return;
    paths[key] = path;
  }

  if (includeSubtitles) {
    add(item.subtitlePath);
    add(item.secondarySubtitlePath);
    for (final path in item.additionalSubtitles?.values ?? const <String>[]) {
      add(path);
    }
    for (final path in item.localSubtitles?.values ?? const <String>[]) {
      add(path);
    }
    for (final asset in item.managedSubtitleAssets) {
      if (asset.kind != ManagedSubtitleAssetKind.embedded) add(asset.path);
    }
  }
  if (includeDanmaku) add(item.danmakuPath, isDanmaku: true);
  return paths.values.where((path) => !File(path).existsSync()).length;
}

List<ZipSubtitleTrack> collectAssociatedSubtitles(VideoItem item) {
  final managedByPath = <String, ManagedSubtitleAsset>{};
  final embeddedPaths = <String>{};
  for (final asset in item.managedSubtitleAssets) {
    final key = _normalizePath(asset.path);
    if (key.isEmpty) continue;
    managedByPath[key] = asset;
    if (asset.kind == ManagedSubtitleAssetKind.embedded) {
      embeddedPaths.add(key);
    }
  }

  final tracks = <ZipSubtitleTrack>[];
  final seen = <String>{};

  void add(String? rawPath, String fallbackTitle) {
    final path = rawPath?.trim() ?? '';
    if (path.isEmpty) return;
    final key = _normalizePath(path);
    if (!seen.add(key) || embeddedPaths.contains(key)) return;
    if (!File(path).existsSync()) return;
    final asset = managedByPath[key];
    final displayName = asset?.displayName.trim() ?? '';
    tracks.add(
      ZipSubtitleTrack(
        path: path,
        title: displayName.isEmpty ? fallbackTitle : displayName,
        language: asset?.language,
        isDefault: false,
        isDanmaku: false,
      ),
    );
  }

  add(item.subtitlePath, '主字幕');
  add(item.secondarySubtitlePath, '副字幕');
  item.additionalSubtitles?.forEach(
    (label, path) => add(path, label.trim().isEmpty ? '字幕' : label.trim()),
  );
  item.localSubtitles?.forEach(
    (label, path) => add(path, label.trim().isEmpty ? '字幕' : label.trim()),
  );
  for (final asset in item.managedSubtitleAssets) {
    if (asset.kind == ManagedSubtitleAssetKind.embedded) continue;
    add(
      asset.path,
      asset.displayName.trim().isEmpty ? '字幕' : asset.displayName,
    );
  }
  return <ZipSubtitleTrack>[
    for (var index = 0; index < tracks.length; index++)
      tracks[index].copyWith(isDefault: index == 0),
  ];
}

ZipSubtitleTrack? collectDanmakuTrack(VideoItem item) {
  final path = item.danmakuPath?.trim() ?? '';
  if (path.isEmpty || !File(path).existsSync()) return null;
  return ZipSubtitleTrack(
    path: path,
    title: '弹幕',
    language: null,
    isDefault: false,
    isDanmaku: true,
  );
}

List<ZipSubtitleTrack> zipEmbedTracks({
  required List<ZipSubtitleTrack> associated,
  required ZipSubtitleTrack? danmaku,
  required bool embedSubtitles,
  required bool externalSubtitles,
  required bool includeDanmaku,
}) {
  final tracks = <ZipSubtitleTrack>[];
  if (embedSubtitles) tracks.addAll(associated);
  if (includeDanmaku &&
      danmaku != null &&
      (embedSubtitles || !externalSubtitles)) {
    tracks.add(danmaku);
  }
  return tracks;
}

String chooseZipOutputExtension({
  required String sourcePath,
  required List<ZipSubtitleTrack> embedded,
  required bool willRemux,
  MediaType type = MediaType.video,
}) {
  final sourceExt = p.extension(sourcePath).toLowerCase();
  final fallback = sourceExt.isEmpty ? '.mp4' : sourceExt;
  if (!willRemux) return fallback;
  final matroska = type == MediaType.audio ? '.mka' : '.mkv';
  final styled = embedded.any((track) => !_isPlainTextSubtitle(track));
  if (styled) return matroska;
  final embeddingSubs = embedded.isNotEmpty;
  if (_canStayInContainer(fallback, embeddingSubs: embeddingSubs)) {
    return fallback;
  }
  return matroska;
}

bool zipCandidateNeedsProbe({
  required VideoItem item,
  required List<ZipSubtitleTrack> embedTracks,
}) {
  if (embedTracks.isNotEmpty || item.chapters.isNotEmpty) return true;
  final thumbnail = item.thumbnailPath?.trim() ?? '';
  return thumbnail.isNotEmpty && File(thumbnail).existsSync();
}

class ZipCandidateSet {
  final List<ZipCandidate> candidates;
  final List<ZipReferenceEntry> references;
  final int referenceCount;
  final int skippedOnline;
  final int skippedMissing;
  final ZipNameAllocator names;

  const ZipCandidateSet({
    required this.candidates,
    this.references = const [],
    this.referenceCount = 0,
    required this.skippedOnline,
    required this.skippedMissing,
    required this.names,
  });
}

String? _zipPodcastWebUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
          const ['http', 'https'].contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !value.contains(RegExp(r'[\r\n]'))
      ? value
      : null;
}

ZipCandidateSet enumerateZipCandidates({
  required LibraryService library,
  required List<String> rootIds,
}) {
  final names = ZipNameAllocator();
  final selection = PortableMediaSelection(rootIds);
  final tree = PortableTreeIndex.fromLibrary(library);
  final inclusion = selection.resolve(tree);
  final traversalIds = inclusion.traversalIds(tree);
  final candidates = <ZipCandidate>[];
  // Reserve this well-known metadata name before allocating user filenames.
  names.allocate('', zipPodcastReferencesPath);
  final references = <ZipReferenceEntry>[];
  final podcastCollections = <String, Map<String, dynamic>>{};
  final podcastVideos = <Map<String, dynamic>>[];
  final podcastBundles = <String, Map<String, dynamic>>{};
  final collectionDirectories = <String, String>{};
  var skippedOnline = rootIds.toSet().where((id) {
    final item = library.getVideo(id);
    return tree.node(id) == null &&
        item != null &&
        !communityMediaIsLocal(item.path);
  }).length;
  var skippedMissing = 0;
  final visited = <String>{};

  void addPodcastBundle(
    PodcastChannelRef ref,
    String title, {
    VideoItem? episodeItem,
  }) {
    final bundle = podcastBundles.putIfAbsent(
      ref.channelId,
      () => {
        'version': 2,
        'inheritanceVersion': 1,
        'channel': PodcastChannel(
          id: ref.channelId,
          feedUrl: ref.feedUrl,
          title: title,
        ).toJson(),
        'episodes': <Map<String, dynamic>>[],
        'states': <String, dynamic>{},
        'settings': <String, dynamic>{},
        'globalSettings': <String, dynamic>{},
      },
    );
    final episodeRef = episodeItem?.sourceRef?.podcast;
    if (episodeItem == null || episodeRef == null) return;
    final episodes = bundle['episodes'] as List<Map<String, dynamic>>;
    if (episodes.any((row) => row['id'] == episodeRef.episodeId)) return;
    episodes.add(
      PodcastEpisode(
        id: episodeRef.episodeId,
        channelId: ref.channelId,
        title: episodeItem.title,
        durationMs: episodeItem.durationMs,
        media: [PodcastMedia(url: episodeRef.mediaUrl)],
      ).toJson(),
    );
  }

  void addLink(String title, String feedUrl, String parentDirectory) {
    final uri = Uri.tryParse(feedUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        feedUrl.contains(RegExp(r'[\r\n]'))) {
      throw StateError('播客订阅地址无效：$title');
    }
    references.add(
      ZipReferenceEntry(
        archivePath: names.allocate(
          parentDirectory,
          '${sanitizeZipName(title)}.url',
        ),
        contents: '[InternetShortcut]\r\nURL=$feedUrl\r\n',
      ),
    );
  }

  String? referenceParent(String? id) {
    if (id == null || !inclusion.collectionIds.contains(id)) return null;
    if (podcastCollections.containsKey(id)) return id;
    final collection = library.getCollection(id);
    if (collection == null || collection.isRecycled) return null;
    // Mark before recursing so damaged cyclic folder metadata cannot loop.
    final record = <String, dynamic>{
      'exportId': id,
      'parentExportId': null,
      'name': collection.name,
      'createTime': collection.createTime,
      if (collection.podcastRef == null)
        'archiveDirectory': collectionDirectories[id],
      if (collection.podcastRef != null)
        'podcastRef': collection.podcastRef!.toJson(),
    };
    podcastCollections[id] = record;
    record['parentExportId'] = referenceParent(collection.parentId);
    if (collection.podcastRef case final ref?) {
      addPodcastBundle(ref, collection.name);
    }
    return id;
  }

  void omitDescendants(VideoCollection collection) {
    for (final id in collection.childrenIds) {
      if (!visited.add(id)) continue;
      final child = library.getCollection(id);
      if (child != null) omitDescendants(child);
    }
  }

  void walk(String id, String parentDirectory) {
    if (!traversalIds.contains(id)) return;
    if (!visited.add(id)) return;
    final collection = library.getCollection(id);
    if (collection != null && !collection.isRecycled) {
      if (!inclusion.collectionIds.contains(id)) {
        for (final childId in collection.childrenIds) {
          walk(childId, parentDirectory);
        }
        return;
      }
      // Historical folders containing ordinary local files keep their original
      // file export behavior. Live podcast cards contain catalog references.
      if (collection.podcastRef != null &&
          selection.isFullySelected(tree, id) &&
          !library
              .mediaInFolderTree(collection.id)
              .any((item) => communityMediaIsLocal(item.path))) {
        final ref = collection.podcastRef!;
        if (_zipPodcastWebUrl(ref.feedUrl) == null) {
          skippedOnline++;
          omitDescendants(collection);
          return;
        }
        references.add(
          ZipReferenceEntry(
            archivePath: names.allocate(
              parentDirectory,
              '${sanitizeZipName(collection.name)}.opml',
            ),
            contents: PodcastFeedParser().exportOpml([
              PodcastChannel(
                id: ref.channelId,
                feedUrl: ref.feedUrl,
                title: collection.name,
              ),
            ]),
          ),
        );
        referenceParent(collection.id);
        addPodcastBundle(ref, collection.name);
        omitDescendants(collection);
        return;
      }
      final ownDirectory = names.allocate(
        parentDirectory,
        sanitizeZipName(collection.name),
      );
      collectionDirectories[id] = ownDirectory;
      for (final childId in collection.childrenIds) {
        walk(childId, ownDirectory);
      }
      return;
    }
    final video = library.getVideo(id);
    if (video == null ||
        video.isRecycled ||
        video.isTransient ||
        !inclusion.videoIds.contains(id)) {
      return;
    }
    if (omitLegacyWebDownload(video, library)) {
      skippedOnline++;
      return;
    }
    if (!communityMediaIsLocal(video.path) &&
        video.sourceRef?.podcast != null) {
      final ref = video.sourceRef!.podcast!;
      if (!communityMediaIsPlayable(video.path, source: video.sourceRef)) {
        skippedOnline++;
        return;
      }
      addLink(
        video.title,
        _zipPodcastWebUrl(ref.mediaUrl) ?? ref.feedUrl,
        parentDirectory,
      );
      // Construct a reference record instead of copying a VideoItem containing
      // device-local download, subtitle, artwork or recycled file paths.
      final referenceItem = VideoItem(
        id: video.id,
        path: 'podcast:${ref.episodeId}',
        title: video.title,
        durationMs: video.durationMs,
        lastPositionMs: video.lastPositionMs,
        lastUpdated: video.lastUpdated,
        type: video.type,
        sourceRef: MediaSourceRef(
          value: ref.mediaUrl,
          kind: MediaSourceKind.podcastEpisode,
          podcast: ref,
        ),
      );
      podcastVideos.add({
        'exportId': video.id,
        'parentExportId': referenceParent(video.parentId),
        'isOnline': true,
        'video': referenceItem.toJson(),
      });
      addPodcastBundle(
        PodcastChannelRef(channelId: ref.channelId, feedUrl: ref.feedUrl),
        video.title,
        episodeItem: video,
      );
      return;
    }
    if (!communityMediaIsLocal(video.path)) {
      skippedOnline++;
      return;
    }
    final localPath = communityLocalMediaPath(video.path);
    if (!File(localPath).existsSync()) {
      skippedMissing++;
      return;
    }
    candidates.add(ZipCandidate(item: video, parentDirectory: parentDirectory));
  }

  for (final item in library.getContents(null)) {
    final id = item is VideoCollection ? item.id : (item as VideoItem).id;
    walk(id, '');
  }
  for (final id in <String>[
    ...inclusion.collectionIds,
    ...inclusion.videoIds,
  ]) {
    if (!visited.contains(id)) walk(id, '');
  }
  final referenceCount = references.length;
  if (references.isNotEmpty) {
    references.add(
      ZipReferenceEntry(
        archivePath: zipPodcastReferencesPath,
        contents: jsonEncode({
          'format': 'fluent-podcast-references',
          'formatVersion': 1,
          'snapshot': {
            'collections': podcastCollections.values.toList(),
            'videos': podcastVideos,
            'podcasts': podcastBundles.values.toList(),
          },
        }),
      ),
    );
  }
  return ZipCandidateSet(
    candidates: candidates,
    references: references,
    referenceCount: referenceCount,
    skippedOnline: skippedOnline,
    skippedMissing: skippedMissing,
    names: names,
  );
}

ZipExportLayout buildZipExportLayout({
  required LibraryService library,
  required List<String> rootIds,
  required bool embedSubtitles,
  required bool externalSubtitles,
  required bool includeDanmaku,
  ZipSourceFacts Function(VideoItem item)? factsFor,
}) {
  final draft = enumerateZipCandidates(library: library, rootIds: rootIds);
  final media = <ZipResolvedMedia>[
    for (final candidate in draft.candidates)
      resolveZipCandidate(
        candidate: candidate,
        names: draft.names,
        embedSubtitles: embedSubtitles,
        externalSubtitles: externalSubtitles,
        includeDanmaku: includeDanmaku,
        facts: factsFor?.call(candidate.item) ?? const ZipSourceFacts(),
      ),
  ];
  return ZipExportLayout(
    media: media,
    references: draft.references,
    skippedOnline: draft.skippedOnline,
    skippedMissing: draft.skippedMissing,
    names: draft.names,
  );
}

ZipResolvedMedia resolveZipCandidate({
  required ZipCandidate candidate,
  required ZipNameAllocator names,
  required bool embedSubtitles,
  required bool externalSubtitles,
  required bool includeDanmaku,
  required ZipSourceFacts facts,
}) {
  final item = candidate.item;
  final associated = collectAssociatedSubtitles(item);
  final danmaku = collectDanmakuTrack(item);
  final embedTracks = zipEmbedTracks(
    associated: associated,
    danmaku: danmaku,
    embedSubtitles: embedSubtitles,
    externalSubtitles: externalSubtitles,
    includeDanmaku: includeDanmaku,
  );
  final thumbnail = item.thumbnailPath?.trim() ?? '';
  final thumbnailReady = thumbnail.isNotEmpty && File(thumbnail).existsSync();
  final addCover = thumbnailReady && !facts.hasAttachedCover;
  final replaceChapters =
      facts.fileChapters != null &&
      item.chapters.isNotEmpty &&
      !zipChaptersMatch(item.chapters, facts.fileChapters!);
  final willRemux = embedTracks.isNotEmpty || addCover || replaceChapters;
  final extension = chooseZipOutputExtension(
    sourcePath: candidate.sourcePath,
    type: item.type,
    embedded: embedTracks,
    willRemux: willRemux,
  );
  final stem = sanitizeZipName(_cardStem(item));
  final archivePath = names.allocate(
    candidate.parentDirectory,
    '$stem$extension',
  );
  final sidecarTracks = <ZipSubtitleTrack>[
    if (externalSubtitles) ...associated,
    if (includeDanmaku && danmaku != null && externalSubtitles) danmaku,
  ];
  return ZipResolvedMedia(
    title: stem,
    sourcePath: candidate.sourcePath,
    sourceBytes: File(candidate.sourcePath).lengthSync(),
    durationMs: item.durationMs,
    directory: candidate.parentDirectory,
    stem: stem,
    archivePath: archivePath,
    remux: willRemux,
    embedTracks: embedTracks,
    coverPath: addCover ? thumbnail : null,
    replacementChapters: replaceChapters ? item.chapters : null,
    sidecars: _sidecarPlans(
      directory: candidate.parentDirectory,
      stem: stem,
      tracks: sidecarTracks,
      names: names,
    ),
    // Only payload requested for embedding may become fallback sidecars.
    fallbackTracks: embedTracks,
    existingSubtitleStreams: facts.subtitleStreamCount,
    existingSubtitleCodecs: facts.subtitleCodecs,
    existingVideoStreams: facts.videoStreamCount,
    missingSidecars: countMissingZipSidecars(
      item,
      includeSubtitles: embedSubtitles || externalSubtitles,
      includeDanmaku: includeDanmaku,
    ),
  );
}

List<ZipSidecarPlan> buildZipFallbackSidecars({
  required ZipResolvedMedia media,
  required String videoArchivePath,
  required ZipNameAllocator names,
}) {
  final stem = p.posix.basenameWithoutExtension(videoArchivePath);
  final directory = p.posix.dirname(videoArchivePath);
  final parent = directory == '.' ? '' : directory;
  return _sidecarPlans(
    directory: parent,
    stem: stem,
    tracks: media.fallbackTracks,
    names: names,
  );
}

String reallocateZipCopyPath({
  required ZipResolvedMedia media,
  required ZipNameAllocator names,
}) {
  names.release(media.archivePath);
  final extension = p.extension(media.sourcePath).toLowerCase();
  final sourceExtension = extension.isEmpty ? '.mp4' : extension;
  return names.allocate(media.directory, '${media.stem}$sourceExtension');
}

/// Path ffmpeg writes before the finished file is renamed into place.
///
/// FFmpeg picks the muxer from the final suffix and does not receive an
/// explicit `-f`. A trailing `.partial` (for example `0_0.mp4.partial`) is
/// not a container it knows, so every soft-subtitle remux fails and the
/// exporter falls back to sidecar files. Keep the real extension last.
String zipInProgressRemuxPath(String outputPath) {
  final extension = p.extension(outputPath);
  if (extension.isEmpty) return '$outputPath.partial';
  return '${p.withoutExtension(outputPath)}.partial$extension';
}

List<String> buildZipRemuxArguments({
  required String sourcePath,
  required String outputPath,
  required List<ZipSubtitleTrack> tracks,
  required String? coverPath,
  required String? chapterMetadataPath,
  required int existingSubtitleStreams,
  required int existingVideoStreams,
  required bool outputIsMp4Family,
  required bool progressPipe,
  List<String> existingSubtitleCodecs = const [],
}) {
  final args = <String>[
    '-hide_banner',
    '-nostdin',
    '-y',
    '-loglevel',
    'error',
    if (progressPipe) ...<String>['-progress', 'pipe:1'],
    '-i',
    sourcePath,
  ];
  for (final track in tracks) {
    args.addAll(<String>['-i', track.path]);
  }
  final coverInput = coverPath == null ? null : 1 + tracks.length;
  if (coverPath != null) {
    args.addAll(<String>['-i', coverPath]);
  }
  final chapterInput = chapterMetadataPath == null
      ? null
      : 1 + tracks.length + (coverPath == null ? 0 : 1);
  if (chapterMetadataPath != null) {
    args.addAll(<String>['-i', chapterMetadataPath]);
  }
  args.addAll(<String>['-map', '0']);
  for (var index = 0; index < tracks.length; index++) {
    args.addAll(<String>['-map', '${index + 1}:0']);
  }
  if (coverInput != null) {
    args.addAll(<String>['-map', '$coverInput:v:0']);
  }
  args.addAll(<String>['-c', 'copy']);
  if (_mkvFamily.contains(p.extension(outputPath).toLowerCase())) {
    for (var index = 0; index < existingSubtitleCodecs.length; index++) {
      if (existingSubtitleCodecs[index] == 'mov_text') {
        // MP4 timed text has no Matroska representation. Convert only these
        // existing tracks; ASS/SSA streams keep their styling and motion.
        args.addAll(<String>['-c:s:$index', 'srt']);
      }
    }
  }
  for (var index = 0; index < tracks.length; index++) {
    final streamIndex = existingSubtitleStreams + index;
    final track = tracks[index];
    final convert = outputIsMp4Family && _isPlainTextSubtitle(track);
    args.addAll(<String>['-c:s:$streamIndex', convert ? 'mov_text' : 'copy']);
    final disposition = track.isDefault && !track.isDanmaku ? 'default' : '0';
    args.addAll(<String>['-disposition:s:$streamIndex', disposition]);
    args.addAll(<String>['-metadata:s:s:$streamIndex', 'title=${track.title}']);
    final language = track.language?.trim() ?? '';
    if (_isLanguageCode(language)) {
      args.addAll(<String>['-metadata:s:s:$streamIndex', 'language=$language']);
    }
  }
  if (coverInput != null) {
    final videoIndex = existingVideoStreams < 0 ? 0 : existingVideoStreams;
    args.addAll(<String>[
      '-c:v:$videoIndex',
      'mjpeg',
      '-disposition:v:$videoIndex',
      'attached_pic',
    ]);
  }
  if (chapterInput != null) {
    args.addAll(<String>['-map_chapters', '$chapterInput']);
  }
  args.add(outputPath);
  return args;
}

List<ZipSidecarPlan> _sidecarPlans({
  required String directory,
  required String stem,
  required List<ZipSubtitleTrack> tracks,
  required ZipNameAllocator names,
}) {
  final subtitles = tracks.where((track) => !track.isDanmaku).toList();
  return <ZipSidecarPlan>[
    for (final track in tracks)
      ZipSidecarPlan(
        sourcePath: track.path,
        archivePath: names.allocate(
          directory,
          _sidecarFileName(
            stem: stem,
            track: track,
            soleSubtitle: subtitles.length == 1,
          ),
        ),
      ),
  ];
}

String _sidecarFileName({
  required String stem,
  required ZipSubtitleTrack track,
  required bool soleSubtitle,
}) {
  final extension = track.extension.toLowerCase();
  if (track.isDanmaku) return '$stem.弹幕$extension';
  if (soleSubtitle) return '$stem$extension';
  final language = track.language?.trim() ?? '';
  final label = sanitizeZipName(language.isNotEmpty ? language : track.title);
  return '$stem.$label$extension';
}

String _cardStem(VideoItem item) {
  final title = item.title.trim();
  if (title.isNotEmpty) return title;
  final stem = p.basenameWithoutExtension(item.path).trim();
  return stem.isEmpty ? '未命名' : stem;
}

String _normalizePath(String path) {
  final normalized = p.normalize(File(path).absolute.path);
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _isPlainTextSubtitle(ZipSubtitleTrack track) {
  final extension = track.extension.toLowerCase();
  return !track.isDanmaku && (extension == '.srt' || extension == '.vtt');
}

bool _canStayInContainer(String extension, {required bool embeddingSubs}) {
  if (_mkvFamily.contains(extension) || _mp4Family.contains(extension)) {
    return true;
  }
  return !embeddingSubs && _audioKeepFamily.contains(extension);
}

bool _isLanguageCode(String value) =>
    RegExp(r'^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})?$').hasMatch(value);
