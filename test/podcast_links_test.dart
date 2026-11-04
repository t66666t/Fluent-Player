import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_links.dart';

void main() {
  for (final (width, scale) in [(320.0, 1.7), (390.0, 1.0), (1100.0, 1.0)]) {
    testWidgets('source links remain readable and copy inline at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const rss =
          'https://rss.amperwave.net/v2/feed/audacynetwork/draymond-green';
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPodcastLinks(
                  context,
                  title: '频道链接',
                  links: [
                    const PodcastLink('RSS 订阅地址', rss),
                    PodcastLink(
                      '音视频地址',
                      'https://cdn.example.com/audio.mp3?tracking=${'a' * 300}',
                    ),
                    const PodcastLink('无效来源', 'javascript:alert(1)'),
                  ],
                ),
                child: const Text('查看来源'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看来源'));
      await tester.pumpAndSettle();
      expect(find.text(rss), findsOneWidget);
      expect(find.text('无效来源'), findsNothing);
      await tester.tap(find.widgetWithText(TextButton, '复制链接').first);
      await tester.pumpAndSettle();
      expect(copied, [rss]);
      expect(find.text('已复制'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('missing source links have an explicit empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPodcastLinks(
                context,
                title: '节目链接',
                links: const [PodcastLink('空链接', '')],
              ),
              child: const Text('查看来源'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看来源'));
    await tester.pumpAndSettle();
    expect(find.text('来源没有提供公开链接。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
