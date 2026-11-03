import 'dart:io';

import '../../models/managed_subtitle_asset.dart';
import '../../models/subtitle_model.dart';
import '../../services/library_service.dart';
import '../../services/media_playback_service.dart';
import '../../services/subtitle_word_timing_store.dart';
import '../../services/task_subtitle_storage_service.dart';
import 'lyric_search_models.dart';

class LyricImportRequest {
  const LyricImportRequest(
    this.lyrics, {
    this.includeTranslation = false,
    this.offset = Duration.zero,
  });
  final DownloadedLyrics lyrics;
  final bool includeTranslation;
  final Duration offset;
}

class LyricSearchImporter {
  const LyricSearchImporter();

  Future<bool> import({
    required String itemId,
    required LyricImportRequest request,
    required LibraryService library,
    required MediaPlaybackService playback,
  }) async {
    if (playback.currentItem?.id != itemId) {
      throw StateError('播放歌曲已切换，请重新打开歌词搜索');
    }
    if (library.getVideo(itemId) == null) throw StateError('请先将当前歌曲加入媒体库');
    final original = request.lyrics.shifted(
      request.lyrics.original,
      request.offset,
    );
    final translation = request.includeTranslation
        ? request.lyrics.shifted(request.lyrics.translation, request.offset)
        : <SubtitleItem>[];
    if (original.isEmpty) throw const FormatException('时间偏移后没有可用歌词');
    final track = request.lyrics.track;
    final label = '${track.title} · ${track.source.label}';
    Future<String> save(
      List<SubtitleItem> cues,
      String name, {
      String? sourceAssetId,
      String? language,
    }) async {
      final path = await library.allocateSubtitleFile(
        itemId,
        TaskSubtitleStorageService.readableSubtitleFileName(
          label: name,
          extension: '.srt',
        ),
      );
      await File(path).writeAsString(encodeSrt(cues), flush: true);
      // Sentence SRT stays compatible with every player; real word timing is
      // preserved in the app's existing companion format and media lifecycle.
      await SubtitleWordTimingStore.write(path, cues);
      final asset = await library.registerManagedSubtitleAsset(
        itemId,
        path: path,
        kind: ManagedSubtitleAssetKind.downloaded,
        displayName: name,
        sourceAssetId: sourceAssetId,
        language: language,
      );
      if (asset == null) throw StateError('歌曲已从媒体库移除');
      return path;
    }

    final primaryPath = await save(original, '$label · 原文');
    final sourceAsset = library.managedSubtitleAssetForPath(
      itemId,
      primaryPath,
    );
    final secondaryPath = translation.isEmpty
        ? null
        : await save(
            translation,
            '$label · 中文翻译',
            sourceAssetId: sourceAsset?.assetId,
            language: 'zh',
          );
    // The playback service also rejects stale subtitle loads if the user
    // switches songs or chooses another subtitle while file parsing runs.
    final loaded = await playback.loadSubtitlePathsForCurrentItem(
      itemId: itemId,
      paths: [primaryPath, ?secondaryPath],
    );
    if (!loaded || playback.currentItem?.id != itemId) return false;
    await library.updateVideoSubtitles(
      itemId,
      primaryPath,
      false,
      secondarySubtitlePath: secondaryPath,
    );
    return true;
  }

  static String timestamp(Duration time) {
    final ms = time.inMilliseconds;
    String pad(int n, int width) => n.toString().padLeft(width, '0');
    return '${pad(ms ~/ 3600000, 2)}:${pad(ms ~/ 60000 % 60, 2)}:${pad(ms ~/ 1000 % 60, 2)},${pad(ms % 1000, 3)}';
  }

  static String encodeSrt(List<SubtitleItem> cues) => [
    for (var i = 0; i < cues.length; i++)
      '${i + 1}\n${timestamp(cues[i].startTime)} --> ${timestamp(cues[i].endTime)}\n${cues[i].text}\n',
  ].join('\n');
}
