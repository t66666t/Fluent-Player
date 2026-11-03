import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
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
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

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

Map<String, dynamic> _episode(
  String exportId, {
  String channelId = 'channel',
  String episodeId = 'episode',
  String feed = 'https://example.com/feed.xml',
  String media = 'https://example.com/episode.mp3',
}) => {
  'exportId': exportId,
  'parentExportId': 'subscription',
  'video': {
    'title': 'Episode',
    'durationMs': 1000,
    'type': 'audio',
    'sourceRef': {
      'value': media,
      'kind': 'podcastEpisode',
      'podcast': {
        'channelId': channelId,
        'episodeId': episodeId,
        'feedUrl': feed,
        'mediaUrl': media,
      },
    },
  },
};

Map<String, dynamic> _snapshot() => {
  'collections': [
    {
      'exportId': 'subscription',
      'parentExportId': null,
      'name': 'Podcast',
      'podcastRef': {
        'channelId': 'channel',
        'feedUrl': 'https://example.com/feed.xml',
      },
    },
  ],
  'videos': [_episode('card')],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  late LibraryService library;
  late PodcastStore store;
  late PodcastController controller;
  late PortableTransferService transfer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'podcast-reference-validation-',
    );
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 1000;
    store = PodcastStore(sqlite3.openInMemory());
    final client = PodcastClient();
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: Directory(p.join(root.path, 'media')),
        store: store,
        http: client.http,
      ),
    );
    PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
      controller,
      library: library,
    );
    transfer = PortableTransferService.forTesting();
  });

  tearDown(() async {
    await library.saveProgress();
    transfer.dispose();
    PodcastRuntime.debugOverride = null;
    await controller.close();
    store.close();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previousPaths;
    await root.delete(recursive: true);
  });

  final invalid = <String, void Function(Map<String, dynamic>)>{
    'duplicate export IDs': (snapshot) {
      (snapshot['videos'] as List).add(_episode('subscription'));
    },
    'missing export identity': (snapshot) {
      ((snapshot['videos'] as List).single as Map).remove('exportId');
    },
    'folder cycle': (snapshot) {
      ((snapshot['collections'] as List).single as Map)['parentExportId'] =
          'subscription';
    },
    'missing parent folder': (snapshot) {
      ((snapshot['videos'] as List).single as Map)['parentExportId'] = 'absent';
    },
    'feed without host': (snapshot) {
      final collection = (snapshot['collections'] as List).single as Map;
      (collection['podcastRef'] as Map)['feedUrl'] = 'https:missing-host';
    },
    'feed with newline injection': (snapshot) {
      final collection = (snapshot['collections'] as List).single as Map;
      (collection['podcastRef'] as Map)['feedUrl'] =
          'https://example.com/feed.xml\r\nIconFile=C:/secret';
    },
    'local media URL': (snapshot) {
      snapshot['videos'] = [_episode('card', media: 'file:///C:/secret.mp3')];
    },
    'conflicting channel feed identities': (snapshot) {
      snapshot['videos'] = [
        _episode('card', feed: 'https://another.example/feed.xml'),
      ];
    },
    'path traversal in archive folder': (snapshot) {
      final collection = (snapshot['collections'] as List).single as Map;
      collection['archiveDirectory'] = '../outside';
    },
    'conflicting incoming episode media identities': (snapshot) {
      (snapshot['videos'] as List).add(
        _episode('another-card', media: 'https://example.com/another.mp3'),
      );
    },
    'conflicting incoming episode channel identities': (snapshot) {
      (snapshot['videos'] as List).add(
        _episode(
          'another-card',
          channelId: 'another-channel',
          feed: 'https://another.example/feed.xml',
        ),
      );
    },
  };

  for (final entry in invalid.entries) {
    test(
      '${entry.key} are rejected before any media or metadata is imported',
      () async {
        final snapshot = _snapshot();
        entry.value(snapshot);
        final archive = Archive()
          // A valid media candidate proves validation precedes ordinary scanning.
          ..addFile(ArchiveFile.string('ordinary.mp4', 'media bytes'))
          ..addFile(
            ArchiveFile.string(
              'fluent-podcast-references.json',
              jsonEncode({
                'format': 'fluent-podcast-references',
                'formatVersion': 1,
                'snapshot': snapshot,
              }),
            ),
          );
        final path = p.join(root.path, 'invalid.zip');
        await File(path).writeAsBytes(ZipEncoder().encode(archive));
        final task = await transfer.importArchive(
          library: library,
          archivePath: path,
          displayName: 'invalid.zip',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (task.isActive && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        if (task.isActive) {
          throw TimeoutException('reference import did not finish');
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(task.status, PortableTransferStatus.failed, reason: task.error);
        expect(task.error, contains('FormatException'));
        expect(library.storageVideos, isEmpty);
        expect(library.getContents(null), isEmpty);
        expect(store.channels, isEmpty);
        expect(store.episodes(), isEmpty);
        expect(controller.downloads, isEmpty);
        expect(await File(path).exists(), isTrue);
      },
    );
  }
}
