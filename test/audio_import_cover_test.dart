import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform originalPathProvider;
  final jpeg = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9]);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('audio_import_cover_');
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

  test('folder import keeps embedded and sibling audio covers', () async {
    library.skipImportSidecarWorkForTesting = false;
    final folder = Directory(p.join(root.path, 'album'))..createSync();
    await File(p.join(folder.path, 'embedded.m4a')).writeAsBytes(_m4a(jpeg));
    await File(
      p.join(folder.path, 'plain.mp3'),
    ).writeAsBytes(List<int>.filled(16, 1));
    final sibling = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD1]);
    await File(p.join(folder.path, 'cover.jpg')).writeAsBytes(sibling);

    final result = await library.importFolderSelection(
      folder.path,
      null,
      sortOptions: const StructuredImportSortOptions(
        field: StructuredImportSortField.fileName,
        direction: StructuredImportSortDirection.ascending,
      ),
    );

    expect(result.importedVideoIds, hasLength(2));
    final embedded = library.getVideo(
      result.importedVideoIds.firstWhere(
        (id) => library.getVideo(id)!.path.endsWith('embedded.m4a'),
      ),
    )!;
    final plain = library.getVideo(
      result.importedVideoIds.firstWhere(
        (id) => library.getVideo(id)!.title.contains('plain'),
      ),
    )!;
    expect(embedded.hasProbedAudioCover, isTrue);
    expect(plain.hasProbedAudioCover, isTrue);
    expect(await File(embedded.thumbnailPath!).readAsBytes(), jpeg);
    expect(await File(plain.thumbnailPath!).readAsBytes(), sibling);
  });

  test(
    'copied folder import still finds cover.jpg beside the source',
    () async {
      library.skipImportSidecarWorkForTesting = false;
      SettingsService().copyImportedMediaToPrivateStorage = true;
      // Files already inside the library data root are not copied again.
      final outside = await Directory.systemTemp.createTemp('audio_import_src_');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final folder = Directory(p.join(outside.path, 'ripped'))..createSync();
      final source = File(p.join(folder.path, 'track.mp3'));
      await source.writeAsBytes(List<int>.filled(16, 2));
      await File(p.join(folder.path, 'folder.jpg')).writeAsBytes(jpeg);

      final result = await library.importFolderSelection(
        folder.path,
        null,
        sortOptions: const StructuredImportSortOptions(
          field: StructuredImportSortField.fileName,
          direction: StructuredImportSortDirection.ascending,
        ),
      );

      final item = library.getVideo(result.importedVideoIds.single)!;
      expect(p.normalize(item.path), isNot(p.normalize(source.path)));
      expect(await File(item.thumbnailPath!).readAsBytes(), jpeg);
    },
  );

  test('file import reads the College Dropout ALAC cover', () async {
    const source =
        r"D:\BaiduNetdiskDownload\Kanye West - The College Dropout (ALAC 16bit_44kHz)\02. We Don't Care [L].m4a";
    if (!File(source).existsSync()) return;
    library.skipImportSidecarWorkForTesting = false;
    final result = await library.importVideosBackground(
      <String>[source],
      null,
      useOriginalPath: true,
    );
    expect(result.createdVideoIds, hasLength(1));
    final item = library.getVideo(result.createdVideoIds.single)!;
    expect(item.type.name, 'audio');
    expect(item.hasProbedAudioCover, isTrue);
    final cover = await File(item.thumbnailPath!).readAsBytes();
    expect(cover.length, 661467);
    expect(cover[0], 0xFF);
    expect(cover[1], 0xD8);
  });
}

Uint8List _m4a(Uint8List jpeg) {
  List<int> atom(String type, List<int> payload) {
    final size = 8 + payload.length;
    return <int>[
      (size >> 24) & 0xff,
      (size >> 16) & 0xff,
      (size >> 8) & 0xff,
      size & 0xff,
      ...type.codeUnits,
      ...payload,
    ];
  }

  return Uint8List.fromList(
    atom('moov', [
      ...atom('udta', [
        ...atom('meta', <int>[
          0,
          0,
          0,
          0,
          ...atom('ilst', [
            ...atom(
              'covr',
              atom('data', <int>[0, 0, 0, 13, 0, 0, 0, 0, ...jpeg]),
            ),
          ]),
        ]),
      ]),
    ]),
  );
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
