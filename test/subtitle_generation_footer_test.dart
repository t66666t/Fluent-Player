import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/music_lyric_region.dart';
import 'package:video_player_app/widgets/music_lyric_selection_pane.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/subtitle_generation_footer.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

class _Manager extends TranscriptionManager {
  SubtitleStreamUpdate? latest;
  bool running = true, stopping = false;
  Duration total = const Duration(minutes: 12);
  Duration done = const Duration(minutes: 3, seconds: 24);

  @override
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId}) =>
      latest?.videoPath == path &&
          (videoId == null || latest?.videoId == videoId)
      ? latest
      : null;
  @override
  bool isVideoRunning(String path, {String? videoId}) =>
      running && streamForVideo(path, videoId: videoId) != null;
  @override
  bool isVideoStopping(String path, {String? videoId}) => stopping;
  @override
  TranscriptionAudioProgress get localAudioProgress =>
      TranscriptionAudioProgress(completed: done, total: total);

  void changed({bool revisionOnly = false}) {
    if (revisionOnly) {
      subtitleFilesRevision.value++;
    } else {
      notifyListeners();
    }
  }
}

List<SubtitleItem> cues(int count) => [
  for (var i = 0; i < count; i++)
    SubtitleItem(
      index: i + 1,
      startTime: Duration(seconds: i * 5),
      endTime: Duration(seconds: i * 5 + 4),
      text: 'A quiet line of lyrics ${i + 1}.',
    ),
];

Future<void> frames(WidgetTester tester, [int count = 12]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const previews = bool.fromEnvironment('SUBTITLE_GENERATION_PREVIEWS');
  late _Manager manager;
  late MediaPlaybackService playback;
  late SubtitleCueBuffer primary, secondary;
  final settings = SettingsService();

  setUpAll(() async {
    if (previews) {
      for (final entry in {
        'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
        'Inter': 'assets/fonts/Inter-ExtraBold.otf',
        'MiSans': 'assets/fonts/MiSans-Regular.otf',
      }.entries) {
        final font = FontLoader(entry.key)
          ..addFont(rootBundle.load(entry.value));
        await font.load();
      }
    }
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({'autoScrollSubtitles': false});
    settings.resetForTest();
    await settings.init();
    manager = _Manager();
    playback = MediaPlaybackService.forTesting();
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'media',
        path: '/media.mp4',
        title: 'Media',
        durationMs: 720000,
        lastUpdated: 0,
      ),
    );
    primary = SubtitleCueBuffer()..addAll(cues(2));
    secondary = SubtitleCueBuffer()
      ..addAll(
        cues(2).map((cue) => cue.copyWith(text: '一行正在生成的译文 ${cue.index}。')),
      );
  });
  tearDown(() {
    playback.dispose();
    manager.dispose();
    settings.resetForTest();
  });

  SubtitleStreamUpdate update({
    SubtitleStreamPhase phase = SubtitleStreamPhase.generating,
    bool translate = true,
    String generation = 'generation',
  }) => SubtitleStreamUpdate(
    generationId: generation,
    mediaKey: 'id:media',
    videoId: 'media',
    videoPath: '/media.mp4',
    revision: primary.snapshot.length,
    primaryPath: '/$generation.source.srt',
    secondaryPath: translate ? '/$generation.translation.srt' : null,
    primary: primary.snapshot,
    secondary: secondary.snapshot,
    addedPrimary: const [],
    addedSecondary: const [],
    primaryBytes: 100,
    secondaryBytes: translate ? 100 : 0,
    processedThrough: manager.done,
    phase: phase,
  );

  void selectGenerated({bool translate = true}) {
    manager.latest = update(translate: translate);
    playback.setSubtitleState(
      paths: manager.latest!.paths,
      primary: primary.snapshot,
      secondary: translate ? secondary.snapshot : const [],
    );
  }

  Widget app(Widget body, {TargetPlatform platform = TargetPlatform.windows}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider<TranscriptionManager>.value(value: manager),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            platform: platform,
            fontFamily: previews ? 'Noto Sans SC' : null,
          ),
          home: Scaffold(body: body),
        ),
      );

  Widget footer({bool showPrimary = true, bool showSecondary = true}) =>
      SubtitleGenerationFooter(
        primary: playback.subtitles,
        secondary: playback.secondarySubtitles,
        showPrimary: showPrimary,
        showSecondary: showSecondary,
      );

  testWidgets(
    'updates only the hint, and terminal phases remove it without moving text',
    (tester) async {
      selectGenerated();
      var builds = 0;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) {
              builds++;
              return Column(
                children: [const Text('Last published subtitle'), footer()],
              );
            },
          ),
        ),
      );
      final tail = find.byType(SubtitleGenerationFooter);
      final initial = tester.getRect(tail);
      expect(find.text('正在转录并翻译 · 03:24 / 12:00'), findsOneWidget);
      final parentBuilds = builds;
      manager.done = const Duration(minutes: 4, seconds: 10);
      manager.changed();
      await tester.pump();
      expect(find.text('正在转录并翻译 · 04:10 / 12:00'), findsOneWidget);
      expect(builds, parentBuilds);
      expect(tester.getRect(tail), initial);
      for (final phase in [
        SubtitleStreamPhase.complete,
        SubtitleStreamPhase.failed,
        SubtitleStreamPhase.paused,
        SubtitleStreamPhase.stopping,
      ]) {
        manager.latest = update(phase: phase);
        manager.changed(revisionOnly: true);
        await tester.pump();
        expect(find.textContaining('正在转录'), findsNothing);
        expect(tester.getRect(tail), initial);
      }
      manager.latest = update();
      manager.changed();
      await tester.pump();
      expect(find.textContaining('正在转录并翻译'), findsOneWidget);
      manager.running = false;
      manager.changed();
      await tester.pump();
      expect(find.textContaining('正在转录'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual file selection hides the hint, selecting the live file restores it',
    (tester) async {
      selectGenerated(translate: false);
      await tester.pumpWidget(app(footer()));
      expect(find.text('正在转录 · 03:24 / 12:00'), findsOneWidget);
      playback.setSubtitleState(
        paths: ['/manual.srt'],
        primary: cues(2),
        secondary: [],
      );
      await tester.pump();
      expect(find.textContaining('正在转录'), findsNothing);
      selectGenerated(translate: false);
      await tester.pump();
      expect(find.textContaining('正在转录 ·'), findsOneWidget);
      manager.latest = update(translate: false, generation: 'new-generation');
      manager.changed();
      await tester.pump();
      expect(find.textContaining('正在转录'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('only the visible lyric role contributes a generation hint', (
    tester,
  ) async {
    selectGenerated();
    playback.setSubtitleState(
      paths: ['/manual.srt', manager.latest!.secondaryPath!],
      primary: cues(2),
      secondary: secondary.snapshot,
    );
    await tester.pumpWidget(app(footer(showSecondary: false)));
    expect(find.textContaining('正在转录'), findsNothing);
    await tester.pumpWidget(app(footer(showPrimary: false)));
    expect(find.textContaining('正在转录并翻译'), findsOneWidget);
    manager.total = const Duration(hours: 1, minutes: 12);
    manager.changed();
    await tester.pump();
    expect(find.text('正在转录并翻译 · 00:03:24 / 01:12:00'), findsOneWidget);
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'other',
        path: '/other.mp4',
        title: 'Other',
        durationMs: 10000,
        lastUpdated: 0,
      ),
    );
    manager.changed();
    await tester.pump();
    expect(find.textContaining('正在转录'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final mode in [0, 1, 2]) {
    testWidgets('transcript footer follows the last cue in mode $mode', (
      tester,
    ) async {
      await settings.updateSetting('subtitleViewMode', mode == 0 ? 0 : 1);
      await settings.updateSetting(
        'subtitleArticleParagraphModeEnabled',
        mode == 2,
      );
      selectGenerated();
      await tester.pumpWidget(
        app(
          SizedBox(
            width: 380,
            height: 600,
            child: SubtitleSidebar(
              subtitles: primary.snapshot,
              secondarySubtitles: secondary.snapshot,
              isCompact: true,
              isPortrait: true,
            ),
          ),
        ),
      );
      await frames(tester, 18);
      expect(find.textContaining('正在转录并翻译'), findsOneWidget);
      final hint = tester.getRect(find.byType(SubtitleGenerationFooter));
      final list = find.byType(ScrollablePositionedList);
      final contentHeight = tester.getSize(list).height;
      expect(
        hint.top,
        greaterThan(tester.getTopLeft(find.byType(SubtitleSidebar)).dy + 40),
      );
      expect(tester.takeException(), isNull);
      manager.latest = update(phase: SubtitleStreamPhase.complete);
      manager.changed(revisionOnly: true);
      await frames(tester);
      expect(find.textContaining('正在转录'), findsNothing);
      expect(
        tester.getSize(list).height,
        closeTo(contentHeight - SubtitleGenerationFooter.extent, .1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final paragraphMode in [true, false]) {
    testWidgets(
      'finished hint lets a nearly fitting article return to the top, '
      'paragraph=$paragraphMode',
      (tester) async {
        await settings.updateSetting('subtitleViewMode', 1);
        await settings.updateSetting(
          'subtitleArticleParagraphModeEnabled',
          paragraphMode,
        );
        selectGenerated();
        Future<void> show(double height) => tester.pumpWidget(
          app(
            SizedBox(
              width: 380,
              height: height,
              child: SubtitleSidebar(
                subtitles: primary.snapshot,
                secondarySubtitles: secondary.snapshot,
                isCompact: true,
                isPortrait: true,
              ),
            ),
          ),
        );
        await show(600);
        await frames(tester);
        final list = find.byType(ScrollablePositionedList);
        final contentHeight = tester.getSize(list).height;
        final toolbarHeight = tester
            .getSize(find.byKey(const ValueKey('subtitle-toolbar')))
            .height;
        await show(toolbarHeight + contentHeight - 24);
        await frames(tester);
        ScrollPosition position() => tester
            .state<ScrollableState>(
              find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        expect(
          position().maxScrollExtent - position().minScrollExtent,
          greaterThan(0),
        );
        position().jumpTo(position().maxScrollExtent);
        await frames(tester);
        manager.latest = update(phase: SubtitleStreamPhase.complete);
        manager.changed(revisionOnly: true);
        await frames(tester);
        expect(
          position().maxScrollExtent - position().minScrollExtent,
          closeTo(0, .1),
        );
        final itemPositions = tester
            .widget<ScrollablePositionedList>(list)
            .itemPositionsNotifier!
            .itemPositions
            .value;
        expect(itemPositions.any((item) => item.index == 0), isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'selection reclaims the finished hint without moving the selected text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      selectGenerated();
      await tester.pumpWidget(
        app(
          MusicLyricRegion(
            mediaId: 'media',
            subtitles: primary.snapshot,
            secondarySubtitles: secondary.snapshot,
            splitSubtitleByLine: false,
            preference: MusicLyricTrackDisplayMode.both,
            onPreferenceChanged: (_) {},
            isPlaying: false,
            applyEdgeFade: false,
          ),
          platform: TargetPlatform.android,
        ),
      );
      await frames(tester, 18);
      await tester.longPress(find.text('A quiet line of lyrics 1.'));
      await frames(tester);
      expect(find.byType(MusicLyricSelectionPane), findsOneWidget);
      final editable = find.byType(EditableText);
      final controller = tester.widget<EditableText>(editable).controller;
      final selection = controller.selection;
      final document = controller.text;
      final rectangle = tester.getRect(editable);
      final render = tester.state<EditableTextState>(editable).renderEditable;
      Offset selectedTextPosition() => render.localToGlobal(
        render.getEndpointsForSelection(selection).first.point,
      );
      final selectedPosition = selectedTextPosition();
      manager.done = const Duration(minutes: 8);
      manager.changed();
      await tester.pump();
      expect(find.text('正在转录并翻译 · 08:00 / 12:00'), findsOneWidget);
      expect(controller.text, document);
      expect(controller.selection, selection);
      expect(tester.getRect(editable), rectangle);
      manager.latest = update(phase: SubtitleStreamPhase.complete);
      manager.changed(revisionOnly: true);
      await tester.pump();
      expect(find.textContaining('正在转录'), findsNothing);
      expect(controller.selection, selection);
      final expanded = tester.getRect(editable);
      expect(expanded.topLeft, rectangle.topLeft);
      expect(expanded.width, rectangle.width);
      expect(
        expanded.height,
        rectangle.height + SubtitleGenerationFooter.extent,
      );
      expect(selectedTextPosition(), selectedPosition);
      expect(tester.getSize(find.byType(SubtitleGenerationFooter)).height, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selection text reaches the actions when no generation is active',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      primary = SubtitleCueBuffer()..addAll(cues(60));
      playback.setSubtitles(primary.snapshot);
      await tester.pumpWidget(
        app(
          MusicLyricRegion(
            mediaId: 'media',
            subtitles: primary.snapshot,
            secondarySubtitles: const [],
            splitSubtitleByLine: false,
            preference: MusicLyricTrackDisplayMode.both,
            onPreferenceChanged: (_) {},
            isPlaying: false,
            applyEdgeFade: false,
          ),
          platform: TargetPlatform.android,
        ),
      );
      await frames(tester, 18);
      final footer = find.byType(SubtitleGenerationFooter);
      await tester.longPress(find.text('A quiet line of lyrics 1.'));
      await frames(tester);
      final field = tester.getRect(find.byType(EditableText));
      final actions = tester.getRect(
        find.byKey(const ValueKey('music-lyric-selection-actions')),
      );
      expect(tester.getSize(footer).height, 0);
      expect(field.bottom, actions.top);
      expect(find.text('长按选择文字，或按句选取'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey('music-lyric-selection-done')),
      );
      await frames(tester);
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(MusicLyricView), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final platform in TargetPlatform.values.where(
    (p) => p != TargetPlatform.fuchsia,
  )) {
    for (final size in [const Size(360, 760), const Size(1000, 550)]) {
      testWidgets('music footer updates and clears in $platform/$size', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        selectGenerated();
        final clock = ValueNotifier(Duration.zero);
        addTearDown(clock.dispose);
        final capture = GlobalKey();
        final regionKey = GlobalKey<MusicLyricRegionState>();
        await tester.pumpWidget(
          app(
            RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: const Color(0xFF282E3A),
                child: MusicLyricRegion(
                  key: regionKey,
                  mediaId: 'media',
                  subtitles: primary.snapshot,
                  secondarySubtitles: secondary.snapshot,
                  splitSubtitleByLine: false,
                  preference: MusicLyricTrackDisplayMode.both,
                  onPreferenceChanged: (_) {},
                  positionListenable: clock,
                  isPlaying: false,
                  applyEdgeFade: false,
                ),
              ),
            ),
            platform: platform,
          ),
        );
        await frames(tester, 18);
        expect(find.textContaining('正在转录并翻译'), findsOneWidget);
        final lyricState = tester.state(find.byType(MusicLyricView));
        final cue = find.text('A quiet line of lyrics 1.');
        final before = tester.getTopLeft(cue);
        manager.done = const Duration(minutes: 5);
        manager.changed();
        await tester.pump();
        expect(find.text('正在转录并翻译 · 05:00 / 12:00'), findsOneWidget);
        expect(tester.state(find.byType(MusicLyricView)), same(lyricState));
        expect(tester.getTopLeft(cue), before);
        if (previews && platform == TargetPlatform.android) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '.artifacts/model-center/generation-footer-${size.width < size.height ? 'portrait' : 'landscape'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        manager.latest = update(phase: SubtitleStreamPhase.complete);
        manager.changed(revisionOnly: true);
        await tester.pump();
        expect(find.textContaining('正在转录'), findsNothing);
        expect(tester.getTopLeft(cue), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  for (final view in ['list', 'article', 'continuous', 'music']) {
    for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
      testWidgets(
        'live footer keeps the reading anchor on $view/$platform append',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(420, 760));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await settings.updateSetting(
            'subtitleViewMode',
            view == 'list' ? 0 : 1,
          );
          await settings.updateSetting(
            'subtitleArticleParagraphModeEnabled',
            view == 'continuous',
          );
          primary = SubtitleCueBuffer()..addAll(cues(80));
          secondary = SubtitleCueBuffer()
            ..addAll(cues(80).map((c) => c.copyWith(text: '译文 ${c.index}')));
          final sidebarKey = GlobalKey<SubtitleSidebarState>();
          final lyricKey = GlobalKey<MusicLyricRegionState>();
          final clock = ValueNotifier(const Duration(seconds: 30));
          addTearDown(clock.dispose);
          Future<void> show() async {
            selectGenerated();
            await tester.pumpWidget(
              app(
                view == 'music'
                    ? MusicLyricRegion(
                        key: lyricKey,
                        mediaId: 'media',
                        subtitles: primary.snapshot,
                        secondarySubtitles: secondary.snapshot,
                        splitSubtitleByLine: false,
                        preference: MusicLyricTrackDisplayMode.both,
                        onPreferenceChanged: (_) {},
                        positionListenable: clock,
                        isPlaying: false,
                        applyEdgeFade: false,
                      )
                    : SubtitleSidebar(
                        key: sidebarKey,
                        subtitles: primary.snapshot,
                        secondarySubtitles: secondary.snapshot,
                        positionListenable: clock,
                        isCompact: true,
                        isPortrait: true,
                      ),
                platform: platform,
              ),
            );
          }

          await show();
          await frames(tester, 18);
          if (view != 'music') {
            sidebarKey.currentState!.jumpToFirstSubtitleTop();
            await frames(tester);
          }
          await tester.drag(
            find.byType(view == 'music' ? MusicLyricRegion : SubtitleSidebar),
            const Offset(0, -220),
          );
          await frames(tester, 6);
          final oldPositions = <int, double>{};
          final oldTexts = <String, Offset>{};
          if (view == 'music') {
            for (final cue in primary.snapshot) {
              final text = find.text(cue.text);
              if (text.evaluate().isNotEmpty) {
                oldTexts[cue.text] = tester.getTopLeft(text.first);
              }
            }
            expect(oldTexts, isNotEmpty);
          } else {
            final list = tester.widget<ScrollablePositionedList>(
              find.byType(ScrollablePositionedList),
            );
            for (final p in list.itemPositionsNotifier!.itemPositions.value) {
              if (p.index < list.itemCount - 2 &&
                  p.itemLeadingEdge >= 0 &&
                  p.itemLeadingEdge < 1) {
                oldPositions[p.index] = p.itemLeadingEdge;
              }
            }
            expect(oldPositions, isNotEmpty);
          }
          primary.addAll(cues(90).skip(80));
          secondary.addAll(
            cues(90).skip(80).map((c) => c.copyWith(text: '译文 ${c.index}')),
          );
          await show();
          await frames(tester, 4);
          if (view == 'music') {
            for (final entry in oldTexts.entries) {
              final text = find.text(entry.key);
              if (text.evaluate().isNotEmpty) {
                expect(
                  tester.getTopLeft(text.first).dy,
                  closeTo(entry.value.dy, 1.5),
                );
              }
            }
          } else {
            final list = tester.widget<ScrollablePositionedList>(
              find.byType(ScrollablePositionedList),
            );
            final positions = {
              for (final p in list.itemPositionsNotifier!.itemPositions.value)
                p.index: p.itemLeadingEdge,
            };
            for (final entry in oldPositions.entries) {
              expect(positions[entry.key], isNotNull);
              expect(positions[entry.key], closeTo(entry.value, .003));
            }
          }
          expect(clock.value, const Duration(seconds: 30));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
