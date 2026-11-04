import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/subtitle_display_resolver.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

SubtitleItem _cue(int index, int startMs, int endMs, String text) =>
    SubtitleItem(
      index: index,
      startTime: Duration(milliseconds: startMs),
      endTime: Duration(milliseconds: endMs),
      text: text,
    );

// The reported OCR tracks have 139 Chinese / 141 English cues. At this point
// primary cue 39 pairs with secondary cue 41, with the same 170.7–174.1 s span.
// Keep only the timing pattern and synthetic text; no user subtitle files.
List<SubtitleItem> get _primary => [
  _cue(1, 0, 1000, 'Main intro'),
  _cue(39, 170700, 174100, 'Main example'),
  _cue(40, 174100, 175600, 'Main curves'),
];
List<SubtitleItem> get _secondary => [
  _cue(1, 0, 1000, 'Translation intro'),
  _cue(39, 163000, 167500, 'Previous translation'),
  _cue(40, 167500, 169800, 'Origin translation'),
  _cue(41, 170700, 174100, 'Translation example'),
  _cue(42, 174100, 175600, 'Translation curves'),
];

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 18; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<String> _selectAll(
  WidgetTester tester,
  GlobalKey<SubtitleSidebarState> key,
) async {
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
    await tester.pump();
    return key.currentState!.selectedTranscriptText;
  } finally {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
}

void main() {
  const primaryFile = String.fromEnvironment('SUBTITLE_ALIGNMENT_PRIMARY');
  const secondaryFile = String.fromEnvironment('SUBTITLE_ALIGNMENT_SECONDARY');
  for (final mode in ['list', 'paragraph', 'continuous']) {
    testWidgets(
      'external OCR tracks keep the same pairing after every streamed batch: $mode',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': false,
          'subtitleViewMode': mode == 'list' ? 0 : 1,
          'subtitleArticleParagraphModeEnabled': mode == 'paragraph',
        });
        await (SettingsService()..resetForTest()).init();
        final source = SubtitleParser.parseSrt(
          File(primaryFile).readAsStringSync(),
        );
        final translated = SubtitleParser.parseSrt(
          File(secondaryFile).readAsStringSync(),
        );
        final primary = SubtitleCueBuffer(), secondary = SubtitleCueBuffer();
        final key = GlobalKey<SubtitleSidebarState>();
        var addedPrimary = 0, addedSecondary = 0;
        for (var batch = 1; batch <= 6; batch++) {
          final throughPrimary = (source.length * batch / 6).ceil();
          final throughSecondary = (translated.length * batch / 6).ceil();
          primary.addAll(source.sublist(addedPrimary, throughPrimary));
          secondary.addAll(
            translated.sublist(addedSecondary, throughSecondary),
          );
          addedPrimary = throughPrimary;
          addedSecondary = throughSecondary;
          final a = primary.snapshot, b = secondary.snapshot;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 500,
                  height: 550,
                  child: SubtitleSidebar(
                    key: key,
                    subtitles: a,
                    secondarySubtitles: b,
                    isCompact: true,
                  ),
                ),
              ),
            ),
          );
          await _frames(tester);
          final matches = matchSubtitleTracks(
            primarySubtitles: a,
            secondarySubtitles: b,
          );
          final expected = [
            for (var i = 0; i < a.length; i++)
              '${a[i].text} ${matches.secondaryTextForPrimary(i, b)}',
          ].join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
          expect(
            await _selectAll(tester, key),
            expected,
            reason: 'batch $batch',
          );
          key.currentState!.clearTextSelection();
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: primaryFile.isEmpty || secondaryFile.isEmpty,
    );
  }
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final mode in ['list', 'paragraph', 'continuous']) {
      for (final growth in [
        'both',
        'primary',
        'secondary',
        'late match',
        'equal counts',
        'selection',
      ]) {
        testWidgets(
          'sidebar aligns independent streamed tracks: $platform $mode $growth',
          (tester) async {
            debugDefaultTargetPlatformOverride = platform;
            try {
              SharedPreferences.setMockInitialValues({
                'autoScrollSubtitles': false,
                'subtitleViewMode': mode == 'list' ? 0 : 1,
                'subtitleArticleParagraphModeEnabled': mode == 'paragraph',
              });
              await (SettingsService()..resetForTest()).init();
              final primary = SubtitleCueBuffer();
              final secondary = SubtitleCueBuffer();
              final inputs = growth == 'selection'
                  ? [
                      ..._primary.take(2),
                      _cue(99, 170700, 174100, 'Main repeated'),
                    ]
                  : _primary;
              final translations =
                  growth == 'selection' || growth == 'equal counts'
                  ? [_secondary[0], _secondary[1], _secondary[3]]
                  : _secondary;
              final firstPrimary = growth == 'secondary'
                  ? inputs.length
                  : growth == 'late match'
                  ? 2
                  : 1;
              final firstSecondary = growth == 'primary'
                  ? translations.length
                  : 1;
              primary.addAll(inputs.take(firstPrimary));
              secondary.addAll(translations.take(firstSecondary));
              final key = GlobalKey<SubtitleSidebarState>();
              Future<void> show() => tester.pumpWidget(
                MaterialApp(
                  home: Scaffold(
                    body: SizedBox(
                      width: platform == TargetPlatform.android ? 360 : 500,
                      height: 550,
                      child: SubtitleSidebar(
                        key: key,
                        subtitles: primary.snapshot,
                        secondarySubtitles: secondary.snapshot,
                        isCompact: true,
                      ),
                    ),
                  ),
                ),
              );
              await show();
              await _frames(tester);
              if (growth == 'selection') {
                final selected = await _selectAll(tester, key);
                primary.addAll([inputs[1]]);
                secondary.addAll(translations.skip(firstSecondary));
                await show();
                await _frames(tester);
                expect(key.currentState!.selectedTranscriptText, selected);
                // The next batch reaches equal counts and matching suffix
                // timestamps. Its unrefreshed prefix must still stay frozen.
                primary.addAll([inputs[2]]);
                await show();
                await _frames(tester);
                expect(key.currentState!.hasTextSelection, isTrue);
                expect(key.currentState!.selectedTranscriptText, selected);
                key.currentState!.clearTextSelection();
              } else {
                primary.addAll(inputs.skip(firstPrimary));
                secondary.addAll(translations.skip(firstSecondary));
              }
              await show();
              await _frames(tester);
              final text = await _selectAll(tester, key);
              expect(text, contains('Main example Translation example'));
              if (growth == 'selection') {
                expect(text, contains('Main repeated Translation example'));
              } else if (growth == 'equal counts') {
                expect(text, contains('Main curves'));
                expect(
                  text,
                  isNot(contains('Main curves Translation example')),
                );
              } else {
                expect(text, contains('Main curves Translation curves'));
              }
              expect(text, isNot(contains('Previous translation')));
              expect(text, isNot(contains('Origin translation')));
              expect(tester.takeException(), isNull);
              await tester.pumpWidget(const SizedBox.shrink());
            } finally {
              debugDefaultTargetPlatformOverride = null;
            }
          },
        );
      }
    }
  }
}
