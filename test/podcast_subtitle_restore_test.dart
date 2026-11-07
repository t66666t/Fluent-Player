import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_transfer.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selected podcast subtitles', () {
    late Directory root;
    late MediaPlaybackService playback;
    late VideoItem item;
    late File subtitle;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('podcast-subtitle-restore-');
      subtitle = File('${root.path}/primary.srt');
      await subtitle.writeAsString(
        '1\n00:00:40,000 --> 00:00:45,000\nSaved transcript\n',
      );
      playback = MediaPlaybackService.forTesting();
      item = VideoItem(
        id: 'episode-a',
        path: 'podcast:episode-a',
        title: 'Episode A',
        durationMs: 7200000,
        lastUpdated: 0,
        type: MediaType.audio,
        subtitlePath: subtitle.path,
      );
      playback.debugSeedCurrentItem(item);
    });

    tearDown(() async {
      playback.dispose();
      await root.delete(recursive: true);
    });

    test(
      'loading is published before local reading and always settles',
      () async {
        final restoring = playback.refreshAssociatedSubtitles(item);
        expect(playback.isLoadingSubtitles, isTrue);
        expect(playback.subtitles, isEmpty);
        await restoring;
        expect(playback.isLoadingSubtitles, isFalse);
        expect(playback.subtitles.single.text, 'Saved transcript');

        playback.clearSubtitleState();
        await subtitle.delete();
        await playback.refreshAssociatedSubtitles(item);
        expect(playback.isLoadingSubtitles, isFalse);
        expect(playback.subtitles, isEmpty);
      },
    );

    test(
      'a covered page cannot cancel the active subtitle restoration',
      () async {
        final restoring = playback.refreshAssociatedSubtitles(item);
        final rejected = await playback.loadSubtitlePathsForCurrentItem(
          itemId: 'previous-episode',
          paths: [],
        );
        expect(rejected, isFalse);
        expect(playback.isLoadingSubtitles, isTrue);
        await restoring;
        expect(playback.isLoadingSubtitles, isFalse);
        expect(playback.subtitles.single.text, 'Saved transcript');
      },
    );

    test('an explicit clear wins over an older restore', () async {
      final restoring = playback.refreshAssociatedSubtitles(item);
      expect(
        await playback.loadSubtitlePathsForCurrentItem(
          itemId: item.id,
          paths: [],
        ),
        isTrue,
      );
      await restoring;
      expect(playback.isLoadingSubtitles, isFalse);
      expect(playback.subtitles, isEmpty);
      expect(playback.subtitlePaths, isEmpty);
      expect(item.subtitlePath, isNull);
    });

    test(
      'repeated restoration reuses parsing and notices file edits',
      () async {
        await playback.refreshAssociatedSubtitles(item);
        final originalCue = playback.subtitles.single;
        await playback.refreshAssociatedSubtitles(item);
        expect(identical(playback.subtitles.single, originalCue), isTrue);

        await subtitle.writeAsString(
          '1\n00:00:40,000 --> 00:00:45,000\nUpdated transcript\n',
        );
        await playback.refreshAssociatedSubtitles(item);
        expect(playback.subtitles.single.text, 'Updated transcript');
        expect(identical(playback.subtitles.single, originalCue), isFalse);
      },
    );

    test(
      'the new episode owns both subtitle content and loading state',
      () async {
        final restoringA = playback.refreshAssociatedSubtitles(item);
        final secondFile = File('${root.path}/secondary-episode.srt');
        await secondFile.writeAsString(
          '1\n00:00:10,000 --> 00:00:15,000\nEpisode B transcript\n',
        );
        final second = VideoItem(
          id: 'episode-b',
          path: 'podcast:episode-b',
          title: 'Episode B',
          durationMs: 7200000,
          lastUpdated: 0,
          subtitlePath: secondFile.path,
        );
        playback.debugSeedCurrentItem(second);
        final restoringB = playback.refreshAssociatedSubtitles(second);
        await Future.wait([restoringA, restoringB]);
        expect(playback.isLoadingSubtitles, isFalse);
        expect(playback.currentItem?.id, second.id);
        expect(playback.subtitles.single.text, 'Episode B transcript');
      },
    );
  });

  test('local loading and a missing selection never say no transcript', () {
    PodcastTranscriptAction action({
      bool loading = false,
      bool selected = false,
    }) => resolvePodcastTranscriptAction(
      sessionReady: true,
      sourceSupported: true,
      official: PodcastOfficialTranscript.unknown,
      aiRunning: false,
      aiFailed: false,
      hasGenerated: false,
      generatedLoaded: false,
      subtitlesLoading: loading,
      hasSelectedSubtitle: selected,
    );
    expect(
      action(loading: true, selected: true).kind,
      PodcastTranscriptActionKind.loading,
    );
    expect(
      action(selected: true).kind,
      PodcastTranscriptActionKind.retrySelected,
    );
    expect(action().kind, PodcastTranscriptActionKind.generate);
  });

  for (final size in [const Size(390, 844), const Size(1100, 844)]) {
    testWidgets(
      'player restores an already selected transcript on entry at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        final root = Directory.systemTemp.createTempSync(
          'podcast-subtitle-page-',
        );
        final subtitle = File('${root.path}/primary.srt')
          ..writeAsStringSync(
            '1\n00:00:00,000 --> 00:00:45,000\nSaved transcript\n',
          );
        final store = PodcastStore(sqlite3.openInMemory());
        final client = PodcastClient();
        final controller = PodcastController(
          store: store,
          client: client,
          mediaStore: PodcastMediaStore(
            root: root,
            store: store,
            http: client.http,
          ),
        );
        final playback = MediaPlaybackService.forTesting();
        final episode = PodcastEpisode(
          sourceFeedUrl: 'https://publisher.test/rss',
          id: 'saved-episode',
          channelId: 'channel',
          title: 'Saved episode',
          media: [
            const PodcastMedia(
              url: 'https://example.invalid/audio.mp3',
              mimeType: 'audio/mpeg',
            ),
          ],
        );
        store.write(
          'episode',
          episode.id,
          episode.toJson(),
          channel: episode.channelId,
        );
        final runtime = PodcastRuntime.forTesting(
          controller,
          playback: playback,
        );
        PodcastRuntime.debugOverride = runtime;
        playback.debugSeedCurrentItem(
          VideoItem(
            id: episode.id,
            path: 'podcast:${episode.id}',
            title: episode.title,
            durationMs: 7200000,
            lastUpdated: 0,
            type: MediaType.audio,
            subtitlePath: subtitle.path,
            sourceRef: MediaSourceRef(
              value: 'podcast:${episode.id}',
              kind: MediaSourceKind.podcastEpisode,
              podcast: PodcastEpisodeRef(
                channelId: episode.channelId,
                episodeId: episode.id,
                feedUrl: 'https://example.invalid/rss',
                mediaUrl: episode.media.first.url,
              ),
            ),
          ),
        );
        try {
          Future<void> mountAndWait() async {
            final loaded = Completer<void>();
            void onPlayback() {
              if (!playback.isLoadingSubtitles &&
                  playback.subtitles.isNotEmpty &&
                  !loaded.isCompleted) {
                loaded.complete();
              }
            }

            playback.addListener(onPlayback);
            await tester.pumpWidget(
              MultiProvider(
                providers: [
                  ChangeNotifierProvider<SettingsService>.value(
                    value: settings,
                  ),
                  ChangeNotifierProvider<MediaPlaybackService>.value(
                    value: playback,
                  ),
                ],
                child: MaterialApp(
                  home: PodcastPlayerPage(episodeId: episode.id),
                ),
              ),
            );
            expect(find.text('本期暂无文字稿'), findsNothing);
            expect(find.text('语音转录'), findsNothing);
            expect(
              find.byKey(const ValueKey('podcast-transcript-loading')),
              findsOneWidget,
            );
            for (
              var attempt = 0;
              attempt < 200 && !loaded.isCompleted;
              attempt++
            ) {
              await tester.pump(const Duration(milliseconds: 20));
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 5)),
              );
            }
            expect(loaded.isCompleted, isTrue);
            playback.removeListener(onPlayback);
            await tester.pumpAndSettle();
            expect(find.byType(MusicLyricView), findsOneWidget);
            expect(find.text('Saved transcript'), findsOneWidget);
            expect(
              find.byKey(const ValueKey('podcast-transcript-loading')),
              findsNothing,
            );
          }

          await mountAndWait();
          await tester.pumpWidget(const SizedBox.shrink());
          playback.clearSubtitleState();
          // The association persists even if an earlier load was superseded.
          await mountAndWait();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(runtime.shutdown);
          PodcastRuntime.debugOverride = null;
          playback.dispose();
          await tester.runAsync(() => root.delete(recursive: true));
        }
      },
    );
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('$platform reveals late long transcripts at the current line', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(600, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final clock = ValueNotifier(const Duration(minutes: 90));
      addTearDown(clock.dispose);
      final cues = List.generate(
        2000,
        (index) => SubtitleItem(
          index: index,
          startTime: Duration(seconds: index * 5),
          endTime: Duration(seconds: index * 5 + 5),
          text: 'Transcript line $index',
        ),
      );
      late StateSetter update;
      var available = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MusicLyricView(
                  subtitles: available ? cues : const [],
                  positionListenable: clock,
                  applyEdgeFade: false,
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      update(() => available = true);
      await tester.pump();
      // A playback tick can arrive between the subtitle commit and reveal.
      clock.value = const Duration(minutes: 90, seconds: 5);
      for (var frame = 0; frame < 24; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final content = tester.widget<FadeTransition>(
          find
              .descendant(
                of: find.byType(MusicLyricView),
                matching: find.byType(FadeTransition),
              )
              .first,
        );
        if (content.opacity.value > 0) {
          final current = find.text('Transcript line 1081');
          expect(current, findsOneWidget);
          expect(tester.getTopLeft(current).dy, closeTo(240, 1));
        }
      }
      // A late native resume sample must also jump, with no traversal.
      clock.value = const Duration(minutes: 100);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getTopLeft(find.text('Transcript line 1200')).dy,
        closeTo(240, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
