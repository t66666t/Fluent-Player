import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/desktop_media_artwork.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';

VideoItem _item(String path) => VideoItem(
  id: 'cover',
  path: 'test.wav',
  title: 'Cover test',
  thumbnailPath: path,
  durationMs: 1000,
  lastUpdated: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DesktopMediaArtwork artwork;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('desktop_artwork_test_');
    artwork = DesktopMediaArtwork();
  });
  tearDown(() async {
    await artwork.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'default application artwork is a readable PNG and removed on disposal',
    () async {
      final path = await artwork.fallback();
      expect(path, isNotNull);
      final file = File(path!);
      expect((await file.readAsBytes()).take(8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
      await artwork.dispose();
      expect(await file.exists(), false);
    },
  );

  test(
    'normalizes GIF and handles file URIs, unicode, and late generated covers',
    () async {
      final file = File('${directory.path}/封面 #1.gif');
      final item = _item(file.uri.toString());
      expect(await artwork.resolve(item), isNull);
      await file.writeAsBytes(
        base64Decode(
          'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
        ),
      );
      final path = await artwork.resolve(item);
      expect(path, isNotNull);
      expect((await File(path!).readAsBytes()).take(8), [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ]);
      await file.writeAsString('corrupt artwork');
      expect(await artwork.resolve(item), isNull);
    },
  );

  test('remote artwork reuses the shared download cache', () async {
    final data = await rootBundle.load(
      'android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png',
    );
    var fetches = 0;
    final repository = await MediaArtworkRepository.open(
      Directory('${directory.path}/repository'),
      installAsActive: false,
      fetcher: (request) async {
        fetches++;
        return ArtworkFetchResponse(
          status: 200,
          headers: const {
            'content-type': 'image/png',
            'cache-control': 'max-age=3600',
          },
          bytes: data.buffer.asUint8List(),
          finalUri: request.uri,
        );
      },
    );
    MediaArtworkRepository.debugOverride = repository;
    addTearDown(repository.close);
    const url = 'https://example.test/cover.png';
    await repository.load(
      const ArtworkRef(
        ownerKind: 'existing-page',
        ownerId: 'cover',
        primary: ArtworkRequest(url: url, adapter: ArtworkAdapter.generic),
      ),
    );
    final path = await artwork.resolve(_item(url));
    expect(path, isNotNull);
    expect(fetches, 1);
    expect(await File(path!).exists(), true);
  });
}
