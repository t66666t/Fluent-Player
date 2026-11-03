import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

import 'support/subtitle_alignment_fixture.dart';

SubtitleItem _cue(int index, int startMs, int endMs, String text) =>
    SubtitleItem(
      index: index,
      startTime: Duration(milliseconds: startMs),
      endTime: Duration(milliseconds: endMs),
      text: text,
    );

Future<void> _pumpLyrics(
  WidgetTester tester,
  List<SubtitleItem> primary,
  List<SubtitleItem> secondary,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MusicLyricView(
          subtitles: primary,
          secondarySubtitles: secondary,
          isPlaying: false,
          applyEdgeFade: false,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('music lyrics share merged translation on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final chinese = loadAlignmentLyrics('zh');
        final english = loadAlignmentLyrics('en');
        await _pumpLyrics(tester, chinese.sublist(6, 9), [english[5]]);

        for (int row = 0; row < 3; row++) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey('music-lyric-row-scale-$row')),
              matching: find.text(english[5].text),
            ),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('music lyrics display every translated fragment in order', (
    tester,
  ) async {
    final chinese = loadAlignmentLyrics('zh');
    final english = loadAlignmentLyrics('en');
    await _pumpLyrics(tester, [english[2]], chinese.sublist(2, 4));
    expect(find.text('${chinese[2].text}\n${chinese[3].text}'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final changePrimary in [true, false]) {
    testWidgets(
      'music alignment refreshes when only the ${changePrimary ? 'primary' : 'secondary'} end changes',
      (tester) async {
        final primary = [
          _cue(
            0,
            changePrimary ? 0 : 2000,
            changePrimary ? 1000 : 4000,
            'Main',
          ),
        ];
        final secondary = [
          _cue(
            0,
            changePrimary ? 2000 : 0,
            changePrimary ? 3000 : 1000,
            'Translation',
          ),
        ];
        await _pumpLyrics(tester, primary, secondary);
        Finder mainRowTranslation() => find.descendant(
          of: find.ancestor(
            of: find.text('Main'),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget.key is ValueKey<String> &&
                  (widget.key! as ValueKey<String>).value.startsWith(
                    'music-lyric-row-scale-',
                  ),
            ),
          ),
          matching: find.text('Translation'),
        );
        // Unmatched secondary cues remain visible in their own group. Only
        // attachment to Main should change when an interval end is edited.
        expect(mainRowTranslation(), findsNothing);

        await _pumpLyrics(
          tester,
          changePrimary ? [_cue(0, 0, 4000, 'Main')] : primary,
          changePrimary ? secondary : [_cue(0, 0, 4000, 'Translation')],
        );
        expect(mainRowTranslation(), findsOneWidget);

        // Track removal must clear the cached translation as well.
        await _pumpLyrics(tester, primary, []);
        expect(find.text('Translation'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final mode in [
    (name: 'list', article: false, paragraph: true),
    (name: 'paragraph article', article: true, paragraph: true),
    (name: 'continuous article', article: true, paragraph: false),
  ]) {
    testWidgets('real bilingual ${mode.name} copies the correct pairs', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': false,
        'subtitleViewMode': mode.article ? 1 : 0,
        'subtitleArticleParagraphModeEnabled': mode.paragraph,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final chinese = loadAlignmentLyrics('zh');
      final english = loadAlignmentLyrics('en');
      final key = GlobalKey<SubtitleSidebarState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 550,
              child: SubtitleSidebar(
                key: key,
                subtitles: chinese,
                secondarySubtitles: english,
                isCompact: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final expected = [
        for (int i = 0; i < chinese.length; i++)
          '${chinese[i].text} ${english[expectedEnglishIndices[i]].text}',
      ].join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      try {
        expect(
          key.currentState!.handleTranscriptShortcut(
            const KeyDownEvent(
              logicalKey: LogicalKeyboardKey.keyA,
              physicalKey: PhysicalKeyboardKey.keyA,
              timeStamp: Duration.zero,
            ),
          ),
          KeyEventResult.handled,
        );
        expect(key.currentState!.selectedTranscriptText, expected);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
    });
  }

  testWidgets('a partially translated transcript shows its valid translation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': false,
      'subtitleViewMode': 0,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubtitleSidebar(
            subtitles: List.generate(
              10,
              (i) => _cue(i, i * 2000, i * 2000 + 1000, 'Main $i'),
            ),
            secondarySubtitles: [_cue(0, 0, 1000, 'Only translated cue')],
            isCompact: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Main 0 Only translated cue'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
