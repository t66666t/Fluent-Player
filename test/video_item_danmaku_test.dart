import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/video_item.dart';

void main() {
  test('persists Bilibili danmaku association in the library model', () {
    final item = VideoItem(
      id: 'video-id',
      path: 'video.mp4',
      title: 'video',
      durationMs: 1000,
      lastUpdated: 1,
      isBilibiliExported: true,
      danmakuPath: 'danmaku/video-id_danmaku.ass',
    );

    final restored = VideoItem.fromJson(item.toJson());

    expect(restored.isBilibiliExported, isTrue);
    expect(restored.danmakuPath, 'danmaku/video-id_danmaku.ass');
  });
}
