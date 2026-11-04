import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/progress_tracker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  final legacy = PlaybackStateSnapshot(
    currentItemId: 'existing-song',
    positionMs: 75000,
    wasPlaying: false,
    timestamp: 1,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('playback_state_');
    SharedPreferences.setMockInitialValues({
      PlaybackStateStore.legacyKey: jsonEncode(legacy.toJson()),
      // Real installations can have large caches in the same preferences file.
      // Saving a tiny playback snapshot must leave that whole store alone.
      'unrelated_cache': 'x' * (11 * 1024 * 1024),
    });
  });
  tearDown(() => directory.delete(recursive: true));

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    PlaybackStateStore store() => PlaybackStateStore(
      platform: platform,
      directoryProvider: () async => directory,
    );

    test(
      '$platform migrates resume state without rewriting preferences',
      () async {
        final tracker = ProgressTracker(playbackStateStore: store());
        final restored = await tracker.restorePlaybackState();
        expect(restored?.toJson(), legacy.toJson());

        final next = PlaybackStateSnapshot(
          currentItemId: 'clicked-song',
          positionMs: 12000,
          wasPlaying: true,
          timestamp: 2,
        );
        await tracker.savePlaybackState(next);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString(PlaybackStateStore.legacyKey),
          jsonEncode(legacy.toJson()),
        );
        final file = File(p.join(directory.path, PlaybackStateStore.fileName));
        expect(await file.length(), lessThan(1024));

        // Reopen through a new tracker/store to exercise actual disk persistence.
        final reopened = ProgressTracker(playbackStateStore: store());
        expect(
          (await reopened.restorePlaybackState())?.toJson(),
          next.toJson(),
        );
      },
    );

    test(
      '$platform serializes seek/pause saves and a following read',
      () async {
        final tracker = ProgressTracker(playbackStateStore: store());
        final writes = List.generate(
          20,
          (index) => tracker.savePlaybackState(
            PlaybackStateSnapshot(
              currentItemId: 'song',
              positionMs: index * 1000,
              wasPlaying: index.isEven,
              timestamp: index,
            ),
          ),
        );
        final restored = await tracker.restorePlaybackState();
        await Future.wait(writes);
        expect(restored?.positionMs, 19000);
        expect(restored?.wasPlaying, false);
        final reopened = await ProgressTracker(
          playbackStateStore: store(),
        ).restorePlaybackState();
        expect(reopened?.toJson(), restored?.toJson());
      },
    );

    test('$platform ignores an unfinished temporary write', () async {
      final storage = store();
      await storage.write(legacy.toJson());
      await File(
        p.join(directory.path, '${PlaybackStateStore.fileName}.tmp'),
      ).writeAsString('{incomplete');
      expect(await store().read(), legacy.toJson());
    });

    test('$platform can save again after a failed write', () async {
      var first = true;
      final storage = PlaybackStateStore(
        platform: platform,
        directoryProvider: () async {
          if (first) {
            first = false;
            throw const FileSystemException('temporary storage failure');
          }
          return directory;
        },
      );
      await expectLater(
        storage.write(legacy.toJson()),
        throwsA(isA<FileSystemException>()),
      );
      await storage.write(legacy.toJson());
      expect(await storage.read(), legacy.toJson());
    });
  }

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    test('$platform retains its native preferences storage', () async {
      final tracker = ProgressTracker(
        playbackStateStore: PlaybackStateStore(
          platform: platform,
          directoryProvider: () async =>
              throw StateError('Unexpected file storage'),
        ),
      );
      final cleared = PlaybackStateSnapshot(positionMs: 0, wasPlaying: false);
      await tracker.savePlaybackState(cleared);
      expect(
        (await tracker.restorePlaybackState())?.toJson(),
        cleared.toJson(),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(PlaybackStateStore.legacyKey),
        jsonEncode(cleared.toJson()),
      );
    });
  }
}
