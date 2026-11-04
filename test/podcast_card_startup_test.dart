import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as images;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_widgets.dart';
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/widgets/media_artwork_view.dart';

final reference = podcastArtworkRef(
  ownerKind: 'channel',
  ownerId: 'startup-channel',
  primaryUrl: 'https://example.test/cover.png',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppStorageService previousStorage;
  late PodcastRuntime runtime;
  late String coverPath;
  MediaArtworkRepository? validationRepository;

  Future<void> decodeCover(WidgetTester tester) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      if (tester.widget<RawImage>(find.byType(RawImage)).image != null) return;
    }
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('podcast-card-startup-');
    previousStorage = AppStorageService.instance;
    AppStorageService.instance = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.windows,
        support: Directory(p.join(root.path, 'support')),
        documents: Directory(p.join(root.path, 'documents')),
        defaultData: Directory(p.join(root.path, 'data')),
        executable: Directory(p.join(root.path, 'program')),
      ),
    );
    await AppStorageService.instance.initialize();
    final directory = await AppStorageService.instance.featureDirectory(
      'podcasts',
    );
    final store = PodcastStore.open(p.join(directory.path, 'podcasts.sqlite'));
    final channel = PodcastChannel(
      id: 'startup-channel',
      feedUrl: 'https://example.test/rss',
      title: '启动封面',
      author: '播客作者',
      imageUrl: reference.primary!.url,
    );
    store.write('channel', channel.id, channel.toJson());
    store.close();
    final repository = await MediaArtworkRepository.open(
      await AppStorageService.instance.featureDirectory('artwork'),
      installAsActive: false,
      fetcher: (request) async => ArtworkFetchResponse(
        status: 200,
        headers: const {},
        bytes: images.encodePng(images.Image(width: 2, height: 2)),
        finalUri: request.uri,
      ),
    );
    coverPath = (await repository.load(reference)).localPath!;
    repository.close();
    runtime = PodcastRuntime();
    PodcastRuntime.debugOverride = runtime;
  });

  tearDown(() async {
    validationRepository?.close();
    validationRepository = null;
    await runtime.shutdown();
    PodcastRuntime.debugOverride = null;
    MediaArtworkRepository.debugOverride = null;
    AppStorageService.instance = previousStorage;
    await root.delete(recursive: true);
  });

  testWidgets('restart shows a local cover before full podcast startup', (
    tester,
  ) async {
    await tester.runAsync(
      () => Future.wait([
        runtime.prepareCardArtwork(),
        runtime.prepareCardArtwork(),
      ]),
    );
    expect(runtime.ready, isFalse);
    final collection = VideoCollection(
      id: 'startup-card',
      name: '启动封面',
      createTime: 1,
      podcastRef: const PodcastChannelRef(
        channelId: 'startup-channel',
        feedUrl: 'https://example.test/rss',
      ),
    );
    expect(podcastLibrarySummary(collection), '播客作者');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 160,
            height: 90,
            child: PodcastCardCover(collection: collection),
          ),
        ),
      ),
    );

    // The very first build has a file image, without waiting for a stream
    // notification, playback services, or a fade-in timer.
    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect((resized.imageProvider as FileImage).file.path, coverPath);
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(runtime.artwork!.diagnostics.network, 0);
    await decodeCover(tester);
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());

    // A local-only startup also releases its database for storage migration.
    await tester.runAsync(runtime.prepareStorageMigration);
    expect(runtime.artwork, isNull);
    await tester.runAsync(runtime.prepareCardArtwork);
    expect(runtime.artwork!.cachedSnapshot(reference)!.localPath, coverPath);
  });

  testWidgets('expired cover stays visible while validation is waiting', (
    tester,
  ) async {
    final response = Completer<ArtworkFetchResponse>();
    late MediaArtworkRepository repository;
    var requests = 0;
    await tester.runAsync(() async {
      repository = await MediaArtworkRepository.open(
        await AppStorageService.instance.featureDirectory('artwork'),
        installAsActive: false,
        clock: () => DateTime.now().add(const Duration(days: 8)),
        fetcher: (request) {
          requests++;
          return response.future;
        },
      );
    });
    MediaArtworkRepository.debugOverride = repository;
    validationRepository = repository;
    await tester.pumpWidget(
      MaterialApp(home: MediaArtworkView(reference: reference, size: 80)),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(AnimatedOpacity), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    expect(requests, 1);
    expect(find.byType(Image), findsOneWidget);
    response.complete(
      ArtworkFetchResponse(
        status: 304,
        headers: const {},
        bytes: const [],
        finalUri: Uri.parse(reference.primary!.url),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    await decodeCover(tester);
    expect(repository.diagnostics.notModified, 1);
    expect(repository.cachedSnapshot(reference)!.localPath, coverPath);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
