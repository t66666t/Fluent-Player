import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/local_filesystem_path.dart';

/// Headless L3 smoke: normalize a known test asset path and import into the
/// library without GUI / media_kit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform originalPathProvider;

  const enSample =
      '/workspace/Video-master-test/videos/en/en_dialogue_practice.mp4';
  const zhSample =
      '/workspace/Video-master-test/videos/zh/zh_dialogue_practice.mp4';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('linux_l3_import_');
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
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('file:// en/zh sample paths import into LibraryService', () async {
    for (final raw in <String>[
      'file://$enSample',
      'file://$zhSample',
    ]) {
      final path = normalizeLocalFilesystemPath(raw);
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue, reason: path);
    }

    final en = normalizeLocalFilesystemPath('file://$enSample')!;
    final zh = normalizeLocalFilesystemPath(zhSample)!;
    final result = await library.importVideosBackground(
      [en, zh],
      null,
      useOriginalPath: true,
    );
    expect(result.createdVideoIds, hasLength(2));
    final paths = result.createdVideoIds
        .map((id) => library.getVideo(id)!.path)
        .toSet();
    expect(paths.contains(en), isTrue);
    expect(paths.contains(zh), isTrue);
  }, skip: !(File(enSample).existsSync() && File(zhSample).existsSync()));
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => p.join(root, 'support');

  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'tmp');

  @override
  Future<String?> getDownloadsPath() async => p.join(root, 'Downloads');
}
