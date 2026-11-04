import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('list wrap enables next on the last item and previous on the first', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final sandbox = await Directory.systemTemp.createTemp('playlist_wrap_nav_');
    final settings = SettingsService();
    final originalWrap = settings.playlistWrapToFirst;
    final playlist = PlaylistManager();
    final service = MediaPlaybackService();
    await service.initialize(
      playlistManager: playlist,
      progressTracker: ProgressTracker(),
    );

    final items = <VideoItem>[
      for (var index = 0; index < 3; index++)
        VideoItem(
          id: 'wrap-$index',
          path: '${sandbox.path}${Platform.pathSeparator}$index.mp4',
          title: 'Item $index',
          durationMs: 1000,
          lastUpdated: 0,
        ),
    ];
    for (final item in items) {
      await File(item.path).writeAsBytes(<int>[0]);
    }

    addTearDown(() async {
      settings.playlistWrapToFirst = originalWrap;
      await service.stop();
      if (await sandbox.exists()) await sandbox.delete(recursive: true);
    });

    settings.playlistWrapToFirst = false;
    playlist.setPlaylist(items, startIndex: items.length - 1);
    expect(service.hasPlayableNext, isFalse);
    expect(service.hasPlayablePrevious, isTrue);

    playlist.setPlaylist(items, startIndex: 0);
    expect(service.hasPlayablePrevious, isFalse);
    expect(service.hasPlayableNext, isTrue);

    settings.playlistWrapToFirst = true;
    playlist.setPlaylist(items, startIndex: items.length - 1);
    expect(service.hasPlayableNext, isTrue);
    expect(service.hasPlayablePrevious, isTrue);

    playlist.setPlaylist(items, startIndex: 0);
    expect(service.hasPlayablePrevious, isTrue);
    expect(service.hasPlayableNext, isTrue);

    playlist.setPlaylist(items.sublist(0, 1));
    expect(service.hasPlayableNext, isFalse);
    expect(service.hasPlayablePrevious, isFalse);
  });
}
