import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/widgets/media_artwork_view.dart';
import 'package:video_player_app/widgets/media_card_preparation.dart';

final _reference = ArtworkRef(
  ownerKind: 'episode',
  ownerId: 'memory-cover',
  primary: ArtworkRequest(
    url: 'https://example.test/cover.png',
    adapter: ArtworkAdapter.podcast,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'nonpersistent cover owns compact bytes and never writes a blob',
    () async {
      final root = await Directory.systemTemp.createTemp('artwork-memory-');
      final responseBytes = image_lib.encodePng(
        image_lib.Image(width: 2, height: 2),
      );
      final expected = Uint8List.fromList(responseBytes);
      final repository = await MediaArtworkRepository.open(
        root,
        installAsActive: false,
        fetcher: (request) async => ArtworkFetchResponse(
          status: 200,
          headers: const {'cache-control': 'no-store'},
          bytes: responseBytes,
          finalUri: request.uri,
        ),
      );
      addTearDown(() async {
        repository.close();
        await root.delete(recursive: true);
      });

      final snapshot = await repository.load(_reference);
      expect(snapshot.hasImage, isTrue);
      expect(snapshot.memoryBytes, isA<Uint8List>());
      expect(identical(snapshot.memoryBytes, responseBytes), isFalse);
      responseBytes.fillRange(0, responseBytes.length, 0);
      expect(snapshot.memoryBytes, orderedEquals(expected));
      expect(await Directory('${root.path}/blobs').list().toList(), isEmpty);

      final cached = await repository.watch(_reference).first;
      expect(identical(cached.memoryBytes, snapshot.memoryBytes), isTrue);
    },
  );

  testWidgets(
    'late shared cover appears after preparation deadline without scrolling',
    (tester) async {
      late Directory root;
      late MediaArtworkRepository repository;
      final response = Completer<ArtworkFetchResponse>();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('late-artwork-');
        repository = await MediaArtworkRepository.open(
          root,
          installAsActive: false,
          fetcher: (_) => response.future,
        );
      });
      MediaArtworkRepository.debugOverride = repository;
      addTearDown(() async {
        MediaArtworkRepository.debugOverride = null;
        repository.close();
        await root.delete(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MediaCardPreparationHost(
            child: MediaArtworkView(
              reference: _reference,
              size: 64,
              placeholder: const Text('waiting'),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('waiting'), findsOneWidget);
      await tester.runAsync(() async {
        response.complete(
          ArtworkFetchResponse(
            status: 200,
            headers: const {'cache-control': 'no-store'},
            bytes: image_lib.encodePng(image_lib.Image(width: 2, height: 2)),
            finalUri: Uri.parse('https://example.test/cover.png'),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('waiting'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('fifty parent rebuilds reuse one decoded image cache key', (
    tester,
  ) async {
    late Directory root;
    late MediaArtworkRepository repository;
    var fetches = 0;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('artwork-rebuild-');
      repository = await MediaArtworkRepository.open(
        root,
        installAsActive: false,
        fetcher: (request) async {
          fetches++;
          return ArtworkFetchResponse(
            status: 200,
            headers: const {'cache-control': 'no-store'},
            bytes: image_lib.encodePng(image_lib.Image(width: 2, height: 2)),
            finalUri: request.uri,
          );
        },
      );
    });
    MediaArtworkRepository.debugOverride = repository;
    final tick = ValueNotifier(0);
    addTearDown(() async {
      tick.dispose();
      MediaArtworkRepository.debugOverride = null;
      repository.close();
      await root.delete(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: tick,
          builder: (_, value, _) => MediaArtworkView(
            reference: _reference,
            size: 64,
            placeholder: Text('waiting-$value'),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    });
    await tester.pumpAndSettle();
    final first = tester.widget<Image>(find.byType(Image)).image;
    final initialFetches = fetches;
    for (var i = 1; i <= 50; i++) {
      tick.value = i;
      await tester.pump();
      expect(tester.widget<Image>(find.byType(Image)).image, first);
    }
    expect(fetches, initialFetches);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
