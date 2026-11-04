import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';

void main() {
  test('managed subtitle lineage survives VideoItem JSON round trip', () {
    const source = ManagedSubtitleAsset(
      assetId: 'source-id',
      path: r'C:\data\subtitles\tasks\card-1\ai.srt',
      kind: ManagedSubtitleAssetKind.ai,
      displayName: 'AI 字幕',
      language: 'en',
      createdAt: 10,
    );
    const translation = ManagedSubtitleAsset(
      assetId: 'translation-id',
      path: r'C:\data\subtitles\tasks\card-1\translated.zh.srt',
      kind: ManagedSubtitleAssetKind.translated,
      displayName: '中文翻译',
      sourceAssetId: 'source-id',
      language: 'zh-CN',
      createdAt: 20,
    );
    final item = VideoItem(
      id: 'card-1',
      path: r'C:\video\movie.mp4',
      title: 'movie',
      durationMs: 1000,
      lastUpdated: 1,
      managedSubtitleAssets: const <ManagedSubtitleAsset>[source, translation],
    );

    final restored = VideoItem.fromJson(item.toJson());

    expect(restored.managedSubtitleAssets, hasLength(2));
    expect(
      restored.managedSubtitleAssets.first.kind,
      ManagedSubtitleAssetKind.ai,
    );
    expect(restored.managedSubtitleAssets.last.sourceAssetId, source.assetId);
    expect(restored.managedSubtitleAssets.last.language, 'zh-CN');
  });
}
