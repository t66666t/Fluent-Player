import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/generated_subtitle_names.dart';

void main() {
  test(
    'legacy technical suffixes display in Chinese without changing ordinary titles',
    () {
      expect(
        localizedSubtitleResultName('课程.optimized.translated.en.srt'),
        '课程.优化.翻译.英语.srt',
      );
      expect(
        localizedSubtitleResultName('My optimized course.srt'),
        'My optimized course.srt',
      );
      final original = ManagedSubtitleAsset(
        assetId: 'old',
        path: 'lesson.optimized.srt',
        kind: ManagedSubtitleAssetKind.ai,
        displayName: 'lesson.optimized.srt',
        createdAt: 1,
      );
      final media = VideoItem(
        id: 'media',
        path: 'lesson.mp4',
        title: '课程',
        durationMs: 0,
        lastUpdated: 0,
        managedSubtitleAssets: [original],
      );
      expect(subtitleManuscriptDisplayName(media, original), '［优化］课程');
      expect(original.displayName, 'lesson.optimized.srt');
      expect(original.path, 'lesson.optimized.srt');
    },
  );
  test(
    'manuscript names use the content and language, independently of a provider or file ID',
    () {
      expect(
        generatedSubtitleName(mediaTitle: '人工智能入门.mp4', version: '精校稿'),
        '［优化］人工智能入门',
      );
      expect(
        generatedSubtitleName(
          mediaTitle: '人工智能入门',
          version: subtitleTranslationManuscript('en'),
        ),
        '［英文］人工智能入门',
      );
      expect(subtitleTranslationManuscript('zh-cn'), '简体中文译稿');
      expect(subtitleTranslationManuscript('mul'), '互译稿');
      expect(
        generatedSubtitleName(
          mediaTitle: '课程',
          version: subtitleTranslationManuscript('zh-CN'),
        ),
        '［简体中文］课程',
      );
      expect(
        generatedSubtitleName(
          mediaTitle: '课程',
          version: subtitleTranslationManuscript('ja'),
        ),
        '［日文］课程',
      );
      expect(
        generatedSubtitleName(
          mediaTitle: '课程',
          version: subtitleTranslationManuscript('mul'),
        ),
        '［互译］课程',
      );
      expect(
        generatedSubtitleName(
          mediaTitle: '课程',
          version: subtitleTranslationManuscript(null),
        ),
        '［翻译］课程',
      );
    },
  );

  test(
    'previous automatic suffix names display as prefixes and retain revision numbers',
    () {
      const optimized = ManagedSubtitleAsset(
        assetId: 'optimized',
        path: 'optimized.srt',
        kind: ManagedSubtitleAssetKind.ai,
        displayName: '课程 · 精校稿 v3',
        createdAt: 1,
      );
      const translated = ManagedSubtitleAsset(
        assetId: 'translated',
        path: 'translated.srt',
        kind: ManagedSubtitleAssetKind.translated,
        displayName: '课程 · 英文译稿',
        language: 'en',
        createdAt: 2,
      );
      const custom = ManagedSubtitleAsset(
        assetId: 'custom',
        path: 'custom.srt',
        kind: ManagedSubtitleAssetKind.ai,
        displayName: '我的课堂笔记 · 精校稿',
        createdAt: 3,
      );
      final media = VideoItem(
        id: 'course',
        path: 'course.mp4',
        title: '课程',
        durationMs: 0,
        lastUpdated: 0,
        managedSubtitleAssets: [optimized, translated, custom],
      );
      final before = media.toJson();
      expect(subtitleManuscriptDisplayName(media, optimized), '［优化］课程 v3');
      expect(subtitleManuscriptDisplayName(media, translated), '［英文］课程');
      expect(subtitleManuscriptDisplayName(media, custom), custom.displayName);
      expect(media.toJson(), before);
    },
  );

  test(
    'transcription and retained originals keep their original naming without category prefixes',
    () {
      expect(
        generatedSubtitleName(mediaTitle: '课程.mp4', version: '听写稿'),
        '课程 · 听写稿',
      );
      expect(
        generatedSubtitleName(mediaTitle: '课程.mp4', version: '原稿'),
        '课程 · 原稿',
      );
      final assets = [
        const ManagedSubtitleAsset(
          assetId: 'wrong',
          path: 'transcript.srt',
          kind: ManagedSubtitleAssetKind.ai,
          displayName: '[听写]课程',
          createdAt: 1,
        ),
        const ManagedSubtitleAsset(
          assetId: 'wrong-fullwidth',
          path: 'transcript3.srt',
          kind: ManagedSubtitleAssetKind.ai,
          displayName: '［听写］课程 v3',
          createdAt: 2,
        ),
        const ManagedSubtitleAsset(
          assetId: 'legacy',
          path: 'transcript2.srt',
          kind: ManagedSubtitleAssetKind.ai,
          displayName: '课程 · 听写稿 v2',
          createdAt: 3,
        ),
        const ManagedSubtitleAsset(
          assetId: 'custom',
          path: 'custom.srt',
          kind: ManagedSubtitleAssetKind.ai,
          displayName: '［听写］我的课堂笔记',
          createdAt: 4,
        ),
      ];
      final media = VideoItem(
        id: 'course',
        path: 'course.mp4',
        title: '课程',
        durationMs: 0,
        lastUpdated: 0,
        managedSubtitleAssets: assets,
      );
      final before = media.toJson();
      expect(subtitleManuscriptDisplayName(media, assets[0]), '课程 · 听写稿');
      expect(subtitleManuscriptDisplayName(media, assets[1]), '课程 · 听写稿 v3');
      expect(subtitleManuscriptDisplayName(media, assets[2]), '课程 · 听写稿 v2');
      expect(subtitleManuscriptDisplayName(media, assets[3]), '［听写］我的课堂笔记');
      expect(media.toJson(), before);
    },
  );

  test(
    'new editions get v2 and v3 without nested operation or timestamp suffixes',
    () {
      expect(
        generatedSubtitleName(
          mediaTitle: '人工智能入门',
          version: '精校稿',
          existingNames: ['［优化］人工智能入门', '［优化］人工智能入门 v2'],
        ),
        '［优化］人工智能入门 v3',
      );
    },
  );

  test(
    'known legacy generated names render consistently while stored names and user names stay',
    () {
      const first = ManagedSubtitleAsset(
        assetId: 'first',
        path: 'old-agent-file.srt',
        kind: ManagedSubtitleAssetKind.ai,
        displayName: 'Agent 优化字幕',
        createdAt: 1,
      );
      const second = ManagedSubtitleAsset(
        assetId: 'second',
        path: 'another.srt',
        kind: ManagedSubtitleAssetKind.ai,
        displayName: '软件 优化字幕',
        createdAt: 2,
      );
      const custom = ManagedSubtitleAsset(
        assetId: 'custom',
        path: 'user.srt',
        kind: ManagedSubtitleAssetKind.manual,
        displayName: '我的课堂笔记',
        createdAt: 3,
      );
      final media = VideoItem(
        id: 'lesson',
        path: 'movie.mp4',
        title: '人工智能入门',
        durationMs: 0,
        lastUpdated: 0,
        managedSubtitleAssets: [first, second, custom],
      );
      final before = media.toJson();
      expect(subtitleManuscriptDisplayName(media, first), '［优化］人工智能入门');
      expect(subtitleManuscriptDisplayName(media, second), '［优化］人工智能入门 v2');
      expect(subtitleManuscriptDisplayName(media, custom), '我的课堂笔记');
      expect(media.toJson(), before);
      final nextName = generatedSubtitleName(
        mediaTitle: media.title,
        version: '精校稿',
        existingNames: media.managedSubtitleAssets.map(
          (a) => subtitleManuscriptDisplayName(media, a),
        ),
      );
      expect(nextName, '［优化］人工智能入门 v3');
      media.managedSubtitleAssets.add(
        ManagedSubtitleAsset(
          assetId: 'new',
          path: 'new.srt',
          kind: ManagedSubtitleAssetKind.ai,
          displayName: nextName,
          createdAt: 4,
        ),
      );
      expect(subtitleManuscriptDisplayName(media, first), '［优化］人工智能入门');
      expect(subtitleManuscriptDisplayName(media, second), '［优化］人工智能入门 v2');
    },
  );
}
