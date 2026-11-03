import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/transcription_progress.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/subtitle_generation_footer.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  for (final mode in ['list', 'paragraph', 'continuous']) {
    for (final following in [false, true]) {
      testWidgets(
        '$mode short live transcript stays at top, follow=$following',
        (tester) async {
          final host = await _Host.create(
            tester,
            mode: mode,
            following: following,
          );
          host.expectAtTop();
          expect(find.byType(SubtitleGenerationFooter), findsOneWidget);
          expect(find.text('正在转录 · 04:14 / 55:04'), findsOneWidget);
          host.sidebar.locateToCurrentSubtitle(ignorePointer: true);
          await host.frames();
          host.expectAtTop();
          host.player.value = host.player.value.copyWith(
            position: const Duration(seconds: 4),
            isPlaying: true,
          );
          await host.frames();
          host.expectAtTop();
          await host.dispose();
        },
      );
    }
    for (final percent in [0, 100]) {
      testWidgets('$mode short transcript ignores $percent percent locate', (
        tester,
      ) async {
        final host = await _Host.create(
          tester,
          mode: mode,
          locatePercent: percent,
        );
        host.expectAtTop();
        host.sidebar.locateToTime(const Duration(seconds: 4));
        await host.frames();
        host.expectAtTop();
        await host.dispose();
      });
    }
    testWidgets(
      '$mode stays at top as a live transcript grows beyond the viewport',
      (tester) async {
        final host = await _Host.create(tester, mode: mode, following: false);
        host.expectAtTop();
        final state = tester.state(host.list);
        host.update(() {
          host.buffer.addAll(_cues(6, 8));
          host.publish();
        });
        await host.frames();
        host.expectAtTop();
        host.update(() {
          host.buffer.addAll(_cues(8, 40));
          host.publish();
        });
        await host.frames();
        host.expectAtTop();
        expect(tester.state(host.list), same(state));
        host.sidebar.locateToTime(const Duration(seconds: 90), animated: false);
        await host.frames();
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(of: host.list, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        expect(
          position.maxScrollExtent - position.minScrollExtent,
          greaterThan(0),
        );
        expect(
          tester
              .widget<ScrollablePositionedList>(host.list)
              .itemPositionsNotifier!
              .itemPositions
              .value
              .any(
                (p) =>
                    p.index > 0 &&
                    p.itemLeadingEdge >= 0 &&
                    p.itemLeadingEdge < 1,
              ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await host.dispose();
      },
    );
    testWidgets(
      '$mode returns to the top when a larger viewport fits the text',
      (tester) async {
        final host = await _Host.create(tester, mode: mode, following: false);
        host.update(() => host.height = 220);
        await host.frames();
        host.sidebar.locateToTime(const Duration(seconds: 14), animated: false);
        await host.frames();
        host.update(() => host.height = 650);
        await host.frames();
        host.expectAtTop();
        await host.dispose();
      },
    );
  }
}

class _LiveManager extends TranscriptionManager {
  SubtitleStreamUpdate? latest;

  @override
  SubtitleStreamUpdate? streamForVideo(String path, {String? videoId}) =>
      latest;
  @override
  bool isVideoRunning(String path, {String? videoId}) => true;
  @override
  bool isVideoStopping(String path, {String? videoId}) => false;
  @override
  TranscriptionAudioProgress get localAudioProgress =>
      const TranscriptionAudioProgress(
        completed: Duration(minutes: 4, seconds: 14),
        total: Duration(minutes: 55, seconds: 4),
      );
}

class _Host {
  _Host(this.tester, this.mode, this.player, this.playback, this.manager);

  final WidgetTester tester;
  final String mode;
  final VideoPlayerController player;
  final MediaPlaybackService playback;
  final _LiveManager manager;
  final key = GlobalKey<SubtitleSidebarState>();
  final buffer = SubtitleCueBuffer();
  late StateSetter update;
  double height = 650;
  double width = 420;

  SubtitleSidebarState get sidebar => key.currentState!;
  Finder get list => find.byType(ScrollablePositionedList).first;
  Finder get firstRow => find
      .descendant(
        of: list,
        matching: find.byWidgetPredicate(
          (widget) => widget is IndexedSemantics && widget.index == 0,
        ),
      )
      .first;

  void expectAtTop() {
    final first = tester.getTopLeft(firstRow).dy;
    final top = tester.getTopLeft(list).dy;
    expect(
      first - top,
      inInclusiveRange(-.5, 21),
      reason:
          'A fitting transcript must start at its normal top inset; '
          'actual gap: ${first - top}.',
    );
    expect(tester.takeException(), isNull);
  }

  Future<void> frames([int count = 20]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  void publish() {
    manager.latest = SubtitleStreamUpdate(
      generationId: 'short-generation',
      mediaKey: 'id:short',
      videoId: 'short',
      videoPath: '/short.mp4',
      revision: buffer.snapshot.length,
      primaryPath: '/short.source.srt',
      secondaryPath: null,
      primary: buffer.snapshot,
      secondary: SubtitleCueBuffer().snapshot,
      addedPrimary: const [],
      addedSecondary: const [],
      primaryBytes: 100,
      secondaryBytes: 0,
      processedThrough: const Duration(minutes: 4, seconds: 14),
      phase: SubtitleStreamPhase.generating,
    );
    playback.setSubtitleState(
      paths: manager.latest!.paths,
      primary: buffer.snapshot,
      secondary: const [],
    );
  }

  static Future<_Host> create(
    WidgetTester tester, {
    required String mode,
    bool following = true,
    int locatePercent = 50,
  }) async {
    SharedPreferences.setMockInitialValues({
      'autoScrollSubtitles': following,
      'subtitleViewMode': mode == 'list' ? 0 : 1,
      'subtitleArticleParagraphModeEnabled': mode == 'paragraph',
      'subtitleArticleSentencesPerParagraph': 4,
      'landscapeSidebarLocatePositionPercent': locatePercent,
    });
    final settings = SettingsService()..resetForTest();
    await settings.init();
    await tester.binding.setSurfaceSize(const Size(900, 760));
    final player = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/short.mp4'),
    );
    player.value = VideoPlayerValue(
      duration: const Duration(minutes: 55, seconds: 4),
      position: const Duration(seconds: 14),
      isInitialized: true,
      isPlaying: following,
    );
    final playback = MediaPlaybackService.forTesting();
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'short',
        path: '/short.mp4',
        title: 'Short transcript',
        durationMs: 3304000,
        lastUpdated: 0,
      ),
    );
    final host = _Host(tester, mode, player, playback, _LiveManager());
    host.buffer.addAll(_cues(0, 6));
    host.publish();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ChangeNotifierProvider<TranscriptionManager>.value(
            value: host.manager,
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                host.update = setState;
                return Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: host.width,
                    height: host.height,
                    child: SubtitleSidebar(
                      key: host.key,
                      subtitles: host.buffer.snapshot,
                      controller: player,
                      isCompact: true,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await host.frames();
    return host;
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox());
    await player.dispose();
    playback.dispose();
    manager.dispose();
    SettingsService().resetForTest();
    await tester.binding.setSurfaceSize(null);
  }
}

List<SubtitleItem> _cues(int start, int end) => [
  for (var i = start; i < end; i++)
    SubtitleItem(
      index: i + 1,
      startTime: Duration(seconds: i * 3),
      endTime: Duration(seconds: i * 3 + 3),
      text: 'Sentence $i stays near the top. 一段正在生成的课堂字幕。',
    ),
];
