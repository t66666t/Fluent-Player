import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/library_persistence_notification_bridge.dart';

void main() {
  final service = LibraryService();

  setUp(() {
    service.resetPersistenceForTesting();
    service.saveRetryDelaysForTesting = const <Duration>[Duration(days: 1)];
  });

  tearDown(() async {
    service.resetPersistenceForTesting();
    await AppToast.dismiss(immediate: true);
  });

  test(
    'a failed save stays recoverable and an immediate retry clears it',
    () async {
      var attempts = 0;
      service.writeLibrarySnapshotOverrideForTesting = () async {
        attempts++;
        if (attempts == 1) {
          throw const FileSystemException('test write failure');
        }
      };

      await service.saveLibraryForTesting();

      expect(
        service.persistenceStatus,
        LibraryPersistenceStatus.retryScheduled,
      );
      expect(service.hasPersistenceFailure, isTrue);
      expect(service.persistenceFailureEpisode, 1);
      expect(service.consecutivePersistenceFailures, 1);
      expect(service.lastPersistenceError, isA<FileSystemException>());
      expect(service.lastPersistenceFailureAt, isNotNull);

      await service.retryLibraryPersistence();

      expect(attempts, 2);
      expect(service.persistenceStatus, LibraryPersistenceStatus.healthy);
      expect(service.hasPersistenceFailure, isFalse);
      expect(service.consecutivePersistenceFailures, 0);
      expect(service.lastPersistenceError, isNull);
      expect(service.lastPersistenceFailureAt, isNull);
    },
  );

  test('repeated failures share one notice episode until recovery', () async {
    service.writeLibrarySnapshotOverrideForTesting = () async {
      throw const FileSystemException('still unavailable');
    };

    await service.saveLibraryForTesting();
    await service.saveLibraryForTesting();

    expect(service.persistenceFailureEpisode, 1);
    expect(service.consecutivePersistenceFailures, 2);

    service.writeLibrarySnapshotOverrideForTesting = () async {};
    await service.retryLibraryPersistence();
    expect(service.hasPersistenceFailure, isFalse);

    service.writeLibrarySnapshotOverrideForTesting = () async {
      throw const FileSystemException('new failure period');
    };
    await service.saveLibraryForTesting();

    expect(service.persistenceFailureEpisode, 2);
    expect(service.consecutivePersistenceFailures, 1);
  });

  test('background retry eventually restores healthy state', () async {
    var attempts = 0;
    service.saveRetryDelaysForTesting = const <Duration>[
      Duration(milliseconds: 10),
    ];
    service.writeLibrarySnapshotOverrideForTesting = () async {
      attempts++;
      if (attempts == 1) {
        throw const FileSystemException('temporary failure');
      }
    };

    await service.saveLibraryForTesting();
    for (var i = 0; i < 20 && service.hasPersistenceFailure; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(attempts, 2);
    expect(service.persistenceStatus, LibraryPersistenceStatus.healthy);
  });

  testWidgets(
    'save warning auto-dismisses and does not repeat in one episode',
    (tester) async {
      service.writeLibrarySnapshotOverrideForTesting = () async {
        throw const FileSystemException('test write failure');
      };

      await tester.pumpWidget(
        ChangeNotifierProvider<LibraryService>.value(
          value: service,
          child: MaterialApp(
            navigatorKey: AppToast.navigatorKey,
            builder: (context, child) {
              return LibraryPersistenceNotificationBridge(
                child: child ?? const SizedBox.shrink(),
              );
            },
            home: const Scaffold(body: Text('library')),
          ),
        ),
      );

      await tester.runAsync(service.saveLibraryForTesting);
      await tester.pump();
      await tester.pump();

      const warning = '媒体库的最新更改暂未写入磁盘，应用会在后台自动重试';
      expect(find.text(warning), findsOneWidget);
      expect(find.text('立即重试'), findsOneWidget);

      await tester.pump(const Duration(seconds: 9));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(warning), findsNothing);

      await tester.runAsync(service.saveLibraryForTesting);
      await tester.pump();
      await tester.pump();
      expect(service.persistenceFailureEpisode, 1);
      expect(find.text(warning), findsNothing);
    },
  );
}
