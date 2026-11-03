import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_article.dart';
import 'package:video_player_app/features/podcasts/podcast_feed_parser.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';

void main() {
  const showNotes = '''
《十字路口》播客节目简介
本节目是一档由罗永浩主持的深度播客类节目。
本期嘉宾：手工耿
【你将听到】
00:01:56 手工赠礼
00:25:09 童年三件套
03:22:37 - 外号大赏
❤️参与录制：
公众号关注「罗永浩的十字路口」。
''';

  test('show notes keep the publisher line breaks', () {
    final lines = podcastArticleLines(showNotes);
    expect(lines.map((line) => line.kind), [
      PodcastArticleKind.prose,
      PodcastArticleKind.prose,
      PodcastArticleKind.prose,
      PodcastArticleKind.heading,
      PodcastArticleKind.cue,
      PodcastArticleKind.cue,
      PodcastArticleKind.cue,
      PodcastArticleKind.heading,
      PodcastArticleKind.prose,
    ]);
    expect(lines[4].time, '00:01:56');
    expect(lines[4].text, '手工赠礼');
    expect(lines[6].time, '03:22:37');
    expect(lines[6].text, '外号大赏');
    expect(
      podcastPlainText(showNotes),
      contains('00:01:56 手工赠礼 00:25:09 童年三件套'),
    );
  });

  test('html blocks become paragraphs and a timestamp stays on its own line', () {
    const source =
        '<p>甲</p><p>乙<br>00:01:56 丙</p><ul><li>丁</li><li>戊</li></ul><div>00:02:00己</div>';
    expect(
      podcastArticleText(source),
      '甲\n\n乙\n00:01:56 丙\n\n• 丁\n• 戊\n\n00:02:00己',
    );
    final lines = podcastArticleLines(source);
    expect(lines[2].kind, PodcastArticleKind.cue);
    expect(lines[2].text, '丙');
    // A clock directly followed by a Chinese title remains seekable.
    expect(lines.last.kind, PodcastArticleKind.cue);
    expect(lines.last.time, '00:02:00');
    expect(lines.last.text, '己');
  });

  test('publisher brackets and clock separators retain valid seek targets', () {
    for (final (source, clock, text) in [
      (
        '[00:02:18] 9个月、三次转型：SuperDesign、增长 Agent 与 Treg',
        '00:02:18',
        '9个月、三次转型：SuperDesign、增长 Agent 与 Treg',
      ),
      (
        '[00:03:10] 从周末项目到 6000+ GitHub Star',
        '00:03:10',
        '从周末项目到 6000+ GitHub Star',
      ),
      ('［00:04:59］模型吞噬应用', '00:04:59', '模型吞噬应用'),
      ('（00：06：59）「0人公司」的创业浪潮', '00：06：59', '「0人公司」的创业浪潮'),
      ('(14:42) - 一个 Codex 插件', '14:42', '一个 Codex 插件'),
      ('【00:17:36】从增长 Agent 中拆出最有价值的一层', '00:17:36', '从增长 Agent 中拆出最有价值的一层'),
      ('• [00:18:04] Agent 最常买什么工具？', '00:18:04', 'Agent 最常买什么工具？'),
      ('1. [00:02:18] 第一章', '00:02:18', '第一章'),
      ('90:00—继续收听', '90:00', '继续收听'),
      ('[00:00:00]', '00:00:00', ''),
      ('<p><a href="#t=138">[00:02:18]</a>&nbsp;创业故事</p>', '00:02:18', '创业故事'),
    ]) {
      final line = podcastArticleLines(source).single;
      expect(line.kind, PodcastArticleKind.cue, reason: source);
      expect(line.time, clock, reason: source);
      expect(line.text, text, reason: source);
    }
    expect(podcastDuration('00：02：18'), 138000);
    expect(podcastDuration('90:00'), 5400000);
  });

  test('invalid or partial clocks stay ordinary article text', () {
    for (final source in [
      '[00:99:00] 无效分钟',
      '[00:02:99] 无效秒数',
      '12:345 无效时间',
      '00:02:18:20 多余字段',
      '[00:02:18) 不匹配的括号',
      '00:02:18.123 小数',
      '2026:10 年月',
      'https://example.com/00:02:18',
    ]) {
      expect(
        podcastArticleLines(source).single.kind,
        PodcastArticleKind.prose,
        reason: source,
      );
    }
  });

  testWidgets(
    'timestamp outline is a column and seeks with the published clock',
    (tester) async {
      String? jumped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              child: PodcastArticleView(
                source: showNotes,
                onSeek: (clock) => jumped = clock,
              ),
            ),
          ),
        ),
      );
      expect(find.text('00:01:56手工赠礼'), findsNothing);
      expect(find.text('00:01:56'), findsOneWidget);
      expect(find.text('手工赠礼'), findsOneWidget);
      final prose = tester.widget<Text>(find.textContaining('深度播客'));
      expect(prose.style?.fontFamily, 'Noto Sans SC');
      expect(prose.style?.fontWeight, FontWeight.w400);
      final headingText = tester.widget<Text>(find.text('【你将听到】'));
      expect(headingText.style?.fontFamily, 'Noto Sans SC');
      expect(headingText.style?.fontWeight, FontWeight.w700);
      final clock = tester.widget<Text>(find.text('00:01:56'));
      expect(clock.style?.fontFamily, 'Inter');
      expect(clock.style?.fontWeight, FontWeight.w500);
      expect(clock.style?.decoration, TextDecoration.underline);
      expect(clock.style?.color, PodcastArticleView.seekColor);
      expect(find.text('点击时间或条目跳转播放'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline_rounded), findsNWidgets(3));
      expect(find.text('【你将听到】'), findsOneWidget);
      final firstProse = tester.getTopLeft(find.textContaining('深度播客'));
      final secondProse = tester.getTopLeft(find.text('本期嘉宾：手工耿'));
      final heading = tester.getTopLeft(find.text('【你将听到】'));
      final giftTime = tester.getTopLeft(find.text('00:01:56'));
      final giftTitle = tester.getTopLeft(find.text('手工赠礼'));
      final nextTime = tester.getTopLeft(find.text('00:25:09'));
      final nextTitle = tester.getTopLeft(find.text('童年三件套'));
      expect(secondProse.dy - firstProse.dy, greaterThan(24));
      expect(heading.dy, greaterThan(secondProse.dy));
      expect(giftTitle.dx, greaterThan(giftTime.dx + 60));
      expect(nextTime.dx, giftTime.dx);
      expect(nextTitle.dx, giftTitle.dx);
      expect(nextTime.dy - giftTime.dy, greaterThanOrEqualTo(48));
      await tester.tap(find.text('童年三件套'));
      expect(jumped, '00:25:09');
      expect(podcastDuration('00:25:09'), 1509000);
    },
  );

  testWidgets(
    'cue feedback is visible during and after a tap on opaque surfaces',
    (tester) async {
      final boundaryKey = GlobalKey();
      var seeks = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appInteractionTheme(ThemeData.dark()),
          home: Scaffold(
            body: Container(
              color: const Color(0xFF151515),
              child: RepaintBoundary(
                key: boundaryKey,
                child: PodcastArticleView(
                  source: '00:01:56 手工赠礼',
                  onSeek: (_) => seeks++,
                ),
              ),
            ),
          ),
        ),
      );
      Future<List<int>?> pixels() => tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData();
        final bytes = data!.buffer.asUint8List().toList();
        image.dispose();
        return bytes;
      });

      await tester.pumpAndSettle();
      final idle = await pixels();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('手工赠礼')),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(await pixels(), isNot(orderedEquals(idle!)));
      expect(seeks, 0);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 80));
      expect(seeks, 1);
      expect(await pixels(), isNot(orderedEquals(idle)));
      await tester.pumpAndSettle();
      expect(await pixels(), orderedEquals(idle));
    },
  );

  for (final (width, scale) in [
    (220.0, 1.8),
    (320.0, 1.8),
    (390.0, 1.0),
    (768.0, 1.3),
    (1440.0, 1.0),
  ]) {
    testWidgets(
      'bracketed show notes remain visible and seekable at $width scale=$scale',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final jumped = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 420,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: PodcastArticleView(
                      source:
                          '[00:02:18] 9个月、三次转型：SuperDesign、增长 Agent 与 Treg\n[00:03:10] 从周末项目到 6000+ GitHub Star',
                      onSeek: jumped.add,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final clock = find.text('00:02:18');
        expect(tester.widget<Text>(clock).maxLines, 1);
        expect(
          tester.widget<Text>(clock).style?.decoration,
          TextDecoration.underline,
        );
        expect(
          find.byKey(const ValueKey('podcast-timestamp-hint')),
          findsOneWidget,
        );
        await tester.tap(clock);
        expect(jumped, ['00:02:18']);
        await tester.ensureVisible(find.text('从周末项目到 6000+ GitHub Star'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('从周末项目到 6000+ GitHub Star'));
        expect(jumped, ['00:02:18', '00:03:10']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('unavailable cues remain plain text', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: PodcastArticleView(source: '00:01:56 手工赠礼')),
      ),
    );
    expect(find.byType(InkWell), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline_rounded), findsNothing);
    expect(find.byKey(const ValueKey('podcast-timestamp-hint')), findsNothing);
    expect(
      tester.widget<Text>(find.text('00:01:56')).style?.decoration,
      isNull,
    );
  });
}
