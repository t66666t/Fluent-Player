import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:path/path.dart' as p;

import '../../models/subtitle_model.dart';
import '../../models/managed_subtitle_asset.dart';
import '../../models/video_item.dart';
import '../../services/bilibili/bilibili_offline_details.dart';
import '../../services/bilibili/bilibili_player_video.dart';
import '../../services/bilibili/bilibili_subtitle_tracks.dart';
import '../../services/subtitle_discovery_service.dart';
import '../../utils/subtitle_file_matcher.dart';
import '../../utils/subtitle_parser.dart';
import '../../utils/subtitle_util.dart';
import '../youtube_download/models/youtube_download_models.dart';

/// A snapshot, independent of which subtitle tracks happen to be displayed.
class AiVideoContext {
  const AiVideoContext({
    required this.videoId,
    required this.title,
    this.metadata = const <String, dynamic>{},
    this.tracks = const <AiSubtitleTrack>[],
    this.position = Duration.zero,
  });

  final String videoId;
  final String title;
  final Map<String, dynamic> metadata;

  /// Playback changes are appended per turn, never included in the reusable
  /// source prefix. Sort object keys so reloaded metadata has the same order.
  Map<String, dynamic> get promptMetadata {
    Object? ordered(Object? value) {
      if (value is Map) {
        final entries = value.entries.toList()
          ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
        return {
          for (final entry in entries)
            entry.key.toString(): ordered(entry.value),
        };
      }
      if (value is List) return value.map(ordered).toList();
      return value;
    }

    return Map<String, dynamic>.from(
      ordered({...metadata}..remove('positionMs'))! as Map,
    );
  }

  final List<AiSubtitleTrack> tracks;
  final Duration position;
}

class AiSubtitleTrack {
  const AiSubtitleTrack({
    required this.id,
    required this.label,
    this.role = 'other',
    this.cues = const <SubtitleItem>[],
    this.error,
    this.aliases = const <String>{},
    this.sourceDescription = '关联字幕',
    this.fileName,
  });

  final String id;
  final String label;
  final String role;
  final List<SubtitleItem> cues;
  final String? error;
  final String sourceDescription;

  /// A basename for local preview only; full paths never enter model context.
  final String? fileName;

  /// Former local-file IDs retained when an online subtitle is saved to disk.
  final Set<String> aliases;

  bool get hasText => cues.any((cue) => cue.text.trim().isNotEmpty);
}

class _SubtitleFacts {
  const _SubtitleFacts(
    this.characters,
    this.firstMs,
    this.lastMs,
    this.language,
  );
  final int characters;
  final int firstMs;
  final int lastMs;
  final String? language;
}

final Expando<_SubtitleFacts> _subtitleFacts = Expando<_SubtitleFacts>(
  'ai-subtitle-facts',
);

_SubtitleFacts _factsOf(List<SubtitleItem> cues) =>
    _subtitleFacts[cues] ??= (() {
      var characters = 0;
      int? first;
      var last = 0;
      final sample = StringBuffer();
      for (final cue in cues) {
        if (cue.text.trim().isEmpty) continue;
        characters += cue.text.length;
        first = first == null
            ? cue.startTime.inMilliseconds
            : math.min(first, cue.startTime.inMilliseconds);
        last = math.max(last, cue.endTime.inMilliseconds);
        if (sample.length < 1600) {
          sample.write(
            cue.text.substring(
              0,
              math.min(1600 - sample.length, cue.text.length),
            ),
          );
        }
      }
      final text = sample.toString();
      final language = RegExp(r'[\u3040-\u30ff]').allMatches(text).length >= 2
          ? 'ja'
          : RegExp(r'[\uac00-\ud7af]').allMatches(text).length >= 2
          ? 'ko'
          : RegExp(r'[\u3400-\u9fff]').allMatches(text).length >= 3
          ? 'zh'
          : RegExp(r'[a-zA-Z]').allMatches(text).length >= 10
          ? 'en'
          : null;
      return _SubtitleFacts(characters, first ?? 0, last, language);
    })();

/// Playback choices are authoritative. Without them, recommend one complete,
/// readable source, preferring the user's language and associated human text.
/// This does not change video playback subtitles or override an explicit chat
/// selection (including an intentionally empty selection).
Set<String> recommendAiSubtitleTracks(AiVideoContext video) {
  final readable = video.tracks
      .where(
        (track) => track.hasText && !(track.error?.contains('乱码') ?? false),
      )
      .toList();
  final playback = readable
      .where((track) => track.role == 'primary' || track.role == 'secondary')
      .map((track) => track.id)
      .toSet();
  if (playback.isNotEmpty) return playback;
  if (readable.isEmpty) return <String>{};
  final preferred =
      _languageCode(
        '${video.metadata['preferredLanguage'] ?? Platform.localeName}',
      ) ??
      'zh';
  final explicitDuration = video.metadata['durationMs'];
  final duration = explicitDuration is num && explicitDuration > 0
      ? explicitDuration.toInt()
      : readable
            .map((track) => _factsOf(track.cues).lastMs)
            .fold<int>(0, (a, b) => math.max(a, b));
  double score(AiSubtitleTrack track) {
    final facts = _factsOf(track.cues);
    final coverage = duration > 0
        ? ((facts.lastMs - facts.firstMs) / duration).clamp(0.0, 1.0)
        : 0.5;
    final source = track.sourceDescription;
    final language =
        _languageCode(
          '${track.label} ${track.sourceDescription} ${track.fileName ?? ''}',
        ) ??
        facts.language;
    return coverage * 75 +
        math.min(15.0, math.log(1 + facts.characters) * 2) +
        (language == preferred ? 18 : 0) +
        (source.contains('已关联') || source.contains('已绑定') ? 20 : 0) +
        (source.contains('手工') || source.contains('人工') ? 20 : 0) -
        (source.contains('自动生成') ||
                source.contains('AI 转写') ||
                source.contains('OCR')
            ? 10
            : 0) -
        (source.contains('同目录候选') ? 15 : 0) -
        (track.error != null ? 25 : 0);
  }

  readable.sort((a, b) {
    final byQuality = score(b).compareTo(score(a));
    return byQuality != 0 ? byQuality : a.id.compareTo(b.id);
  });
  return {readable.first.id};
}

String? _languageCode(String value) {
  final text = value.trim().toLowerCase().replaceAll('_', '-');
  if (RegExp(r'繁[体體]|zh-(hant|tw|hk)|\bcht\b').hasMatch(text)) return 'zh-Hant';
  if (RegExp(
    r'中文|简[体體]|汉语|漢語|(?:^|[^a-z])(?:ai-)?(?:zh(?:-hans|-cn)?|chi|zho|chs)(?:$|[^a-z])',
  ).hasMatch(text)) {
    return 'zh';
  }
  if (RegExp(
    r'英语|英語|英文|english|(?:^|[^a-z])(?:en(?:-[a-z]{2})?|eng)(?:$|[^a-z])',
  ).hasMatch(text)) {
    return 'en';
  }
  if (RegExp(
    r'日语|日語|日文|日本語|(?:^|[^a-z])(?:ja|jpn|jp)(?:$|[^a-z])',
  ).hasMatch(text)) {
    return 'ja';
  }
  if (RegExp(r'韩语|韓語|韩文|(?:^|[^a-z])(?:ko|kor)(?:$|[^a-z])').hasMatch(text)) {
    return 'ko';
  }
  final code = RegExp(
    r'^(?:ai-)?([a-z]{2,3})(?:-[a-z]{2,4})?$',
  ).firstMatch(text)?.group(1);
  return code != null && SubtitleUtil.getLanguageName(code) != code
      ? code
      : null;
}

String _languageLabel(String? code) => switch (code) {
  'zh' => '中文',
  'zh-Hant' => '中文（繁体）',
  'en' => '英语',
  'ja' => '日语',
  'ko' => '韩语',
  null => '',
  _ => SubtitleUtil.getLanguageName(code),
};

String _kindDescription(ManagedSubtitleAssetKind kind) => switch (kind) {
  ManagedSubtitleAssetKind.ai => 'AI 转写',
  ManagedSubtitleAssetKind.translated => '翻译字幕',
  ManagedSubtitleAssetKind.imported => '导入字幕',
  ManagedSubtitleAssetKind.manual => '手工编辑',
  ManagedSubtitleAssetKind.embedded => '内嵌提取',
  ManagedSubtitleAssetKind.downloaded => '下载字幕',
  ManagedSubtitleAssetKind.ocr => 'OCR 识别',
  ManagedSubtitleAssetKind.cached => '缓存字幕',
};

String _kindLabel(ManagedSubtitleAssetKind? kind) => switch (kind) {
  ManagedSubtitleAssetKind.ai => 'AI 转写稿',
  ManagedSubtitleAssetKind.translated => '翻译字幕',
  ManagedSubtitleAssetKind.imported => '导入字幕',
  ManagedSubtitleAssetKind.manual => '手工字幕',
  ManagedSubtitleAssetKind.embedded => '内嵌字幕',
  ManagedSubtitleAssetKind.downloaded => '下载字幕',
  ManagedSubtitleAssetKind.ocr => 'OCR 字幕',
  ManagedSubtitleAssetKind.cached => '字幕',
  null => '字幕',
};

ManagedSubtitleAssetKind? _kindFromPath(String path) {
  final name = p.basename(path).toLowerCase();
  if (RegExp(r'(?:^|[._-])manual(?:[._-]|$)').hasMatch(name)) {
    return ManagedSubtitleAssetKind.manual;
  }
  if (RegExp(r'(?:^|[._-])(?:ai|asr)(?:[._-]|$)').hasMatch(name)) {
    return ManagedSubtitleAssetKind.ai;
  }
  if (RegExp(r'(?:^|[._-])ocr(?:[._-]|$)').hasMatch(name)) {
    return ManagedSubtitleAssetKind.ocr;
  }
  if (RegExp(r'(?:^|[._-])translated?(?:[._-]|$)').hasMatch(name)) {
    return ManagedSubtitleAssetKind.translated;
  }
  if (RegExp(r'(?:^|[._-])stream(?:[._-]|$)').hasMatch(name)) {
    return ManagedSubtitleAssetKind.embedded;
  }
  return null;
}

class _TrackPresentation {
  const _TrackPresentation(
    this.name,
    this.source,
    this.fileName, {
    this.language,
    this.kind,
  });
  final String name;
  final String source;
  final String? fileName;
  final String? language;
  final ManagedSubtitleAssetKind? kind;
}

String _cleanSubtitleName(String value, {String? videoStem}) {
  var text = value.trim();
  if (text.contains('%')) {
    try {
      text = Uri.decodeComponent(text);
    } catch (_) {}
  }
  if (RegExp(r'[ÃÂäåæç]').hasMatch(text)) {
    // Common labels were UTF-8 decoded as Latin-1 or Windows-1252. The latter
    // maps C1 bytes to punctuation, e.g. 中文 becomes ä¸­æ–‡.
    const windows1252 = <int, int>{
      0x20ac: 0x80,
      0x201a: 0x82,
      0x0192: 0x83,
      0x201e: 0x84,
      0x2026: 0x85,
      0x2020: 0x86,
      0x2021: 0x87,
      0x02c6: 0x88,
      0x2030: 0x89,
      0x0160: 0x8a,
      0x2039: 0x8b,
      0x0152: 0x8c,
      0x017d: 0x8e,
      0x2018: 0x91,
      0x2019: 0x92,
      0x201c: 0x93,
      0x201d: 0x94,
      0x2022: 0x95,
      0x2013: 0x96,
      0x2014: 0x97,
      0x02dc: 0x98,
      0x2122: 0x99,
      0x0161: 0x9a,
      0x203a: 0x9b,
      0x0153: 0x9c,
      0x017e: 0x9e,
      0x0178: 0x9f,
    };
    final bytes = text.runes
        .map((rune) => windows1252[rune] ?? rune)
        .toList(growable: false);
    if (bytes.every((byte) => byte <= 255)) {
      try {
        text = utf8.decode(bytes);
      } catch (_) {}
    }
  }
  if (text.contains('\uFFFD') || text.contains('锟斤拷')) return '';
  text = p.basename(text.replaceAll('\\', '/'));
  text = text.replaceFirst(
    RegExp(
      r'\.(?:srt|vtt|ass|ssa|lrc|json|sup|idx|sub)$',
      caseSensitive: false,
    ),
    '',
  );
  if (videoStem != null &&
      videoStem.isNotEmpty &&
      text.toLowerCase().startsWith(videoStem.toLowerCase())) {
    text = text.substring(videoStem.length);
  }
  text = text
      .replaceAll(
        RegExp(
          r'[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(r'(^|[\s._-])[a-f0-9]{8,}(?=$|[\s._-])', caseSensitive: false),
        ' ',
      )
      .replaceAll(RegExp(r'(^|[\s._-])\d{13,}(?=$|[\s._-])'), ' ')
      .replaceAll(
        RegExp(
          r'\b(?:subtitle|subtitles|cache|cached|temp|tmp|stream)[_-]?\d*\b',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'^[ ._-]+|[ ._-]+$'), '')
      .trim();
  if (text.isEmpty ||
      RegExp(r'^[a-f0-9_-]{8,}$', caseSensitive: false).hasMatch(text) ||
      RegExp(
        r'^(?:manual|ai|ocr|asr|embedded|downloaded|imported|translated?)(?:[._-]\d+)?$',
        caseSensitive: false,
      ).hasMatch(text)) {
    return '';
  }
  return String.fromCharCodes(text.runes.take(80));
}

class _ParsedSource {
  const _ParsedSource(this.modified, this.size, this.cues);
  final DateTime modified;
  final int size;
  final List<SubtitleItem> cues;
}

/// Reads existing subtitle files and online subtitle JSON, never video media.
/// Supplying the app's BilibiliSubtitleTracks preserves its login and listing
/// policy. Fetched JSON is kept in memory and does not change selected subtitles.
class AiVideoContextLoader {
  AiVideoContextLoader({
    this.bilibiliTracks,
    this.discovery = const SubtitleDiscoveryService(),
    this.offlineDetails,
    this.ytDlpTasks,
    this.onlineTimeout = const Duration(seconds: 15),
    this.failedRetryDelay = const Duration(seconds: 30),
    this.allowRemoteSubtitleSources = false,
  });

  BilibiliSubtitleTracks? bilibiliTracks;
  final SubtitleDiscoveryService discovery;
  final BilibiliOfflineDetails? offlineDetails;

  /// Online link learning only uses user-supplied text. It cannot fetch legacy
  /// platform subtitle lists or promote downloader metadata into the context.
  final bool allowRemoteSubtitleSources;
  Iterable<YtDlpTaskRecord> Function()? ytDlpTasks;

  /// The chat session outlives the panel that created it. Each time a panel
  /// attaches, it points these at that panel's services. Callers must not
  /// touch a disposed [BuildContext] from [ytDlpTasks].
  void bindPlaybackSources({
    BilibiliSubtitleTracks? bilibiliTracks,
    Iterable<YtDlpTaskRecord> Function()? ytDlpTasks,
  }) {
    this.bilibiliTracks = bilibiliTracks;
    this.ytDlpTasks = ytDlpTasks;
  }

  final Duration onlineTimeout;
  final Duration failedRetryDelay;
  final Map<String, _ParsedSource> _files = <String, _ParsedSource>{};
  final Map<String, List<SubtitleItem>> _remote =
      <String, List<SubtitleItem>>{};
  final Map<String, String> _pathRemoteIds = <String, String>{};
  final Map<String, ({DateTime retryAfter, String message})> _remoteFailures =
      {};
  final Map<String, DateTime> _listingFailures = {};

  static String trackIdForPath(String path) {
    final normalized = p.normalize(path);
    return 'file:${Platform.isWindows ? normalized.toLowerCase() : normalized}';
  }

  void clearCache() {
    _files.clear();
    _remote.clear();
    invalidateFailures();
  }

  /// An explicit retry bypasses backoff without discarding successful content.
  /// Automatic refresh before sending should retain the short failure backoff.
  void invalidateFailures() {
    _remoteFailures.clear();
    _listingFailures.clear();
  }

  Future<AiVideoContext> load({
    required VideoItem video,
    List<SubtitleItem> primarySubtitles = const <SubtitleItem>[],
    List<SubtitleItem> secondarySubtitles = const <SubtitleItem>[],
    Duration position = Duration.zero,
    String? primaryPath,
    String? secondaryPath,
  }) async {
    final primary = primaryPath ?? video.subtitlePath;
    final secondary = secondaryPath ?? video.secondarySubtitlePath;
    final paths = <String, String>{};
    final presentations = <String, _TrackPresentation>{};
    final videoStem = p.basenameWithoutExtension(video.path);
    void add(
      String? path,
      String label, {
      String source = '关联字幕',
      String? language,
      ManagedSubtitleAssetKind? kind,
    }) {
      if (path == null || path.trim().isEmpty) return;
      final id = trackIdForPath(path);
      paths.putIfAbsent(id, () => path);
      presentations.putIfAbsent(
        id,
        () => _TrackPresentation(
          label,
          source,
          p.basename(path),
          language: language,
          kind: kind,
        ),
      );
    }

    for (final asset in video.managedSubtitleAssets) {
      add(
        asset.path,
        asset.displayName,
        source: '${_kindDescription(asset.kind)} · 已关联',
        language: asset.language,
        kind: asset.kind,
      );
    }
    for (final entry in video.downloadAssociatedSubtitles.entries) {
      add(
        entry.value,
        entry.key,
        source:
            '${bilibiliPlayerVideoOf(video) == null ? '下载关联' : '哔哩哔哩下载'} · 已关联',
        kind: ManagedSubtitleAssetKind.downloaded,
      );
    }
    for (final entry in video.localSubtitleGroups.entries) {
      add(
        entry.value,
        entry.key,
        source: '本地字幕 · 已关联',
        kind: _kindFromPath(entry.value),
      );
    }
    add(
      primary,
      '主字幕',
      source: '播放器选定字幕',
      kind: primary == null ? null : _kindFromPath(primary),
    );
    add(
      secondary,
      '副字幕',
      source: '播放器选定字幕',
      kind: secondary == null ? null : _kindFromPath(secondary),
    );
    final metadata = <String, dynamic>{
      'title': video.title,
      'durationMs': video.durationMs,
      'mediaType': video.type.name,
      if (video.codec != null) 'codec': video.codec,
      'positionMs': position.inMilliseconds,
      'isOnline': video.path.contains('://'),
      'container': p.extension(video.path).replaceFirst('.', '').toLowerCase(),
      'chapters': video.chapters
          .map(
            (chapter) => <String, dynamic>{
              'title': chapter.title,
              'startMs': chapter.startMs,
              'endMs': chapter.endMs,
            },
          )
          .toList(),
    };
    final ref = video.sourceRef;
    if (ref != null) {
      metadata['sourceType'] = ref.kind.name;
      // Signed stream URLs and local filesystem paths do not belong in prompts.
      final source = Uri.tryParse(ref.originalValue ?? ref.value);
      if (source != null &&
          (source.scheme == 'https' || source.scheme == 'http')) {
        metadata['source'] = Uri(
          scheme: source.scheme,
          host: source.host,
          port: source.hasPort ? source.port : null,
          path: source.path,
        ).toString();
      }
    }
    if (allowRemoteSubtitleSources) _addYtDlpMetadata(video, metadata);
    final bili = allowRemoteSubtitleSources
        ? bilibiliPlayerVideoOf(video)
        : null;
    if (bili != null) {
      metadata['bvid'] = bili.bvid;
      metadata['page'] = bili.page;
      if (ref?.cid != null) metadata['cid'] = ref!.cid;
      final detail = await (offlineDetails ?? BilibiliOfflineDetails.instance)
          .lookup(bili.bvid);
      if (detail != null) {
        metadata['uploader'] = detail.ownerName;
        metadata['description'] = detail.description;
      }
    }
    if (!video.path.contains('://')) {
      try {
        final discovered = await discovery.scanVideoDirectory(
          videoPath: video.path,
        );
        for (final entry in discovered) {
          if (entry.grade == SubtitleMatchGrade.rejected) continue;
          add(
            entry.path,
            p.basename(entry.path),
            source: entry.grade == SubtitleMatchGrade.autoMatch
                ? '同目录匹配字幕'
                : '同目录候选字幕',
            language: entry.analysis.languageCode,
            kind: _kindFromPath(entry.path),
          );
        }
      } on FileSystemException {
        metadata['subtitleDiscoveryWarning'] = '无法读取视频目录中的字幕候选';
      }
    }
    final tracks = <AiSubtitleTrack>[];
    String roleFor(String id) {
      if (primary != null && id == trackIdForPath(primary)) return 'primary';
      if (secondary != null && id == trackIdForPath(secondary)) {
        return 'secondary';
      }
      return 'other';
    }

    for (final entry in paths.entries) {
      final role = roleFor(entry.key);
      final active = role == 'primary'
          ? primarySubtitles
          : role == 'secondary'
          ? secondarySubtitles
          : const <SubtitleItem>[];
      if (active.isNotEmpty) {
        tracks.add(
          _track(
            entry.key,
            presentations[entry.key]!,
            role,
            active,
            videoStem: videoStem,
          ),
        );
        continue;
      }
      try {
        tracks.add(
          _track(
            entry.key,
            presentations[entry.key]!,
            role,
            await _read(entry.value),
            videoStem: videoStem,
          ),
        );
      } catch (error) {
        final appearance = _track(
          entry.key,
          presentations[entry.key]!,
          role,
          const [],
          videoStem: videoStem,
        );
        tracks.add(
          AiSubtitleTrack(
            id: entry.key,
            label: appearance.label,
            sourceDescription: appearance.sourceDescription,
            fileName: appearance.fileName,
            role: role,
            error: error is FormatException
                ? error.message
                : '字幕文件无法读取，请检查文件是否存在及访问权限',
          ),
        );
      }
    }
    if (primary == null && primarySubtitles.isNotEmpty) {
      tracks.add(
        _track(
          'active:primary',
          const _TrackPresentation('主字幕', '播放器实时字幕', null),
          'primary',
          primarySubtitles,
        ),
      );
    }
    if (secondary == null && secondarySubtitles.isNotEmpty) {
      tracks.add(
        _track(
          'active:secondary',
          const _TrackPresentation('副字幕', '播放器实时字幕', null),
          'secondary',
          secondarySubtitles,
        ),
      );
    }
    final service = allowRemoteSubtitleSources ? bilibiliTracks : null;
    if (service != null && BilibiliSubtitleTracks.covers(video)) {
      final clock = Stopwatch()..start();
      var listingTimedOut = false;
      try {
        final retryAfter = _listingFailures[video.id];
        if (retryAfter != null &&
            DateTime.now().isBefore(retryAfter) &&
            (service.listFor(video.id).loading ||
                service.listFor(video.id).failed)) {
          throw TimeoutException('subtitle list retry backoff');
        }
        await _boundedOnline(() => service.ensureLoaded(video.id), clock);
        // ensureLoaded deliberately returns immediately if another panel is
        // already requesting this part. Await that shared request before taking
        // our snapshot, instead of reporting a temporarily empty track list.
        if (service.listFor(video.id).loading &&
            BilibiliSubtitleTracks.onlineKeyOf(video) != null) {
          await _boundedOnline(
            () => _waitForListing(
              service,
              video.id,
              onlineTimeout - clock.elapsed,
            ),
            clock,
          );
        }
      } on TimeoutException {
        listingTimedOut = true;
      } catch (_) {
        metadata['onlineSubtitleWarning'] = '在线字幕列表暂时无法读取；已有本地字幕仍可使用';
      }
      final listing = service.listFor(video.id);
      if (listingTimedOut || listing.failed) {
        final previous = _listingFailures[video.id];
        if (previous == null || !DateTime.now().isBefore(previous)) {
          _listingFailures[video.id] = DateTime.now().add(failedRetryDelay);
        }
      } else if (!listing.loading) {
        _listingFailures.remove(video.id);
      }
      final warning = listingTimedOut || listing.loading
          ? '在线字幕加载已超时；已有本地字幕仍可使用，请稍后刷新'
          : listing.failureMessage ?? listing.loginMessage;
      if (warning != null) metadata['onlineSubtitleWarning'] = warning;
      final pending =
          <({BilibiliSubtitleTrack remote, String id, Set<String> aliases})>[];
      for (final remote in <BilibiliSubtitleTrack>[
        ...listing.tracks,
        ...listing.locked,
      ]) {
        final pathId = remote.path == null
            ? null
            : trackIdForPath(remote.path!);
        final identified = remote.id.isNotEmpty || remote.url.isNotEmpty;
        final id = identified
            ? 'bilibili:${video.id}:${remote.identity}'
            : pathId == null
            ? 'bilibili:${video.id}:${remote.identity}'
            : _pathRemoteIds[pathId] ?? pathId;
        if (pathId != null && identified) _pathRemoteIds[pathId] = id;
        final aliases = <String>{if (pathId != null && pathId != id) pathId};
        final localIndex = tracks.indexWhere((track) => track.id == pathId);
        if (localIndex >= 0) {
          final local = tracks[localIndex];
          tracks[localIndex] = AiSubtitleTrack(
            id: id,
            label: local.label,
            role: local.role,
            cues: local.cues,
            error: local.error,
            aliases: Set<String>.unmodifiable({...local.aliases, ...aliases}),
            sourceDescription: local.sourceDescription.contains('哔哩哔哩')
                ? local.sourceDescription
                : '哔哩哔哩下载 · ${local.sourceDescription}',
            fileName: local.fileName,
          );
          continue;
        }
        if (tracks.any((track) => track.id == id) ||
            pending.any((entry) => entry.id == id)) {
          continue;
        }
        pending.add((remote: remote, id: id, aliases: aliases));
      }
      // Listing and every content request share one wall-clock budget.
      // At most four tracks run concurrently, instead of multiplying timeout
      // delays by the number of languages an online video happens to have.
      for (var offset = 0; offset < pending.length; offset += 4) {
        final batch = pending.skip(offset).take(4);
        tracks.addAll(
          await Future.wait(
            batch.map(
              (entry) => _onlineTrack(
                service,
                entry.remote,
                entry.id,
                entry.aliases,
                entry.remote.path == null
                    ? 'other'
                    : roleFor(trackIdForPath(entry.remote.path!)),
                clock,
              ),
            ),
          ),
        );
      }
    }
    final labelCounts = <String, int>{};
    for (final track in tracks) {
      labelCounts.update(track.label, (count) => count + 1, ifAbsent: () => 1);
    }
    final labelSerials = <String, int>{};
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      if (labelCounts[track.label]! > 1) {
        final serial = labelSerials.update(
          track.label,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        tracks[i] = AiSubtitleTrack(
          id: track.id,
          label: '${track.label}（$serial）',
          role: track.role,
          cues: track.cues,
          error: track.error,
          aliases: track.aliases,
          sourceDescription: track.sourceDescription,
          fileName: track.fileName,
        );
      }
    }
    tracks.sort((a, b) {
      int priority(AiSubtitleTrack track) => track.role == 'primary'
          ? 0
          : track.role == 'secondary'
          ? 1
          : 2;
      final byRole = priority(a).compareTo(priority(b));
      if (byRole != 0) return byRole;
      final byLabel = a.label.compareTo(b.label);
      return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
    });
    return AiVideoContext(
      videoId: video.id,
      title: video.title,
      metadata: metadata,
      tracks: List<AiSubtitleTrack>.unmodifiable(tracks),
      position: position,
    );
  }

  AiSubtitleTrack _track(
    String id,
    _TrackPresentation presentation,
    String role,
    List<SubtitleItem> cues, {
    String? videoStem,
  }) {
    final hasText = cues.any((cue) => cue.text.trim().isNotEmpty);
    final images = cues.any((cue) => cue.imageLoader != null);
    final nickname = _cleanSubtitleName(
      presentation.name,
      videoStem: presentation.name == presentation.fileName ? videoStem : null,
    );
    final language =
        _languageCode(presentation.language ?? '') ??
        _languageCode('${presentation.name} ${presentation.fileName ?? ''}') ??
        _factsOf(cues).language;
    final languageName = _languageLabel(language);
    final fallback = role == 'primary'
        ? '主字幕'
        : role == 'secondary'
        ? '副字幕'
        : _kindLabel(presentation.kind);
    final generic =
        nickname.isEmpty ||
        nickname == '字幕' ||
        nickname == '主字幕' ||
        nickname == '副字幕';
    final languageOnly = RegExp(
      r'^(?:ai-)?(?:zh(?:-(?:cn|hans|hant|tw|hk))?|en(?:-[a-z]{2})?|eng|english|chs|cht|chi|zho|中文|简体中文|繁体中文|英文|英语|ja|jp|jpn|日语|ko|kor|韩语)$',
      caseSensitive: false,
    ).hasMatch(nickname);
    final label = generic
        ? (languageName.isEmpty ? fallback : '$fallback · $languageName')
        : languageOnly
        ? '$languageName字幕'
        : nickname;
    final type = presentation.kind == null
        ? ''
        : _kindDescription(presentation.kind!);
    final source = <String>[
      presentation.source,
      if (languageName.isNotEmpty) languageName,
      if (type.isNotEmpty && !presentation.source.contains(type)) type,
    ].join(' · ');
    final sample = cues.take(24).map((cue) => cue.text).join();
    final garbled =
        '\uFFFD'.allMatches(sample).length >= 3 ||
        '锟斤拷'.allMatches(sample).length >= 2;
    return AiSubtitleTrack(
      id: id,
      label: label,
      sourceDescription: source,
      fileName: presentation.fileName,
      role: role,
      cues: cues,
      error: garbled
          ? '字幕文字疑似乱码，请检查文件编码或重新导入后再选择'
          : !hasText
          ? images
                ? '图片字幕需先执行 OCR 识别，AI 无法直接读取图片字幕'
                : '此字幕没有可读取的文字'
          : images
          ? '已读取文字，部分图片字幕需先执行 OCR'
          : null,
    );
  }

  Future<List<SubtitleItem>> _read(String path) async {
    final extension = p.extension(path).toLowerCase();
    if (const <String>{'.sup', '.idx', '.sub'}.contains(extension)) {
      throw const FormatException('图片字幕需先执行 OCR 识别，AI 无法直接读取图片字幕');
    }
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw const FileSystemException('missing');
    }
    final id = trackIdForPath(path);
    final cached = _files[id];
    if (cached != null &&
        cached.modified == stat.modified &&
        cached.size == stat.size) {
      return cached.cues;
    }
    final bytes = await file.readAsBytes();
    final parsed = bytes.length > 128 * 1024
        ? await compute(_parseSubtitleBytes, (
            bytes: bytes,
            extension: extension,
          ))
        : _parseSubtitleBytes((bytes: bytes, extension: extension));
    final cues = List<SubtitleItem>.unmodifiable(parsed);
    _files[id] = _ParsedSource(stat.modified, stat.size, cues);
    _trimCache(_files);
    return cues;
  }

  static void _trimCache(Map<String, Object?> cache) {
    while (cache.length > 24) {
      cache.remove(cache.keys.first);
    }
  }

  Future<T> _boundedOnline<T>(Future<T> Function() operation, Stopwatch clock) {
    final remaining = onlineTimeout - clock.elapsed;
    if (remaining <= Duration.zero) {
      return Future<T>.error(
        TimeoutException('online subtitle context deadline'),
      );
    }
    return operation().timeout(remaining);
  }

  Future<AiSubtitleTrack> _onlineTrack(
    BilibiliSubtitleTracks service,
    BilibiliSubtitleTrack remote,
    String id,
    Set<String> aliases,
    String role,
    Stopwatch clock,
  ) async {
    try {
      if (remote.locked) throw const FormatException('登录哔哩哔哩后可读取此字幕');
      List<SubtitleItem>? cues = _remote[id];
      if (cues == null) {
        final failed = _remoteFailures[id];
        if (failed != null && DateTime.now().isBefore(failed.retryAfter)) {
          throw FormatException(failed.message);
        }
        if (remote.path != null) {
          cues = await _boundedOnline(() => _read(remote.path!), clock);
        } else {
          final payload = await _boundedOnline(
            () => service.source.fetchContent(remote.url),
            clock,
          );
          cues = _parseBilibili(payload);
          _remote[id] = cues;
          _trimCache(_remote);
        }
        _remoteFailures.remove(id);
      }
      final presentation = _TrackPresentation(
        remote.label,
        remote.path == null
            ? '哔哩哔哩在线 · ${remote.isAi ? '自动生成' : '人工字幕'}'
            : '哔哩哔哩下载 · 已关联',
        remote.path == null ? null : p.basename(remote.path!),
        language: remote.lan,
        kind: remote.isAi
            ? ManagedSubtitleAssetKind.ai
            : ManagedSubtitleAssetKind.downloaded,
      );
      final parsed = _track(id, presentation, role, cues!);
      return AiSubtitleTrack(
        id: parsed.id,
        label: parsed.label,
        role: parsed.role,
        cues: parsed.cues,
        error: parsed.error,
        aliases: Set<String>.unmodifiable(aliases),
        sourceDescription: parsed.sourceDescription,
        fileName: parsed.fileName,
      );
    } catch (error) {
      final message = error is TimeoutException
          ? '在线字幕读取已超时；可继续聊天或稍后刷新'
          : error is FormatException
          ? error.message
          : '在线字幕暂时无法读取，请稍后重试';
      // Successful content is cached independently; a failed unselected track
      // must not delay every subsequent question during an offline spell.
      final previous = _remoteFailures[id];
      if (!remote.locked &&
          (previous == null || !DateTime.now().isBefore(previous.retryAfter))) {
        _remoteFailures[id] = (
          retryAfter: DateTime.now().add(failedRetryDelay),
          message: message,
        );
        _trimCache(_remoteFailures);
      }
      return AiSubtitleTrack(
        id: id,
        label: _cleanSubtitleName(remote.label).isEmpty
            ? '${_languageLabel(_languageCode(remote.lan))}在线字幕'
            : _cleanSubtitleName(remote.label),
        sourceDescription: '哔哩哔哩在线 · ${remote.isAi ? '自动生成' : '人工字幕'}',
        fileName: remote.path == null ? null : p.basename(remote.path!),
        role: role,
        error: message,
        aliases: Set<String>.unmodifiable(aliases),
      );
    }
  }

  static Future<void> _waitForListing(
    BilibiliSubtitleTracks service,
    String id,
    Duration timeout,
  ) async {
    final ready = Completer<void>();
    void changed() {
      if (!service.listFor(id).loading && !ready.isCompleted) ready.complete();
    }

    service.addListener(changed);
    final timer = Timer(timeout > Duration.zero ? timeout : Duration.zero, () {
      if (!ready.isCompleted) ready.complete();
    });
    changed();
    try {
      await ready.future;
    } finally {
      timer.cancel();
      service.removeListener(changed);
    }
  }

  void _addYtDlpMetadata(VideoItem video, Map<String, dynamic> metadata) {
    final tasks = ytDlpTasks;
    if (tasks == null) return;
    final source = video.sourceRef;
    for (final task in tasks()) {
      final meta = task.meta;
      if (meta == null) continue;
      final sameFile =
          task.outputPath != null &&
          p.equals(p.normalize(task.outputPath!), p.normalize(video.path));
      final sameSource =
          source != null &&
          <String>{
            source.value,
            if (source.originalValue != null) source.originalValue!,
          }.any((url) => url == task.sourceUrl || url == meta.webpageUrl);
      if (!sameFile && !sameSource) continue;
      metadata['importProvider'] = 'yt-dlp';
      metadata['platform'] = meta.source;
      metadata['sourceVideoId'] = meta.id;
      metadata['uploader'] = meta.uploader;
      // rawInfo can include cookies, HTTP headers and signed media URLs; it
      // must never be sent wholesale to a model or shown in developer mode.
      for (final key in <String>[
        'description',
        'tags',
        'categories',
        'upload_date',
        'release_date',
        'license',
        'language',
        'view_count',
        'like_count',
        'age_limit',
        'live_status',
      ]) {
        final value = meta.rawInfo[key];
        if (value is String || value is num || value is bool) {
          metadata[key] = value;
        } else if (value is List && value.every((item) => item is String)) {
          metadata[key] = value.cast<String>().take(200).toList();
        }
      }
      break;
    }
  }

  static List<SubtitleItem> _parseSubtitleBytes(
    ({List<int> bytes, String extension}) input,
  ) {
    final text = SubtitleParser.decodeBytes(input.bytes);
    return input.extension == '.json'
        ? _parseBilibili(text)
        : SubtitleParser.parse(text);
  }

  static List<SubtitleItem> _parseBilibili(Object? payload) {
    final data = payload is String ? jsonDecode(payload) : payload;
    final body = data is Map ? data['body'] : null;
    if (body is! List) throw const FormatException('在线字幕格式无法识别');
    final cues = <SubtitleItem>[];
    for (final line in body) {
      if (line is! Map) continue;
      final from = num.tryParse('${line['from']}');
      final to = num.tryParse('${line['to']}');
      if (from == null || to == null || !from.isFinite || !to.isFinite) {
        continue;
      }
      cues.add(
        SubtitleItem(
          index: cues.length + 1,
          startTime: Duration(milliseconds: (from * 1000).round()),
          endTime: Duration(milliseconds: (to * 1000).round()),
          text: '${line['content'] ?? ''}',
        ),
      );
    }
    return List<SubtitleItem>.unmodifiable(cues);
  }
}
