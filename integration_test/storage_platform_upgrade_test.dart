import 'package:video_player_app/services/storage_migration_coordinator.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/app_storage_service.dart';

/// Runs on each real platform in a separate app-owned probe directory. It
/// never opens or changes the user's real library, preferences or login data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native persistent paths survive storage-service recreation', (
    tester,
  ) async {
    final system = await StorageLocations.system();
    final probeBase = await Directory(
      p.join(system.support.path, 'storage-upgrade-probes'),
    ).create(recursive: true);
    final probe = await probeBase.createTemp('isolated-');
    expect(p.isAbsolute(system.defaultData.path), isTrue);
    expect(
      p.isWithin(system.executable.path, system.defaultData.path),
      isFalse,
    );
    try {
      final support = await Directory(p.join(probe.path, 'support')).create();
      final documents = await Directory(
        p.join(probe.path, 'documents'),
      ).create();
      final data = await Directory(p.join(probe.path, 'data')).create();
      final locations = StorageLocations(
        platform: system.platform,
        support: support,
        documents: documents,
        defaultData: data,
        executable: system.executable,
      );
      final storage = AppStorageService(locations: () async => locations);
      await storage.initialize();
      final media = File(p.join(data.path, 'imported_media', '中文 name.mp4'));
      await media.parent.create();
      await media.writeAsString('unchanged');
      final snapshot = storage.encodePaths({
        'path': media.path,
        'lastPositionMs': 12345,
      });
      final record = File(p.join(data.path, 'probe.json'));
      await writeStorageJson(record, snapshot);
      if (storage.desktop) {
        await StorageMigrationCoordinator(
          storage,
        ).migrate(Directory(p.join(probe.path, 'relocated')));
      }
      final recreated = AppStorageService(locations: () async => locations);
      await recreated.initialize();
      final restored = recreated.decodePaths(
        jsonDecode(await record.readAsString()),
      );
      expect(restored['lastPositionMs'], 12345);
      expect(await File(restored['path']).readAsString(), 'unchanged');
      expect(p.isWithin(system.executable.path, data.path), isFalse);
    } finally {
      final allowed = await Directory(
        p.join(system.support.path, 'storage-upgrade-probes'),
      ).resolveSymbolicLinks();
      final resolved = await probe.resolveSymbolicLinks();
      if (!p.isWithin(allowed, resolved)) {
        throw StateError('Probe cleanup outside its isolated directory');
      }
      await probe.delete(recursive: true);
    }
  });
}
