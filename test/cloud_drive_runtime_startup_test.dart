import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_screen.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_startup.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LibraryService library;
  late PlaylistManager playlist;
  late MediaPlaybackService playback;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudDriveStartup.resetForTest();
    library = LibraryService()..resetLibraryForTesting();
    playlist = PlaylistManager()..initialize(libraryService: library);
    playback = MediaPlaybackService.forTesting();
  });
  tearDown(() async {
    await CloudDriveRuntime.instance?.shutdown();
    CloudDriveStartup.resetForTest();
    playback.dispose();
    playlist.dispose();
    library.resetLibraryForTesting();
  });

  void begin(Completer<void> libraryReady) => CloudDriveRuntime.beginInstall(
    library: library,
    playlist: playlist,
    mediaPlayback: playback,
    libraryReady: libraryReady.future,
  );

  test(
    'early playback shares local startup and waits for the library',
    () async {
      final libraryReady = Completer<void>();
      begin(libraryReady);
      final first = CloudDriveRuntime.ensureInstalled();
      final second = CloudDriveRuntime.ensureInstalled();
      expect(identical(first, second), isTrue);
      expect(CloudDriveStartup.pending, isNotNull);
      expect(CloudDriveRuntime.instance, isNull);
      var ready = false;
      final waiting = CloudDriveStartup.waitUntilReady().then(
        (_) => ready = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      libraryReady.complete();
      final runtime = await first;
      await waiting;
      expect(ready, isTrue);
      expect(CloudDriveRuntime.instance, same(runtime));
      expect(
        runtime.providers.all.map((p) => p.id),
        containsAll(['baidu', 'quark', 'uc', 'aliyun']),
      );
    },
  );

  testWidgets(
    'an early cloud page automatically opens when local startup completes',
    (tester) async {
      final libraryReady = Completer<void>();
      begin(libraryReady);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CloudDriveScreen(embedded: true)),
        ),
      );
      await tester.pump();
      expect(find.text('正在读取本机网盘账号…'), findsOneWidget);
      expect(find.text('网盘播放服务尚未初始化'), findsNothing);
      libraryReady.complete();
      await tester.pumpAndSettle();
      expect(find.text('正在读取本机网盘账号…'), findsNothing);
      expect(find.text('登录百度网盘'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a stalled local read offers retry and can reuse a late installation',
    (tester) async {
      final libraryReady = Completer<void>();
      begin(libraryReady);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: CloudDriveScreen(embedded: true)),
        ),
      );
      await tester.pump();
      await tester.pump(
        cloudDriveInitializationTimeout + const Duration(seconds: 1),
      );
      await tester.pump();
      final retry = find.textContaining('读取本机网盘账号超时');
      expect(retry, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      libraryReady.complete();
      await tester.pump();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.text('登录百度网盘'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'background startup errors are observed before a first play and remain retryable',
    () async {
      final initial = Completer<void>();
      var retries = 0;
      CloudDriveStartup.bind(
        pending: initial.future,
        retry: () async => retries++,
      );
      initial.completeError(StateError('local account read failed'));
      await Future<void>.delayed(Duration.zero);
      await CloudDriveStartup.waitUntilReady();
      expect(retries, 1);
      await CloudDriveStartup.waitUntilReady();
      expect(retries, 1);
    },
  );

  test(
    'local startup timeout preserves the shared operation and explains recovery',
    () async {
      final operation = Completer<int>();
      await expectLater(
        waitForCloudDriveInitialization(
          operation.future,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(
          isA<CloudDriveFailure>()
              .having((e) => e.diagnostic, 'diagnostic', 'startup=timeout')
              .having((e) => e.message, 'message', contains('本机网盘账号超时')),
        ),
      );
      operation.complete(42);
      expect(await operation.future, 42);
    },
  );
}
