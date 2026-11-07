import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/utils/media_display_title.dart';
import 'package:video_player_app/utils/supported_media_extensions.dart';

VideoItem _item(
  String path, {
  String title = '课程.MP4',
  MediaSourceRef? source,
}) => VideoItem(
  id: 'existing-media',
  path: path,
  title: title,
  sourceRef: source,
  durationMs: 0,
  lastUpdated: 0,
);

void main() {
  test('all supported video and audio suffixes hide and can be restored', () {
    for (final suffix in {
      ...kSupportedVideoExtensions,
      ...kSupportedAudioExtensions,
    }) {
      final title = '第1.2课$suffix';
      expect(localMediaDisplayTitle(title), '第1.2课', reason: suffix);
      expect(localMediaDisplayTitle(title, showExtension: true), title);
      expect(localMediaDisplayTitle(title.toUpperCase()), '第1.2课');
    }
  });

  test('titles retain dots, path-like characters and non-media endings', () {
    expect(
      localMediaDisplayTitle(r'  A/B\C: 第1.2课.MP4  '),
      r'  A/B\C: 第1.2课  ',
    );
    expect(localMediaDisplayTitle('合集.mp4.m4a'), '合集.mp4');
    for (final title in ['', '.mp4', ' .mp4', '课程', '第1.2课', '课程.custom']) {
      expect(localMediaDisplayTitle(title), title);
    }
  });

  test('local imports format identically without modifying persisted data', () {
    for (final path in [
      r'C:\Videos\课程.mp4',
      r'\\server\Videos\课程.mp4',
      '/storage/emulated/0/Movies/课程.mp4',
      '/archive-extracted/课程.mp4',
      'content://media/external/video/media/42',
      'file:///Users/example/Movies/lesson.mp4',
      '/private-library/opaque-media.fpv',
    ]) {
      final item = _item(path);
      final saved = item.toJson();
      expect(mediaItemDisplayTitle(item), '课程', reason: path);
      expect(
        mediaItemDisplayTitle(item, showLocalMediaExtensions: true),
        '课程.MP4',
      );
      expect(item.toJson(), saved);
    }
  });

  test('online and podcast titles keep publisher-provided suffixes', () {
    for (final path in [
      'https://example.com/video.mp4',
      'bilibili://stream/BV123',
      'cloud-drive://account/video.mp4',
      'podcast:episode-id',
    ]) {
      expect(mediaItemDisplayTitle(_item(path)), '课程.MP4');
    }
    for (final kind in [
      MediaSourceKind.bilibiliStream,
      MediaSourceKind.cloudDrive,
      MediaSourceKind.podcastEpisode,
    ]) {
      final item = _item(
        '/cache/video.mp4',
        source: MediaSourceRef(kind: kind, value: 'source-id'),
      );
      expect(mediaItemDisplayTitle(item), '课程.MP4');
    }
  });
}
