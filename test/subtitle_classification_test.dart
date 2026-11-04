import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_classification.dart';
import 'package:video_player_app/models/video_item.dart';

void main() {
  group('VideoItem subtitle origin migration', () {
    test('download-bound subtitles are the only associated subtitles', () {
      final item = VideoItem(
        id: 'download-1',
        path: r'D:\videos\movie.mp4',
        title: 'movie',
        durationMs: 0,
        lastUpdated: 0,
        subtitlePath: r'D:\other\selected.srt',
        additionalSubtitles: {'English': r'D:\app\subtitles\download_en.srt'},
        localSubtitles: {'Notes': r'D:\app\subtitles\movie.manual.1.srt'},
        usesManagedAssociatedSubtitles: true,
      );

      expect(item.downloadAssociatedSubtitles.values, [
        r'D:\app\subtitles\download_en.srt',
      ]);
      expect(
        item.downloadAssociatedSubtitles.values,
        isNot(contains(item.subtitlePath)),
      );
      expect(item.localSubtitleGroups.values, [
        r'D:\app\subtitles\movie.manual.1.srt',
      ]);
    });

    test('ordinary legacy extra subtitles migrate to local', () {
      final item = VideoItem.fromJson({
        'id': 'local-1',
        'path': r'D:\videos\movie.mp4',
        'title': 'movie',
        'durationMs': 0,
        'lastUpdated': 0,
        'extraSubtitles': {'S1': r'D:\app\subtitles\movie.manual.1.srt'},
      });

      expect(item.downloadAssociatedSubtitles, isEmpty);
      expect(item.localSubtitleGroups.keys, ['S1']);
    });

    test('legacy Bilibili download association is migrated', () {
      final item = VideoItem.fromJson({
        'id': 'bili-1',
        'path': r'D:\videos\movie.mp4',
        'title': 'movie',
        'durationMs': 0,
        'lastUpdated': 0,
        'isBilibiliExported': true,
        'usesManagedAssociatedSubtitles': false,
        'extraSubtitles': {'中文': r'D:\app\subtitles\bili_zh.srt'},
      });

      expect(item.usesManagedAssociatedSubtitles, isTrue);
      expect(item.downloadAssociatedSubtitles.keys, ['中文']);
    });

    test('known legacy local files are removed from download associations', () {
      final item = VideoItem(
        id: 'mixed-1',
        path: r'D:\videos\movie.mp4',
        title: 'movie',
        durationMs: 0,
        lastUpdated: 0,
        usesManagedAssociatedSubtitles: true,
        additionalSubtitles: {
          '下载字幕': r'D:\app\subtitles\download_en.srt',
          '旧内嵌字幕': r'D:\app\subtitles\mixed-1.stream_2.srt',
          '旧手动字幕': r'D:\app\subtitles\mixed-1.manual.1.srt',
          '旧AI字幕': r'D:\app\subtitles\mixed-1.ai.srt',
        },
      );

      expect(item.downloadAssociatedSubtitles.keys, ['下载字幕']);
      expect(
        item.localSubtitleGroups.keys,
        containsAll(['旧内嵌字幕', '旧手动字幕', '旧AI字幕']),
      );
    });
  });

  group('SubtitleClassificationIndex', () {
    final index = SubtitleClassificationIndex(
      downloadAssociatedPaths: [r'D:\subs\download.srt'],
      extractedEmbeddedPaths: [r'D:\subs\movie.stream_1.srt'],
    );

    test('classifies explicit download association', () {
      expect(
        index.categoryForPath(r'D:\subs\download.srt'),
        SubtitleCategory.downloadAssociated,
      );
    });

    test('classifies extracted embedded track', () {
      expect(
        index.categoryForPath(r'D:\subs\movie.stream_1.srt'),
        SubtitleCategory.embedded,
      );
    });

    test('classifies sidecar, AI, manual and external files as local', () {
      for (final path in [
        r'D:\videos\movie.zh.srt',
        r'D:\subs\movie.ai.srt',
        r'D:\subs\movie.manual.1.srt',
        r'E:\unrelated\picked.ass',
      ]) {
        expect(index.categoryForPath(path), SubtitleCategory.local);
      }
    });

    test('playback role does not affect category', () {
      const selectedPrimaryPath = r'E:\unrelated\picked.ass';
      expect(
        index.categoryForPath(selectedPrimaryPath),
        SubtitleCategory.local,
      );
    });

    test('explicit download metadata wins over filesystem appearance', () {
      final overlap = SubtitleClassificationIndex(
        downloadAssociatedPaths: [r'D:\subs\same.srt'],
        extractedEmbeddedPaths: [r'D:\subs\same.srt'],
      );
      expect(
        overlap.categoryForPath(r'D:\subs\same.srt'),
        SubtitleCategory.downloadAssociated,
      );
    });
  });
}
