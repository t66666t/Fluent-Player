import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/widgets/media_artwork_view.dart';

const _primary = ArtworkRequest(
  url: 'https://example.test/primary.png',
  adapter: ArtworkAdapter.podcast,
);
const _fallback = ArtworkRequest(
  url: 'https://example.test/fallback.png',
  adapter: ArtworkAdapter.podcast,
);
const _ref = ArtworkRef(
  ownerKind: 'episode',
  ownerId: 'retention',
  primary: _primary,
);

List<int> _png(int red) => img.encodePng(
  img.Image(width: 2, height: 2)..setPixelRgba(0, 0, red, 30, 70, 255),
);

ArtworkFetchResponse _response(
  Uri uri,
  List<int> bytes, {
  bool persistent = false,
}) => ArtworkFetchResponse(
  status: 200,
  headers: {'cache-control': persistent ? 'max-age=3600' : 'no-store'},
  bytes: bytes,
  finalUri: uri,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'successful disk publication releases the superseded memory cover',
    () async {
      final root = await Directory.systemTemp.createTemp('artwork-promotion-');
      final first = _png(50), second = _png(200);
      var requests = 0;
      final repository = await MediaArtworkRepository.open(
        root,
        installAsActive: false,
        fetcher: (request) async => _response(
          request.uri,
          ++requests == 1 ? first : second,
          persistent: requests > 1,
        ),
      );
      addTearDown(() async {
        repository.close();
        await root.delete(recursive: true);
      });
      final original = await repository.load(_ref);
      expect(original.memoryBytes, orderedEquals(first));
      final promoted = await repository.load(_ref);
      expect(requests, 2);
      expect(promoted.localPath, isNotNull);
      expect(promoted.memoryBytes, isNull);
      expect(
        await File(promoted.localPath!).readAsBytes(),
        orderedEquals(second),
      );
      final cached = repository.cachedSnapshot(_ref)!;
      expect(cached.memoryBytes, isNull);
      expect(cached.localPath, promoted.localPath);
      expect(
        original.memoryBytes,
        orderedEquals(first),
        reason: 'existing consumers own their snapshot',
      );
    },
  );

  test('rejected replacement keeps a usable memory snapshot', () async {
    final root = await Directory.systemTemp.createTemp(
      'artwork-promotion-fail-',
    );
    var requests = 0;
    final bytes = _png(100);
    final repository = await MediaArtworkRepository.open(
      root,
      installAsActive: false,
      retryBase: Duration.zero,
      fetcher: (request) async => _response(
        request.uri,
        ++requests == 1 ? bytes : '<html>unavailable</html>'.codeUnits,
        persistent: requests > 1,
      ),
    );
    addTearDown(() async {
      repository.close();
      await root.delete(recursive: true);
    });
    final original = await repository.load(_ref);
    final rejected = await repository.load(_ref);
    expect(rejected.memoryBytes, same(original.memoryBytes));
    expect(
      repository.cachedSnapshot(_ref)!.memoryBytes,
      same(original.memoryBytes),
    );
  });

  testWidgets(
    'disk primary releases memoized memory fallback in the same view',
    (tester) async {
      late Directory root;
      late MediaArtworkRepository repository;
      final primaryResult = Completer<ArtworkFetchResponse>();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'artwork-fallback-retention-',
        );
        repository = await MediaArtworkRepository.open(
          root,
          installAsActive: false,
          fetcher: (request) async => request.uri.path == '/primary.png'
              ? primaryResult.future
              : _response(request.uri, _png(50)),
        );
        await repository.load(
          const ArtworkRef(
            ownerKind: 'episode',
            ownerId: 'fallback',
            primary: _fallback,
          ),
        );
      });
      MediaArtworkRepository.debugOverride = repository;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        MediaArtworkRepository.debugOverride = null;
        repository.close();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaArtworkView(
            reference: ArtworkRef(
              ownerKind: 'episode',
              ownerId: 'retention',
              primary: _primary,
              fallbacks: [_fallback],
            ),
            size: 64,
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(MediaArtworkView));
      expect(state.debugRetainedEncodedByteCount, greaterThan(0));
      await tester.runAsync(() async {
        primaryResult.complete(
          _response(Uri.parse(_primary.url), _png(200), persistent: true),
        );
      });
      for (
        var i = 0;
        i < 50 && repository.cachedSnapshot(_ref)?.localPath == null;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(repository.cachedSnapshot(_ref)!.localPath, isNotNull);
      expect(tester.state(find.byType(MediaArtworkView)), same(state));
      expect(state.debugRetainedEncodedByteCount, 0);
      final provider =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect(provider.imageProvider, isA<FileImage>());
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
