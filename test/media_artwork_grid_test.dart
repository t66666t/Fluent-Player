import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/widgets/media_artwork_view.dart';
import 'package:video_player_app/widgets/media_card_preparation.dart';
import 'package:video_player_app/widgets/media_cover_reveal.dart';

void main() {
  testWidgets(
    'repository artwork in a grid decodes and reveals with the cards',
    (tester) async {
      late Directory root;
      late MediaArtworkRepository repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('artwork-grid-');
        repository = await MediaArtworkRepository.open(
          root,
          installAsActive: false,
          fetcher: (request) async => ArtworkFetchResponse(
            status: 200,
            headers: const {'cache-control': 'no-store'},
            bytes: image_lib.encodePng(image_lib.Image(width: 4, height: 4)),
            finalUri: request.uri,
          ),
        );
      });
      MediaArtworkRepository.debugOverride = repository;
      ArtworkRevealMemory.shown.clear();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
              ),
              itemCount: 3,
              itemBuilder: (_, index) => MediaCoverRevealStamp(
                index: index,
                crossAxisCount: 3,
                child: MediaCardPreparationHost(
                  child: MediaArtworkView(
                    reference: ArtworkRef(
                      ownerKind: 'test',
                      ownerId: '$index',
                      primary: ArtworkRequest(
                        url: 'https://example.test/$index.png',
                        adapter: ArtworkAdapter.podcast,
                      ),
                    ),
                    size: 64,
                    placeholder: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 30));
        }
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(Image), findsNWidgets(3));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        MediaArtworkRepository.debugOverride = null;
        repository.close();
        await tester.runAsync(() => root.delete(recursive: true));
      }
    },
  );
}
