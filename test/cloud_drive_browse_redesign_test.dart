import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_directory_session.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_view_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'support/cloud_drive_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    await SettingsService().init();
  });
  tearDown(() => SettingsService().resetForTest());

  test(
    'natural names, reverse order, missing metadata and ties are stable',
    () {
      final entries = [
        cloudEntry('ten', name: '第10集.mp4', size: 10),
        cloudEntry('two', name: '第2集.mp4', size: 2),
        cloudEntry('unknown', name: '第3集.mp4'),
        cloudEntry('folder', name: '课程', kind: CloudDriveEntryKind.folder),
      ];
      expect(
        const CloudDriveViewOptions().project(entries).map((e) => e.fileId),
        ['folder', 'two', 'unknown', 'ten'],
      );
      expect(
        const CloudDriveViewOptions(
          descending: true,
        ).project(entries).map((e) => e.fileId),
        ['folder', 'ten', 'unknown', 'two'],
      );
      expect(
        const CloudDriveViewOptions(
          sort: CloudDriveViewSort.size,
          descending: true,
          foldersFirst: false,
        ).project(entries).map((e) => e.fileId).take(3),
        ['ten', 'two', 'unknown'],
      );
      for (final sort in CloudDriveViewSort.values) {
        final options = CloudDriveViewOptions(sort: sort, descending: true);
        expect(
          options.project(entries).map((e) => e.fileId),
          options.project(entries.reversed).map((e) => e.fileId),
        );
      }
    },
  );

  test(
    'filter and search keep accessible folders without including other media',
    () {
      final entries = [
        cloudEntry('folder', name: '课程', kind: CloudDriveEntryKind.folder),
        cloudEntry('v'),
        cloudEntry('a', kind: CloudDriveEntryKind.audio),
        cloudEntry('s', kind: CloudDriveEntryKind.subtitle),
      ];
      expect(
        const CloudDriveViewOptions(
          filter: CloudDriveViewFilter.audio,
        ).project(entries).map((e) => e.fileId),
        ['folder', 'a'],
      );
      expect(
        const CloudDriveViewOptions()
            .project(entries, query: '课')
            .single
            .fileId,
        'folder',
      );
    },
  );

  test('provider, account and sorting survive restoring preferences', () async {
    final prefs = await SharedPreferences.getInstance();
    final memory = CloudDriveViewPreferences(prefs);
    await memory.selectProvider('quark');
    await memory.selectAccount('quark', 'account-q');
    await memory.save(
      'quark',
      const CloudDriveViewOptions(
        sort: CloudDriveViewSort.size,
        descending: true,
      ),
    );
    final restored = CloudDriveViewPreferences(prefs);
    expect(restored.providerId, 'quark');
    expect(restored.accountId('quark'), 'account-q');
    expect(restored.options('quark').sort, CloudDriveViewSort.size);
    expect(restored.options('quark').descending, isTrue);
    expect(restored.options('baidu').sort, CloudDriveViewSort.naturalName);
  });

  test(
    'directory reads all pages and can resume a failed later page',
    () async {
      final provider = FixtureCloudProvider('baidu', {
        '/': [cloudEntry('10'), cloudEntry('2'), cloudEntry('3')],
      })..failOnce.add('/|2');
      final runtime = await cloudRuntime([provider]);
      addTearDown(runtime.shutdown);
      final session = CloudDriveDirectorySession(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        directoryId: '/',
      );
      addTearDown(session.release);
      await expectLater(session.finish(), throwsA(isA<CloudDriveFailure>()));
      expect(session.entries, hasLength(2));
      expect(session.complete, isFalse);
      await session.finish();
      expect(session.complete, isTrue);
      expect(session.entries, hasLength(3));
      expect(provider.calls.map((c) => c.cursor), [null, '2', '2']);
      expect(runtime.launch.library.storageVideos, isEmpty);
    },
  );

  test('a retained directory survives closing its browser owner', () async {
    final gate = Completer<void>();
    final provider = FixtureCloudProvider('baidu', {
      '/': [cloudEntry('a'), cloudEntry('b'), cloudEntry('c')],
    })..gates['/|2'] = gate;
    final runtime = await cloudRuntime([provider]);
    addTearDown(runtime.shutdown);
    final session = CloudDriveDirectorySession(
      runtime: runtime,
      account: runtime.accounts.accounts.single,
      directoryId: '/',
    );
    session.retain();
    final reading = session.finish();
    await Future<void>.delayed(Duration.zero);
    session.release();
    gate.complete();
    await reading;
    expect(session.entries, hasLength(3));
    session.release();
  });

  test(
    'valid cloud identities are queue eligible without local filesystem access',
    () {
      var fileChecks = 0;
      final policy = PlaybackQueuePolicy(
        sourceExists: (_) {
          fileChecks++;
          return false;
        },
      );
      final source = cloudDriveEntrySource(cloudEntry('a'));
      final item = VideoItem(
        id: 'placement-a',
        path: source.cloudDrive!.logicalUri,
        sourceRef: source,
        title: '独立名称',
        durationMs: 10,
        lastUpdated: 0,
      );
      expect(policy.isEligible(item), isTrue);
      expect(fileChecks, 0);
      item.isRecycled = true;
      expect(policy.isEligible(item), isFalse);
      item.isRecycled = false;
      item.sourceRef = const MediaSourceRef(
        value: 'bad',
        kind: MediaSourceKind.cloudDrive,
      );
      expect(policy.isEligible(item), isFalse);
    },
  );

  test(
    'queue waits for full sorted directory, excludes audio and keeps its origin',
    () async {
      final gate = Completer<void>();
      final a = cloudEntry('10', name: '第10集.mp4');
      final provider = FixtureCloudProvider('baidu', {
        '/': [
          a,
          cloudEntry('audio', kind: CloudDriveEntryKind.audio),
          cloudEntry('2', name: '第2集.mp4'),
          cloudEntry('3', name: '第3集.mp4'),
        ],
        '/other': [cloudEntry('other')],
      })..gates['/|2'] = gate;
      final runtime = await cloudRuntime([provider]);
      addTearDown(runtime.shutdown);
      final session = CloudDriveDirectorySession(
        runtime: runtime,
        account: runtime.accounts.accounts.single,
        directoryId: '/',
      );
      final reading = session.finish();
      await Future<void>.delayed(Duration.zero);
      final selected = await runtime.launch.prepareEntry(
        entry: a,
        visibleEntries: session.entries,
        directory: session,
      );
      expect(runtime.launch.playlist.playlist.single.id, selected.id);
      expect(runtime.launch.library.storageVideos, isEmpty);
      session.release();
      gate.complete();
      await reading;
      await runtime.launch.playback.cloudDrivePreparePlaylist!();
      expect(runtime.launch.playlist.playlist.map((v) => v.title), [
        '第2集.mp4',
        '第3集.mp4',
        '第10集.mp4',
      ]);
      expect(runtime.launch.playlist.currentItem?.id, selected.id);
      expect(runtime.launch.playlist.currentItem, same(selected));
      expect(runtime.launch.library.storageVideos, isEmpty);
      expect(runtime.launch.playlist.getPrevious()?.title, '第3集.mp4');
      runtime.launch.playlist.setPlaylist([]);
      expect(
        runtime.launch.playback.cloudDriveQueueNeedsCompletion!(),
        isFalse,
      );
    },
  );
}
