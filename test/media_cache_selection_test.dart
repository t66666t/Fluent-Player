import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/media_cache/media_cache_selection.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_runtime.dart';
import 'support/cloud_drive_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'recursive preview reads every page, filters media and deduplicates without importing',
    () async {
      final provider = FixtureCloudProvider('baidu', {
        '/folder': [
          cloudEntry('a', size: 100),
          cloudEntry('/child', kind: CloudDriveEntryKind.folder),
          cloudEntry('skip', kind: CloudDriveEntryKind.subtitle),
        ],
        '/child': [
          cloudEntry('b', size: 200, kind: CloudDriveEntryKind.audio),
          cloudEntry('a', size: 100),
        ],
      }, pageSize: 1);
      final runtime = await cloudRuntime([provider]);
      CloudDriveRuntime.instance = runtime;
      final collector = CacheSelectionCollector();
      addTearDown(() async {
        collector.dispose();
        await runtime.shutdown();
        CloudDriveRuntime.instance = null;
      });
      await collector.cloud([
        cloudEntry('/folder', kind: CloudDriveEntryKind.folder),
        cloudEntry('a'),
      ]);
      expect(collector.sources, hasLength(2));
      expect(collector.knownBytes, 300);
      expect(collector.skipped, 1);
      expect(provider.calls, hasLength(5));
      expect(runtime.launch.library.storageVideos, isEmpty);
    },
  );
  test(
    'failed directory remains an error and cannot silently create a partial batch',
    () async {
      final provider = FixtureCloudProvider('baidu', {
        '/folder': [cloudEntry('a'), cloudEntry('b')],
      }, pageSize: 1)..failOnce.add('/folder|1');
      final runtime = await cloudRuntime([provider]);
      CloudDriveRuntime.instance = runtime;
      final collector = CacheSelectionCollector();
      addTearDown(() async {
        collector.dispose();
        await runtime.shutdown();
        CloudDriveRuntime.instance = null;
      });
      await expectLater(
        collector.cloud([
          cloudEntry('/folder', kind: CloudDriveEntryKind.folder),
        ]),
        throwsA(isA<CloudDriveFailure>()),
      );
      expect(collector.sources, isEmpty);
      expect(collector.loading, isFalse);
      expect(runtime.launch.library.storageVideos, isEmpty);
    },
  );
}
