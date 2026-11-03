import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_task_store.dart';
import 'package:video_player_app/services/video_compose_manager.dart';

import 'support/compose_queue_fakes.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.documents, this.support, this.cache);
  final Directory documents, support, cache;
  int documentRequests = 0;

  @override
  Future<String?> getApplicationDocumentsPath() async {
    documentRequests++;
    return documents.path;
  }

  @override
  Future<String?> getApplicationSupportPath() async => support.path;

  @override
  Future<String?> getTemporaryPath() async => cache.path;
}

// Records the actual store boundary while retaining all real disk operations.
class _ObservedStore extends VideoComposeTaskStore {
  int loads = 0, saves = 0;
  Completer<void>? readGate;

  @override
  Future<List<VideoComposeTaskState>> loadTasks() async {
    loads++;
    await readGate?.future;
    return super.loadTasks();
  }

  @override
  Future<void> saveTasks(Iterable<VideoComposeTaskState> tasks) {
    saves++;
    return super.saveTasks(tasks);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, documents, support, cache, program;
  late PathProviderPlatform previousPaths;
  late AppStorageService previousStorage, storage;
  late _Paths paths;
  late Completer<void> storageGate;
  bool rejectStorage = false;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('compose_startup_');
    documents = await Directory(p.join(root.path, 'documents')).create();
    support = await Directory(p.join(root.path, 'support')).create();
    cache = await Directory(p.join(root.path, 'cache')).create();
    program = await Directory(p.join(root.path, 'program')).create();
    previousPaths = PathProviderPlatform.instance;
    paths = _Paths(documents, support, cache);
    PathProviderPlatform.instance = paths;
    previousStorage = AppStorageService.instance;
    storageGate = Completer<void>();
    rejectStorage = false;
    storage = AppStorageService(
      locations: () async {
        await storageGate.future;
        if (rejectStorage) {
          throw const StorageUnavailableException('test storage unavailable');
        }
        return StorageLocations(
          platform: StoragePlatform.android,
          support: support,
          documents: documents,
          defaultData: documents,
          executable: program,
          cache: cache,
        );
      },
    );
    AppStorageService.instance = storage;
  });

  tearDown(() async {
    AppStorageService.instance = previousStorage;
    PathProviderPlatform.instance = previousPaths;
    SettingsService().resetForTest();
    // All paths belong to this fixture's newly created temporary directory.
    await root.delete(recursive: true);
  });

  Future<File> seed({bool legacyDocuments = false}) async {
    final file = File(
      p.join(
        (legacyDocuments ? documents : support).path,
        'compose_tasks.json',
      ),
    );
    await file.writeAsString(
      jsonEncode([composeRecord('completed-before-restart').toJson()]),
      flush: true,
    );
    return file;
  }

  List<String> storedIds(File file) =>
      (jsonDecode(file.readAsStringSync()) as List)
          .map((entry) => (entry as Map)['taskId'] as String)
          .toList();

  Future<void> initializeStorage() async {
    if (!storageGate.isCompleted) storageGate.complete();
    await storage.initialize();
  }

  ({VideoComposeManager manager, ControlledComposeOrchestrator runner}) create(
    _ObservedStore store, {
    bool deferred = true,
  }) {
    final library = LibraryService()..resetLibraryForTesting();
    final runner = ControlledComposeOrchestrator();
    final manager = VideoComposeManager(
      library: library,
      taskStore: store,
      orchestrator: runner,
      deferTaskLoading: deferred,
    );
    addTearDown(() async {
      rejectStorage = false;
      await initializeStorage();
      final readGate = store.readGate;
      if (readGate != null && !readGate.isCompleted) readGate.complete();
      await manager.initialize();
      for (final done in runner.running.values) {
        if (!done.isCompleted) done.complete();
      }
      await Future<void>.delayed(Duration.zero);
      await store.loadTasks(); // join pending completion-status writes
      manager.dispose();
      library.resetLibraryForTesting();
    });
    return (manager: manager, runner: runner);
  }

  test('early enqueue waits for storage and loaded support history', () async {
    final file = await seed();
    final original = file.readAsBytesSync();
    final store = _ObservedStore();
    final context = create(store);
    var finished = false;
    final enqueued = enqueueCompose(context.manager, 'new').then((task) {
      finished = true;
      return task;
    });
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    expect(store.loads, 0);
    expect(store.saves, 0);
    expect(paths.documentRequests, 0);
    expect(context.runner.started, isEmpty);
    expect(file.readAsBytesSync(), original);

    await initializeStorage();
    await context.manager.initialize();
    final added = await enqueued;
    await const VideoComposeTaskStore().loadTasks();
    expect(storage.metadataDirectory.path, support.path);
    expect(
      context.manager.allTasks.map((e) => e.taskId),
      containsAll(['completed-before-restart', added.taskId]),
    );
    expect(
      storedIds(file),
      containsAll(['completed-before-restart', added.taskId]),
    );
    expect(storedIds(file), hasLength(2));
  });

  test(
    'early migration save cannot overwrite unread support history',
    () async {
      final file = await seed();
      final original = file.readAsBytesSync();
      final store = _ObservedStore();
      final context = create(store);
      var saved = false;
      final saving = context.manager.prepareStorageMigration().then((_) {
        saved = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(saved, isFalse);
      expect(store.loads, 0);
      expect(store.saves, 0);
      expect(file.readAsBytesSync(), original);

      await initializeStorage();
      await context.manager.initialize();
      await saving;
      expect(store.loads, 1);
      expect(store.saves, 1);
      expect(storedIds(file), ['completed-before-restart']);
    },
  );

  test(
    'initialize is idempotent and enqueue waits for the actual read',
    () async {
      final file = await seed();
      await initializeStorage();
      final store = _ObservedStore()..readGate = Completer<void>();
      final context = create(store);
      final first = context.manager.initialize();
      final second = context.manager.initialize();
      expect(identical(first, second), isTrue);
      var finished = false;
      final enqueued = enqueueCompose(context.manager, 'new').then((task) {
        finished = true;
        return task;
      });
      await Future<void>.delayed(Duration.zero);
      expect(store.loads, 1);
      expect(store.saves, 0);
      expect(finished, isFalse);
      expect(context.runner.started, isEmpty);
      expect(storedIds(file), ['completed-before-restart']);

      store.readGate!.complete();
      await first;
      final added = await enqueued;
      await const VideoComposeTaskStore().loadTasks();
      expect(store.loads, 1);
      expect(
        storedIds(file),
        containsAll(['completed-before-restart', added.taskId]),
      );
    },
  );

  test(
    'failed bootstrap leaves history untouched until storage retry',
    () async {
      final file = await seed();
      final original = file.readAsBytesSync();
      final store = _ObservedStore();
      final context = create(store);
      final saving = context.manager.prepareStorageMigration();
      rejectStorage = true;
      await expectLater(
        initializeStorage(),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(storage.isReady, isFalse);
      expect(store.loads, 0);
      expect(store.saves, 0);
      expect(file.readAsBytesSync(), original);

      rejectStorage = false;
      await initializeStorage();
      await context.manager.initialize();
      await saving;
      expect(storedIds(file), ['completed-before-restart']);
    },
  );

  test(
    'legacy Documents metadata remains the selected record location',
    () async {
      final file = await seed(legacyDocuments: true);
      final store = _ObservedStore();
      final context = create(store);
      await initializeStorage();
      await context.manager.initialize();
      final added = await enqueueCompose(context.manager, 'new');
      await const VideoComposeTaskStore().loadTasks();
      expect(storage.metadataDirectory.path, documents.path);
      expect(
        storedIds(file),
        containsAll(['completed-before-restart', added.taskId]),
      );
      expect(
        File(p.join(support.path, 'compose_tasks.json')).existsSync(),
        isFalse,
      );
    },
  );

  test('default construction retains automatic task loading', () async {
    final file = await seed();
    await initializeStorage();
    final store = _ObservedStore();
    final context = create(store, deferred: false);
    await context.manager.ready;
    expect(store.loads, 1);
    expect(context.manager.allTasks.single.taskId, 'completed-before-restart');
    expect(storedIds(file), ['completed-before-restart']);
  });
}
