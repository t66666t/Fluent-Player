import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/storage_migration_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cache products, atomic generations, partials and native receipts migrate together',
    () async {
      SharedPreferences.setMockInitialValues({});
      final sandbox = await Directory.systemTemp.createTemp(
        'media_cache_migration_',
      );
      final previous = AppStorageService.instance;
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.windows,
          support: Directory(p.join(sandbox.path, 'support')),
          documents: Directory(p.join(sandbox.path, 'documents')),
          defaultData: Directory(p.join(sandbox.path, 'data')),
          executable: Directory(p.join(sandbox.path, 'program')),
        ),
      );
      AppStorageService.instance = storage;
      StorageMigrationCoordinator.participants.clear();
      StorageMigrationCoordinator.maintenance = false;
      addTearDown(() async {
        AppStorageService.instance = previous;
        StorageMigrationCoordinator.participants.clear();
        StorageMigrationCoordinator.maintenance = false;
        await sandbox.delete(recursive: true);
      });
      await storage.initialize();
      final tasks = await storage.downloadTasks('cloud_drive');
      final work = Directory(p.join(tasks.path, 'cache_task'))..createSync();
      final files = await storage.downloadFiles('cloud_drive');
      final output = File(p.join(files.path, 'cache_complete.mp4'))
        ..writeAsBytesSync([1, 2, 3]);
      final part = File(p.join(work.path, 'video.part'))
        ..writeAsBytesSync([9, 8, 7]);
      File('${part.path}.resume').writeAsBytesSync([6, 5]);
      File(
        '${part.path}.receipt.json',
      ).writeAsStringSync('{"identity":"stable","bytes":3}');
      final journal = await storage.dataRecord('media_cache.json');
      final snapshot = storage.encodePaths({
        'version': 1,
        'tasks': [
          {
            'workDirectory': work.path,
            'outputDirectory': files.path,
            'resume': {
              'preparedFile': part.path,
              'video': {'tempPath': part.path},
              'cloudParts': {
                'one': {'path': part.path},
              },
            },
          },
        ],
        'variants': [
          {
            'path': output.path,
            'source': {'legacyPath': output.path, 'thumbnail': output.path},
          },
        ],
      });
      await writeStorageJson(journal, snapshot);
      await writeStorageJson(journal, snapshot);
      final target = Directory(p.join(sandbox.path, 'moved'));
      var prepared = false;
      StorageMigrationCoordinator.register(
        StorageParticipant('cache-test', () async {
          prepared = true;
        }),
      );
      await StorageMigrationCoordinator(
        storage,
        availableBytes: (_) async => 1 << 40,
      ).migrate(target);
      expect(prepared, isTrue);
      final relocated =
          storage.decodePaths(
                jsonDecode(
                  File(
                    p.join(target.path, 'media_cache.json'),
                  ).readAsStringSync(),
                ),
              )
              as Map;
      final task = (relocated['tasks'] as List).single as Map;
      expect(p.isWithin(target.path, task['workDirectory'] as String), isTrue);
      final path = (task['resume'] as Map)['preparedFile'] as String;
      expect(p.isWithin(target.path, path), isTrue);
      expect(File(path).readAsBytesSync(), [9, 8, 7]);
      expect(File('$path.resume').readAsBytesSync(), [6, 5]);
      expect(File('$path.receipt.json').existsSync(), isTrue);
      expect(
        File(p.join(target.path, 'media_cache.json.bak')).existsSync(),
        isTrue,
      );
      expect(
        part.existsSync(),
        isTrue,
        reason: 'migration retains the original until commit is verified',
      );
    },
  );
}
