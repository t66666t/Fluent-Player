import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_layout.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/portrait_playback_layout.dart';
import 'package:video_player_app/widgets/subtitle_editor_panel.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.subtitleEditorAutoFollow = true;
  });

  tearDown(() => SettingsService().resetForTest());

  for (final size in [const Size(390, 844), const Size(360, 640)]) {
    for (final expanded in [false, true]) {
      final scale = size.height < 700 ? 1.6 : 1.0;
      testWidgets(
        'tap, IME composition and subtitle list survive editing at '
        '$size scale=$scale expanded=$expanded',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
          addTearDown(tester.view.reset);
          var subtitles = List.generate(
            12,
            (index) => SubtitleItem(
              index: index,
              startTime: Duration(seconds: index * 5),
              endTime: Duration(seconds: index * 5 + 4),
              text: '字幕 $index',
            ),
          );
          final saved = <List<SubtitleItem>>[];
          final seeks = <Duration>[];
          var currentIndex = 0;
          var position = Duration.zero;
          late StateSetter updatePlayer;

          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery.withClampedTextScaling(
                minScaleFactor: scale,
                maxScaleFactor: scale,
                child: child!,
              ),
              home: StatefulBuilder(
                builder: (context, setState) {
                  updatePlayer = setState;
                  return AiPlaybackKeyboardBoundary(
                    enabled: true,
                    child: Builder(
                      builder: (context) {
                        return Scaffold(
                          resizeToAvoidBottomInset: false,
                          body: SafeArea(
                            maintainBottomViewPadding: true,
                            child: AiKeyboardViewport(
                              reservedBottomInset: 34,
                              child: PortraitPlaybackLayout(
                                video: expanded
                                    ? null
                                    : const AspectRatio(
                                        aspectRatio: 16 / 9,
                                        child: ColoredBox(color: Colors.black),
                                      ),
                                controls: expanded
                                    ? null
                                    : const SizedBox(height: 80),
                                panel: SubtitleEditorPanel(
                                  groups: const {'字幕': 'group.srt'},
                                  activeGroupPath: 'group.srt',
                                  subtitles: subtitles,
                                  // Playback can lag behind a tapped row while
                                  // the seek and the saved edit are acknowledged.
                                  currentSubtitleIndex: currentIndex,
                                  currentPlaybackPosition: position,
                                  onSelectGroupPath: (_) async {},
                                  onCreateGroup: (_) async {},
                                  onRenameGroup: (_, _) async {},
                                  onSubtitlesChanged: (cues) async {
                                    saved.add(List.of(cues));
                                    setState(() => subtitles = List.of(cues));
                                  },
                                  onSeekTo: seeks.add,
                                  onBack: () {},
                                  isExpanded: expanded,
                                  onToggleExpanded: () {},
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          final field = find.byType(TextField);
          final list = find.byType(ScrollablePositionedList);
          // Start with a different row from the player's current subtitle.
          tester
              .widget<ScrollablePositionedList>(list)
              .itemScrollController!
              .jumpTo(index: 1);
          await tester.pumpAndSettle();
          await tester.tap(find.text('字幕 1').hitTestable());
          await tester.pumpAndSettle();
          EditableText editor() => tester.widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          );
          expect(editor().focusNode.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(editor().controller.text, '字幕 1');
          expect(seeks.last, const Duration(seconds: 5));

          const peak = 400.0;
          for (final inset in [80.0, 180.0, 320.0, peak]) {
            tester.view.viewInsets = FakeViewPadding(bottom: inset);
            tester.view.padding = const FakeViewPadding(top: 24);
            await tester.pump(const Duration(milliseconds: 16));
            final fieldRect = tester.getRect(field);
            expect(
              fieldRect.bottom,
              lessThanOrEqualTo(size.height - inset + .1),
            );
            expect(fieldRect.top, greaterThanOrEqualTo(24));
            expect(tester.getSize(list).height, greaterThan(0));
            expect(tester.takeException(), isNull);
          }

          const composing = TextEditingValue(
            text: '正在编辑字',
            selection: TextSelection.collapsed(offset: 5),
            composing: TextRange(start: 4, end: 5),
          );
          tester.testTextInput.updateEditingValue(composing);
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          updatePlayer(() => position = const Duration(seconds: 1));
          await tester.pump();
          expect(editor().controller.value, composing);
          expect(saved.last[0].text, '字幕 0');
          expect(saved.last[1].text, composing.text);

          final edited = List.filled(12, '编辑后的长字幕').join('\n');
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: edited,
              selection: TextSelection.collapsed(offset: edited.length),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pump();
          expect(editor().controller.text, edited);
          expect(saved.last[1].text, edited);
          expect(
            tester.getRect(field).bottom,
            lessThanOrEqualTo(size.height - peak + .1),
          );
          expect(tester.getSize(list).height, greaterThan(0));
          expect(tester.takeException(), isNull);

          tester.testTextInput.hide();
          for (final inset in [180.0, 80.0, 0.0]) {
            tester.view.viewInsets = FakeViewPadding(bottom: inset);
            tester.view.padding = FakeViewPadding(
              top: 24,
              bottom: inset == 0 ? 34 : 0,
            );
            await tester.pump(const Duration(milliseconds: 16));
            expect(tester.takeException(), isNull);
          }
          await tester.pumpAndSettle();
          expect(editor().controller.text, edited);
          expect(editor().focusNode.hasFocus, isFalse);
          expect(tester.getSize(list).height, greaterThan(40));
          expect(find.byType(ErrorWidget), findsNothing);
          expect(
            find
                .descendant(of: list, matching: find.text(edited))
                .hitTestable(),
            findsOneWidget,
          );
          // Playback following resumes after dismissal, without losing edits.
          updatePlayer(() {
            currentIndex = 2;
            position = const Duration(seconds: 10);
          });
          await tester.pumpAndSettle();
          expect(editor().controller.text, '字幕 2');
          expect(saved.last[1].text, edited);
          final nextRow = find
              .descendant(of: list, matching: find.text('字幕 2'))
              .hitTestable();
          expect(nextRow, findsOneWidget);
          // The restored list remains usable for the next edit.
          await tester.tap(nextRow);
          await tester.pumpAndSettle();
          expect(editor().controller.text, '字幕 2');
          expect(editor().focusNode.hasFocus, isTrue);
          expect(tester.testTextInput.isVisible, isTrue);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
        variant: TargetPlatformVariant({
          TargetPlatform.android,
          TargetPlatform.iOS,
        }),
      );
    }
  }

  testWidgets('a collapsed list restores the edited row when space returns', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    var panelHeight = 480.0;
    var subtitles = List.generate(
      40,
      (index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 5),
        endTime: Duration(seconds: index * 5 + 4),
        text: '保留的字幕 $index',
      ),
    );
    late StateSetter resizePanel;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              resizePanel = setState;
              return Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  height: panelHeight,
                  child: SubtitleEditorPanel(
                    groups: const {'字幕': 'group.srt'},
                    activeGroupPath: 'group.srt',
                    subtitles: subtitles,
                    currentSubtitleIndex: 18,
                    currentPlaybackPosition: const Duration(seconds: 90),
                    onSelectGroupPath: (_) async {},
                    onCreateGroup: (_) async {},
                    onRenameGroup: (_, _) async {},
                    onSubtitlesChanged: (cues) async {
                      setState(() => subtitles = List.of(cues));
                    },
                    onSeekTo: (_) {},
                    onBack: () {},
                    isExpanded: false,
                    onToggleExpanded: () {},
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byType(ScrollablePositionedList);
    await tester.tap(
      find.descendant(of: list, matching: find.text('保留的字幕 18')).hitTestable(),
    );
    await tester.pumpAndSettle();

    // Simulate a transient near-zero list viewport during panel/IME relayout.
    resizePanel(() => panelHeight = 64);
    await tester.pump();
    expect(list, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), '恢复后保留的编辑');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(subtitles[18].text, '恢复后保留的编辑');
    expect(tester.takeException(), isNull);

    resizePanel(() => panelHeight = 480);
    await tester.pumpAndSettle();
    expect(list, findsOneWidget);
    expect(
      find.descendant(of: list, matching: find.text('恢复后保留的编辑')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
