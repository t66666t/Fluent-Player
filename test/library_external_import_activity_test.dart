import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp(
      'library_external_import_s03_',
    );
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 1000;
    await library.init();
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    SettingsService().resetForTest();
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // A native test may briefly retain a handle to the temporary fixture.
    }
  });

  test(
    'same source still creates independent cards in one explicit batch',
    () async {
      final file = await File(
        p.join(root.path, 'same.mp4'),
      ).writeAsBytes(List<int>.generate(16, (i) => i));
      final batchId = library.beginImportBatch(
        title: 'B站在线 2 项',
        sourceKind: LibraryImportSourceKind.bilibili,
      );
      for (final id in <String>['card-a', 'card-b']) {
        await library.addSingleVideo(
          VideoItem(
            id: id,
            path: file.path,
            title: id,
            durationMs: 1000,
            lastUpdated: 1,
            hasProbedChapters: true,
          ),
          useOriginalPath: true,
          reuseExistingItem: false,
          activityBatchId: batchId,
          sourceKind: LibraryImportSourceKind.bilibili,
        );
      }
      await library.completeImportBatch(batchId!);

      expect(library.getVideo('card-a'), isNotNull);
      expect(library.getVideo('card-b'), isNotNull);
      expect(library.importBatches, hasLength(1));
      expect(library.importBatches.single.createdMediaIds, [
        'card-a',
        'card-b',
      ]);
      expect(
        library.importBatches.single.sourceKind,
        LibraryImportSourceKind.bilibili,
      );
    },
  );

  test(
    'removing a browser task during preparation prevents the library commit',
    () async {
      final file = await File(
        p.join(root.path, 'cancelled_browser.mp4'),
      ).writeAsBytes(List<int>.generate(16, (i) => i));
      var checks = 0;
      final result = await library.importVideosBackground(
        [file.path],
        null,
        useOriginalPath: true,
        allowCacheRescue: false,
        shouldContinue: () => ++checks < 2,
      );
      expect(checks, 2);
      expect(result.createdVideoIds, isEmpty);
      expect(library.importBatches, isEmpty);
      expect(await file.exists(), isTrue);
    },
  );

  test('yt-dlp auto import of one task is its own batch', () async {
    final file = await File(
      p.join(root.path, 'yt.mp4'),
    ).writeAsBytes(List<int>.generate(16, (i) => i + 3));
    final batchId = library.beginImportBatch(
      title: 'YT-DLP',
      sourceKind: LibraryImportSourceKind.ytDlp,
    );
    await library.addSingleVideo(
      VideoItem(
        id: 'yt-1',
        path: file.path,
        title: 'yt-1',
        durationMs: 1000,
        lastUpdated: 1,
        hasProbedChapters: true,
      ),
      useOriginalPath: true,
      activityBatchId: batchId,
      sourceKind: LibraryImportSourceKind.ytDlp,
    );
    await library.completeImportBatch(batchId!);
    expect(
      library.importBatches.single.sourceKind,
      LibraryImportSourceKind.ytDlp,
    );
    expect(library.importBatches.single.createdMediaIds, ['yt-1']);
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);
  final String rootPath;
  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
