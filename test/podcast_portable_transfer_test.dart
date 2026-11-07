import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/portable_transfer/portable_folder_transfer.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'podcast_core_test.dart' show podcastFixture;

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'temporary');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'podcast folder transfer restores RSS and episode progress without cached audio',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'podcast-portable-',
      );
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(temporary.path);
      SharedPreferences.setMockInitialValues({});
      SettingsService().resetForTest();
      SettingsService().largeDataRootPath = temporary.path;
      final library = LibraryService()..resetLibraryForTesting();
      await library.init();
      library.skipImportSidecarWorkForTesting = true;
      final sourceStore = PodcastStore(sqlite3.openInMemory()),
          receiverStore = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      final sourceController = PodcastController(
        store: sourceStore,
        client: client,
        mediaStore: PodcastMediaStore(
          root: Directory(p.join(temporary.path, 'source-media')),
          store: sourceStore,
          http: client.http,
        ),
      );
      final receiverController = PodcastController(
        store: receiverStore,
        client: client,
        mediaStore: PodcastMediaStore(
          root: Directory(p.join(temporary.path, 'receiver-media')),
          store: receiverStore,
          http: client.http,
        ),
      );
      final service = PortableTransferService.forTesting(),
          transferService = PortableTransferService.forTesting();
      final transfer = PortableFolderTransfer(service: transferService);
      try {
        PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
          sourceController,
          library: library,
        );
        final feed = client.parser.parse(
          utf8.encode(podcastFixture()),
          'https://example.com/rss',
        );
        feed.channel.imageUrl = '';
        final card = await PodcastRuntime.instance.subscribe(feed);
        final episode = sourceStore.episodes().single;
        sourceController.updateState(episode.id, (s) {
          s.positionMs = 12345;
          s.favorite = true;
        });
        sourceStore.setSetting(feed.channel.id, 'speed', 1.5);
        sourceStore.setSetting(null, 'includeDownloadsInExport', true);
        await PodcastRuntime.instance.itemFor(episode);
        final mediaFile = File(p.join(temporary.path, 'episode.mp3'));
        const audioMarker = 'PODCAST-NETWORK-ORIGINAL-AUDIO-BYTES';
        await mediaFile.writeAsBytes([
          ...utf8.encode('ID3$audioMarker'),
          ...List.generate(10240, (i) => i % 251),
        ]);
        await sourceController.mediaStore.importFile(
          episode,
          episode.media.first,
          mediaFile,
        );
        final prepared = await transfer.prepareFolderPackage(
          library: library,
          collectionId: card!.id,
          outputPath: p.join(temporary.path, 'podcast.fluentpack'),
        );
        final archive = ZipDecoder().decodeBytes(
          await File(prepared.path).readAsBytes(),
        );
        final files = archive.files.where((entry) => entry.isFile).toList();
        expect(
          files.any(
            (entry) => latin1.decode(entry.content).contains(audioMarker),
          ),
          isFalse,
          reason:
              'Even an old includeDownloadsInExport preference must not '
              'send podcast audio over LAN.',
        );
        expect(
          files.where(
            (entry) => p.extension(entry.name).toLowerCase() == '.mp3',
          ),
          isEmpty,
        );
        final manifestEntry = files.singleWhere(
          (entry) => p.basename(entry.name) == 'manifest.json',
        );
        final manifest = jsonDecode(utf8.decode(manifestEntry.content)) as Map;
        final snapshot = manifest['snapshot'] as Map;
        final bundle = (snapshot['podcasts'] as List).single as Map;
        expect((bundle['channel'] as Map)['feedUrl'], feed.channel.feedUrl);
        expect(
          (bundle['episodes'] as List).map((value) => (value as Map)['id']),
          contains(episode.id),
        );
        expect(
          ((bundle['states'] as Map)[episode.id] as Map)['positionMs'],
          12345,
        );
        expect(
          sourceController.mediaStore.isDownloaded(
            episode.id,
            episode.media.first.url,
          ),
          isTrue,
          reason:
              'Preparing a metadata-only transfer must retain the source download.',
        );
        library.resetLibraryForTesting();
        library.skipImportSidecarWorkForTesting = true;
        PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
          receiverController,
          library: library,
        );
        receiverStore.setSetting(feed.channel.id, 'speed', 2.0);
        receiverStore.setSetting(feed.channel.id, 'autoDownload', false);
        final received = await transfer.importReceivedFolder(
          library: library,
          packagePath: prepared.path,
          originDeviceId: 'sender',
          sourceCollectionId: card.id,
        );
        expect(
          library.getCollection(received.collectionId)!.podcastRef!.channelId,
          feed.channel.id,
        );
        expect(receiverStore.state(episode.id).positionMs, 12345);
        expect(receiverStore.state(episode.id).favorite, isFalse);
        expect(
          receiverStore.episode(episode.id)?.sourceFeedUrl,
          feed.channel.feedUrl,
        );
        expect(receiverStore.effective(feed.channel.id).number('speed'), 2.0);
        expect(
          receiverStore.effective(feed.channel.id).flag('autoDownload'),
          isFalse,
        );
        expect(
          receiverController.mediaStore.isDownloaded(
            episode.id,
            episode.media.first.url,
          ),
          isFalse,
        );
        expect(
          library
              .mediaInFolderTree(received.collectionId)
              .single
              .sourceRef!
              .podcast!
              .episodeId,
          episode.id,
        );
        receiverController.updateState(episode.id, (state) {
          state.positionMs = 9000;
          state.played = true;
        }, project: false);
        await transfer.importReceivedFolder(
          library: library,
          packagePath: prepared.path,
          originDeviceId: 'sender',
          sourceCollectionId: card.id,
          existingTargetCollectionId: received.collectionId,
        );
        expect(receiverStore.state(episode.id).positionMs, 9000);
        expect(receiverStore.state(episode.id).played, isTrue);
        expect(receiverStore.effective(feed.channel.id).number('speed'), 2.0);
        expect(
          receiverStore.effective(feed.channel.id).flag('autoDownload'),
          isFalse,
        );
      } finally {
        PodcastRuntime.debugOverride = null;
        service.dispose();
        transferService.dispose();
        await sourceController.close();
        await receiverController.close();
        sourceStore.close();
        receiverStore.close();
        library.resetLibraryForTesting();
        SettingsService().resetForTest();
        PathProviderPlatform.instance = oldPaths;
        if (await temporary.exists()) await temporary.delete(recursive: true);
      }
    },
  );
}
