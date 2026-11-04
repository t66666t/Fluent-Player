import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/bilibili_part_cover.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/media_source_ref.dart';

void main() {
  test('multipart P1 and later parts only', () {
    VideoItem item(
      int page,
      String original, {
      MediaSourceKind kind = MediaSourceKind.bilibiliStream,
    }) => VideoItem(
      id: 'a',
      path: 'bilibili://stream/BV123',
      title: 'part',
      durationMs: 1,
      lastUpdated: 0,
      sourceRef: MediaSourceRef(
        value: 'BV123',
        kind: kind,
        page: page,
        originalValue: original,
      ),
    );
    expect(
      bilibiliPartCoverPage(item(1, 'https://www.bilibili.com/video/BV123')),
      isNull,
    );
    expect(
      bilibiliPartCoverPage(
        item(1, 'https://www.bilibili.com/video/BV123?p=1'),
      ),
      1,
    );
    expect(bilibiliPartCoverPage(item(100, '')), 100);
    expect(
      bilibiliPartCoverPage(item(2, '', kind: MediaSourceKind.bilibiliBv)),
      isNull,
    );
  });
  testWidgets(
    'cover scales all geometry and handles long numbers and square slots',
    (tester) async {
      Future<Rect> mount(double width, double height, int page) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: BilibiliPartCover(identity: 'scale', page: page),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(Image), findsNothing);
        return tester.getRect(find.text(page.toString().padLeft(2, '0')));
      }

      final small = await mount(104, 58.5, 3);
      final large = await mount(416, 234, 3);
      expect(large.width / small.width, closeTo(4, .01));
      expect(large.height / small.height, closeTo(4, .01));
      for (final page in [100, 1000, 10000]) {
        final number = await mount(64, 64, page);
        expect(number.width, lessThan(64));
      }
    },
  );
  testWidgets('first entrance fades, rebuild and return do not replay', (
    tester,
  ) async {
    Widget cover({bool reduced = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: const SizedBox(
          width: 208,
          height: 117,
          child: BilibiliPartCover(identity: 'animation', page: 3),
        ),
      ),
    );
    await tester.pumpWidget(cover());
    final finder = find.descendant(
      of: find.byType(BilibiliPartCover),
      matching: find.byType(FadeTransition),
    );
    double opacity() => tester.widget<FadeTransition>(finder).opacity.value;
    expect(opacity(), 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opacity(), greaterThan(0));
    expect(opacity(), lessThan(1));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(cover());
    expect(opacity(), 1);
  });
}
