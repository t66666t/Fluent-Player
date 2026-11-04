import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'missing source keeps a paused navigable session and loads external subtitles',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final sandbox = await Directory.systemTemp.createTemp(
        'media_playback_missing_source_',
      );
      final subtitle = File(
        '${sandbox.path}${Platform.pathSeparator}missing.srt',
      );
      await subtitle.writeAsString(
        '1\n00:00:00,000 --> 00:00:02,000\nStill available\n',
      );

      final playlist = PlaylistManager();
      final service = MediaPlaybackService();
      await service.stop();
      await service.initialize(
        playlistManager: playlist,
        progressTracker: ProgressTracker(),
      );

      final previous = VideoItem(
        id: 'missing-previous',
        path: '${sandbox.path}${Platform.pathSeparator}previous.mp4',
        title: 'Previous',
        durationMs: 1000,
        lastUpdated: 0,
      );
      final missing = VideoItem(
        id: 'missing-current',
        path: '${sandbox.path}${Platform.pathSeparator}current.mp4',
        title: 'Current',
        durationMs: 2000,
        lastUpdated: 0,
        subtitlePath: subtitle.path,
      );
      final next = VideoItem(
        id: 'missing-next',
        path: '${sandbox.path}${Platform.pathSeparator}next.mp4',
        title: 'Next',
        durationMs: 3000,
        lastUpdated: 0,
      );
      playlist.setPlaylist(<VideoItem>[previous, missing, next], startIndex: 1);

      addTearDown(() async {
        await service.stop();
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      await service.play(missing);

      expect(service.currentItem?.id, missing.id);
      expect(service.state, PlaybackState.paused);
      expect(service.isSourceMissing, isTrue);
      expect(service.controller, isNull);
      expect(playlist.playlist, isEmpty);
      expect(playlist.currentIndex, -1);
      expect(playlist.hasPrevious, isFalse);
      expect(playlist.hasNext, isFalse);
      expect(service.hasPlayablePrevious, isFalse);
      expect(service.hasPlayableNext, isFalse);

      for (var i = 0; i < 100 && service.subtitlePaths.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(service.subtitlePaths, <String>[subtitle.path]);
      expect(service.subtitles.single.text, 'Still available');

      await service.playNext(autoPlay: false);
      expect(service.currentItem?.id, missing.id);
      expect(service.isSourceMissing, isTrue);

      await service.playPrevious(autoPlay: false);
      expect(service.currentItem?.id, missing.id);
      expect(service.isSourceMissing, isTrue);
      expect(playlist.hasNext, isFalse);
    },
  );
}
