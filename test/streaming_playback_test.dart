import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/services/transcription_manager.dart';

import 'support/fake_video_player_platform.dart';

class _Manager extends TranscriptionManager {
  final events = StreamController<SubtitleStreamUpdate>.broadcast(sync: true);
  final starts = StreamController<SubtitleGenerationStart>.broadcast(
    sync: true,
  );
  SubtitleStreamUpdate? latest;
  @override
  Stream<SubtitleStreamUpdate> get subtitleUpdates => events.stream;
  @override
  Stream<SubtitleGenerationStart> get subtitleGenerationStarts => starts.stream;
  @override
  SubtitleStreamUpdate? streamForPath(String path) =>
      latest?.paths.contains(path) == true ? latest : null;
  void emit(SubtitleStreamUpdate update) {
    latest = update;
    events.add(update);
  }

  @override
  void dispose() {
    unawaited(events.close());
    unawaited(starts.close());
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Manager manager;
  late MediaPlaybackService playback;
  var playbackDisposed = false;
  late SubtitleCueBuffer primary, secondary;
  late String primaryPath, secondaryPath;
  setUp(() {
    playbackDisposed = false;
    manager = _Manager();
    playback = MediaPlaybackService.forTesting();
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'media',
        path: '/media.mp4',
        title: 'Media',
        durationMs: 60000,
        lastUpdated: 0,
      ),
    );
    playback.bindSubtitleStreams(manager);
    primary = SubtitleCueBuffer();
    secondary = SubtitleCueBuffer();
    primaryPath = '/source.srt';
    secondaryPath = '/translation.srt';
  });
  tearDown(() {
    if (!playbackDisposed) playback.dispose();
    manager.dispose();
  });
  SubtitleStreamUpdate update({
    SubtitleStreamPhase phase = SubtitleStreamPhase.generating,
  }) => SubtitleStreamUpdate(
    generationId: 'generation',
    mediaKey: 'id:media',
    videoId: 'media',
    videoPath: playback.currentItem!.path,
    revision: primary.snapshot.length,
    primaryPath: primaryPath,
    secondaryPath: secondaryPath,
    primary: primary.snapshot,
    secondary: secondary.snapshot,
    addedPrimary: const [],
    addedSecondary: const [],
    primaryBytes: 100,
    secondaryBytes: 100,
    processedThrough: const Duration(seconds: 30),
    phase: phase,
  );
  void append(int id, {bool publish = true}) {
    primary.addAll([
      SubtitleItem(
        index: id,
        startTime: Duration(seconds: id * 2),
        endTime: Duration(seconds: id * 2 + 1),
        text: 'Source $id',
        timedSpans: [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 6,
            startTime: Duration(seconds: id * 2),
            endTime: Duration(milliseconds: id * 2000 + 500),
          ),
          SubtitleTimedSpan(
            textStart: 7,
            textEnd: 'Source $id'.length,
            startTime: Duration(milliseconds: id * 2000 + 500),
            endTime: Duration(seconds: id * 2 + 1),
          ),
        ],
      ),
    ]);
    secondary.addAll([
      SubtitleItem(
        index: id,
        startTime: Duration(seconds: id * 2),
        endTime: Duration(seconds: id * 2 + 1),
        text: '译文 $id',
      ),
    ]);
    if (publish) manager.emit(update());
  }

  Future<void> flush() =>
      Future<void>.delayed(const Duration(milliseconds: 280));

  Future<void> prepareFiles() async {
    final directory = await Directory.systemTemp.createTemp(
      'streaming-playback-timing-',
    );
    addTearDown(() => directory.delete(recursive: true));
    primaryPath = '${directory.path}${Platform.pathSeparator}source.srt';
    secondaryPath = '${directory.path}${Platform.pathSeparator}translation.srt';
    await File(primaryPath).writeAsString(encodeStreamingSrt(primary.snapshot));
    await File(
      secondaryPath,
    ).writeAsString(encodeStreamingSrt(secondary.snapshot));
  }

  for (final phase in SubtitleStreamPhase.values.where(
    (phase) => phase != SubtitleStreamPhase.complete,
  )) {
    test('associated refresh preserves word timings while $phase', () async {
      append(1, publish: false);
      await prepareFiles();
      manager.emit(update(phase: phase));
      await flush();
      final item = playback.currentItem!;
      final first = playback.subtitles.single;
      final intent = playback.subtitleIntentGenerationForTest;

      for (var i = 0; i < 3; i++) {
        await playback.refreshAssociatedSubtitles(item);
        expect(playback.subtitles.single.timedSpans, hasLength(2));
        expect(playback.subtitles.single, same(first));
        expect(playback.subtitles, isA<SubtitleCueSnapshot>());
        expect(playback.secondarySubtitles.single.text, '译文 1');
        expect(playback.subtitlePaths, [primaryPath, secondaryPath]);
        expect(playback.subtitleIntentGenerationForTest, intent);
      }

      append(2);
      await flush();
      expect(playback.subtitleWasAppend, isTrue);
      expect(playback.subtitles.first, same(first));
      expect(playback.subtitles.last.timedSpans, hasLength(2));
      expect(playback.secondarySubtitles, hasLength(2));
    });
  }

  test('rapid local pause/resume retains streaming word timings', () async {
    SharedPreferences.setMockInitialValues({});
    final previousPlatform = VideoPlayerPlatform.instance;
    final platform = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = platform;
    final controller = VideoPlayerController.file(File('/media.mp3'));
    addTearDown(() async {
      await playback.stop();
      await controller.dispose();
      VideoPlayerPlatform.instance = previousPlatform;
    });
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'media',
        path: controller.dataSource,
        title: 'Local audio',
        type: MediaType.audio,
        durationMs: 60000,
        lastUpdated: 0,
      ),
    );
    // Exercise the native local resume path without a platform decoder.
    await controller.initialize();
    await playback.setController(controller);
    append(1, publish: false);
    await prepareFiles();
    manager.emit(update());
    await flush();
    final first = playback.subtitles.single;

    final commands = <Future<void>>[];
    for (var i = 0; i < 5; i++) {
      commands.add(playback.resume());
      commands.add(playback.pause());
    }
    await Future.wait(commands);
    expect(playback.state, PlaybackState.paused);
    expect(playback.subtitles.single.timedSpans, hasLength(2));
    await playback.resume();
    await flush();
    expect(playback.state, PlaybackState.playing);
    expect(playback.isLoadingSubtitles, isFalse);
    expect(playback.controller, same(controller));
    expect(playback.subtitles.single.timedSpans, hasLength(2));
    expect(playback.subtitles.single, same(first));
    expect(playback.secondarySubtitles.single.text, '译文 1');

    append(2);
    await flush();
    expect(playback.subtitleWasAppend, isTrue);
    expect(playback.subtitles.first, same(first));
    expect(playback.subtitles.last.timedSpans, hasLength(2));
    expect(playback.secondarySubtitles, hasLength(2));
  });

  test(
    'a network controller cannot replace the current local session',
    () async {
      final item = playback.currentItem;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/audio.mp3'),
      );
      addTearDown(controller.dispose);
      await expectLater(
        playback.setController(controller),
        throwsUnsupportedError,
      );
      expect(playback.currentItem, same(item));
      expect(playback.controller, isNull);
    },
  );

  test('completed streams still reload files and timing companions', () async {
    append(1, publish: false);
    await prepareFiles();
    manager.emit(update());
    await flush();
    final item = playback.currentItem!;
    await playback.refreshAssociatedSubtitles(item);
    await SubtitleWordTimingStore.write(primaryPath, primary.snapshot);
    // The manager releases completed cue buffers and retains metadata only.
    manager.latest = update(phase: SubtitleStreamPhase.complete).compact();

    await playback.refreshAssociatedSubtitles(item);
    expect(playback.subtitles.single.timedSpans, hasLength(2));
    expect(playback.secondarySubtitles.single.text, '译文 1');

    await File(primaryPath).writeAsString(
      encodeStreamingSrt([
        primary.snapshot.single.copyWith(text: 'Edited after completion'),
      ]),
    );
    await playback.refreshAssociatedSubtitles(item);
    expect(playback.subtitles.single.text, 'Edited after completion');
    expect(playback.subtitles.single.timedSpans, isEmpty);
  });

  test(
    'first pair auto selects once, later batches append without changing intent',
    () async {
      manager.starts.add((mediaKey: 'id:media', runId: 'run'));
      final intent = playback.subtitleIntentGenerationForTest;
      append(1);
      await flush();
      expect(playback.subtitlePaths, ['/source.srt', '/translation.srt']);
      expect(playback.subtitles, hasLength(1));
      expect(playback.secondarySubtitles, hasLength(1));
      expect(playback.subtitleWasAppend, isFalse);
      final first = playback.subtitles.first;
      append(2);
      await flush();
      expect(playback.subtitleWasAppend, isTrue);
      expect(playback.subtitles, hasLength(2));
      expect(identical(first, playback.subtitles.first), isTrue);
      expect(playback.subtitleIntentGenerationForTest, intent);
    },
  );

  test(
    'manual selection before or after first batch wins until generated files are selected',
    () async {
      manager.starts.add((mediaKey: 'id:media', runId: 'run'));
      playback.setSubtitleState(
        paths: ['/manual.srt'],
        primary: [
          SubtitleItem(
            index: 1,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 5),
            text: 'Manual',
          ),
        ],
        secondary: [],
      );
      append(1);
      await flush();
      expect(playback.subtitlePaths, ['/manual.srt']);
      expect(
        await playback.loadSubtitlePathsForCurrentItem(
          itemId: 'media',
          paths: ['/source.srt', '/translation.srt'],
        ),
        isTrue,
      );
      append(2);
      await flush();
      expect(playback.subtitles, hasLength(2));
      playback.setSubtitleState(paths: [], primary: [], secondary: []);
      append(3);
      await flush();
      expect(playback.subtitles, isEmpty);
    },
  );

  test('a queued update cannot change another media item', () async {
    manager.starts.add((mediaKey: 'id:media', runId: 'run'));
    append(1);
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'other',
        path: '/other.mp4',
        title: 'Other',
        durationMs: 60000,
        lastUpdated: 0,
      ),
    );
    await flush();
    expect(playback.subtitles, isEmpty);
    expect(playback.subtitlePaths, isEmpty);
  });

  test(
    'resuming a generation retains a manual choice made before its first pair',
    () async {
      manager.starts.add((mediaKey: 'id:media', runId: 'run'));
      playback.setSubtitleState(
        paths: ['/manual.srt'],
        primary: [],
        secondary: [],
      );
      manager.starts.add((mediaKey: 'id:media', runId: 'run'));
      append(1);
      await flush();
      expect(playback.subtitlePaths, ['/manual.srt']);
      manager.starts.add((mediaKey: 'id:media', runId: 'new-run'));
      append(2);
      await flush();
      expect(playback.subtitlePaths, ['/source.srt', '/translation.srt']);
    },
  );

  test(
    'dispose cancels a pending batch and detaches selection policy',
    () async {
      manager.starts.add((mediaKey: 'id:media', runId: 'run'));
      var notifications = 0;
      playback.addListener(() => notifications++);
      append(1);
      playback.dispose();
      playbackDisposed = true;
      expect(manager.shouldSelectGeneratedSubtitles, isNull);
      await flush();
      expect(notifications, 0);
    },
  );
}
