import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/models/video_item.dart';

void main() {
  group('MediaChapter', () {
    test(
      'normalizes ordering, missing ends, duplicate starts and duration',
      () {
        final chapters = MediaChapter.normalize(const <MediaChapter>[
          MediaChapter(title: 'Second', startMs: 10000, endMs: 99999),
          MediaChapter(title: 'Intro', startMs: 0, endMs: 0),
          MediaChapter(title: 'Duplicate', startMs: 10000, endMs: 12000),
          MediaChapter(title: 'End', startMs: 25000, endMs: 0),
        ], durationMs: 40000);

        expect(chapters.map((chapter) => chapter.title), <String>[
          'Intro',
          'Second',
          'End',
        ]);
        expect(chapters.map((chapter) => chapter.startMs), <int>[
          0,
          10000,
          25000,
        ]);
        expect(chapters.map((chapter) => chapter.endMs), <int>[
          10000,
          25000,
          40000,
        ]);
      },
    );

    test('finds current chapter at boundaries', () {
      const chapters = <MediaChapter>[
        MediaChapter(title: 'A', startMs: 0, endMs: 10000),
        MediaChapter(title: 'B', startMs: 10000, endMs: 20000),
      ];

      expect(
        MediaChapter.atPosition(
          chapters,
          const Duration(milliseconds: 9999),
        )?.title,
        'A',
      );
      expect(
        MediaChapter.atPosition(
          chapters,
          const Duration(milliseconds: 10000),
        )?.title,
        'B',
      );
      expect(
        MediaChapter.atPosition(
          chapters,
          const Duration(milliseconds: 20000),
        )?.title,
        'B',
      );
    });

    test('accepts Bilibili view point field names', () {
      final chapter = MediaChapter.fromJson(<String, dynamic>{
        'content': '开场',
        'from': 1.25,
        'to': 8.5,
        'imgUrl': '//i0.hdslb.com/chapter.jpg',
      });

      expect(chapter.title, '开场');
      expect(chapter.startMs, 1250);
      expect(chapter.endMs, 8500);
      expect(chapter.sourceThumbnailUrl, '//i0.hdslb.com/chapter.jpg');
    });
  });

  test('VideoItem persists chapter metadata', () {
    final item = VideoItem(
      id: 'chapter-card',
      path: 'C:/video.mkv',
      title: 'Chapter video',
      durationMs: 20000,
      lastUpdated: 1,
      chapters: const <MediaChapter>[
        MediaChapter(
          title: 'Intro',
          startMs: 0,
          endMs: 20000,
          sourceThumbnailUrl: 'https://example.com/intro.jpg',
        ),
      ],
      hasProbedChapters: true,
    );

    final restored = VideoItem.fromJson(item.toJson());

    expect(restored.hasProbedChapters, isTrue);
    expect(restored.chapters, hasLength(1));
    expect(restored.chapters.single.title, 'Intro');
    expect(
      restored.chapters.single.sourceThumbnailUrl,
      'https://example.com/intro.jpg',
    );
  });
}
