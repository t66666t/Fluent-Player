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
import 'package:video_player_app/models/video_collection.dart';
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
  late Directory root;
  late PathProviderPlatform oldPaths;
  final library = LibraryService();
  late PodcastStore store;
  late PodcastController controller;
  late PortableTransferService transfer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('podcast_reference_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 120000;
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
    transfer.dispose();
    PodcastRuntime.debugOverride = null;
    await controller.close();
    store.close();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });

  for (final format in PortableExportFormat.values) {
    test(
      '${format.name} exports downloaded podcast as links without any media payload',
      () async {
        final client = PodcastClient();
        final feed = client.parser.parse(
          utf8.encode(podcastFixture()),
          'https://example.com/rss',
        );
        feed.channel.imageUrl = '';
        final subscription = (await PodcastRuntime.instance.subscribe(feed))!;
        final episode = store.episodes().single;
        final item = await PodcastRuntime.instance.itemFor(
          episode,
          standalone: true,
        );
        final media = await File(
          p.join(root.path, 'episode.mp3'),
        ).writeAsString('private media never exported');
        await controller.mediaStore.importFile(
          episode,
          episode.media.first,
          media,
        );
        store.setSetting(null, 'includeDownloadsInExport', true);
        item.playbackPath = media.path;
        final output = p.join(
          root.path,
          'card.${format == PortableExportFormat.zip ? 'zip' : 'fluentpack'}',
        );
        final task = await transfer.exportSelection(
          library: library,
          rootIds: [item.id],
          outputPath: output,
          options: PortableExportOptions(packageName: '播客卡片', format: format),
        );
        await _wait(task, transfer);
        expect(
          task.status,
          PortableTransferStatus.completed,
          reason: task.error,
        );
        final input = InputFileStream(output);
        final archive = ZipDecoder().decodeStream(input);
        expect(
          archive.files.any(
            (entry) =>
                ['.mp3', '.mp4', '.m4a'].contains(p.extension(entry.name)),
          ),
          isFalse,
        );
        archive.clear();
        await input.close();
        library.resetLibraryForTesting();
        library.skipImportSidecarWorkForTesting = true;
        store.setSetting(episode.channelId, 'speed', 1.75);
        controller.updateState(episode.id, (state) => state.positionMs = 777);
        final incoming = format == PortableExportFormat.zip
            ? await transfer.importArchive(
                library: library,
                archivePath: output,
                displayName: 'card.zip',
              )
            : await transfer.importPackage(
                library: library,
                packagePath: output,
                preview: await transfer.inspectPackage(output),
              );
        await _wait(incoming, transfer);
        expect(
          incoming.status,
          PortableTransferStatus.completed,
          reason: incoming.error,
        );
        final restored = library.storageVideos.single;
        expect(restored.sourceRef?.podcast?.episodeId, episode.id);
        expect(restored.path, 'podcast:${episode.id}');
        expect(restored.playbackPath, isNull);
        expect(restored.subtitlePath, isNull);
        if (format == PortableExportFormat.zip) {
          expect(store.effective(episode.channelId).number('speed'), 1.75);
          expect(store.state(episode.id).positionMs, 777);
        }
        expect(subscription.podcastRef?.feedUrl, feed.channel.feedUrl);
      },
    );
  }

  test('ZIP channel card imports without any episode payload', () async {
    final client = PodcastClient();
    final feed = client.parser.parse(
      utf8.encode(podcastFixture()),
      'https://example.com/rss',
    );
    feed.channel.imageUrl = '';
    final subscription = (await PodcastRuntime.instance.subscribe(feed))!;
    final output = p.join(root.path, 'channel.zip');
    final task = await transfer.exportSelection(
      library: library,
      rootIds: [subscription.id],
      outputPath: output,
      options: const PortableExportOptions(
        packageName: '频道',
        format: PortableExportFormat.zip,
      ),
    );
    await _wait(task, transfer);
    expect(task.status, PortableTransferStatus.completed, reason: task.error);
    final input = InputFileStream(output);
    final archive = ZipDecoder().decodeStream(input);
    expect(archive.files.where((e) => e.name.endsWith('.url')), hasLength(1));
    archive.clear();
    await input.close();
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    final incoming = await transfer.importArchive(
      library: library,
      archivePath: output,
      displayName: 'channel.zip',
    );
    await _wait(incoming, transfer);
    expect(
      incoming.status,
      PortableTransferStatus.completed,
      reason: incoming.error,
    );
    final card = library.storageCollections.singleWhere(
      (c) => c.podcastRef != null,
    );
    expect(card.podcastRef!.channelId, feed.channel.id);
    expect(card.podcastRef!.feedUrl, feed.channel.feedUrl);
    expect(library.storageVideos, isEmpty);
    expect(incoming.itemCount, 1);
  });

  test(
    'mixed ZIP restores nested podcast links alongside media with no duplicate folder or settings change',
    () async {
      final client = PodcastClient();
      final feed = client.parser.parse(
        utf8.encode(podcastFixture()),
        'https://example.com/rss',
      );
      feed.channel.imageUrl = '';
      await PodcastRuntime.instance.subscribe(feed);
      final episode = store.episodes().single;
      final item = await PodcastRuntime.instance.itemFor(
        episode,
        standalone: true,
      );
      store.setSetting(episode.channelId, 'speed', 1.75);
      final archive = Archive()
        ..addFile(ArchiveFile.string('目录/movie.mp4', 'ordinary local video'))
        ..addFile(
          ArchiveFile.string(
            'fluent-podcast-references.json',
            jsonEncode({
              'format': 'fluent-podcast-references',
              'formatVersion': 1,
              'snapshot': {
                'collections': [
                  {
                    'exportId': 'parent',
                    'parentExportId': null,
                    'name': '目录',
                    'archiveDirectory': '目录',
                  },
                  {
                    'exportId': 'subscription',
                    'parentExportId': 'parent',
                    'name': '节目订阅',
                    'podcastRef': {
                      'channelId': episode.channelId,
                      'feedUrl': feed.channel.feedUrl,
                    },
                  },
                ],
                'videos': [
                  {
                    'exportId': 'card',
                    'parentExportId': 'parent',
                    'isOnline': true,
                    'video': {
                      ...item.toJson(),
                      'playbackPath': mediaPath(root),
                      'thumbnailPath': '@asset:../../secret',
                    },
                  },
                ],
                'podcasts': [
                  {
                    'channel': feed.channel.toJson(),
                    'episodes': [],
                    'states': {
                      episode.id: {
                        'positionMs': 999,
                        'updatedMs': 9999999999999,
                      },
                    },
                    'settings': {'speed': 9},
                    'settingsUpdatedMs': 9999999999999,
                    'globalSettings': {'pauseAllUpdates': true},
                    'globalSettingsUpdatedMs': 9999999999999,
                  },
                ],
              },
            }),
          ),
        );
      final output = p.join(root.path, 'mixed.zip');
      await File(output).writeAsBytes(ZipEncoder().encode(archive));
      library.resetLibraryForTesting();
      library.skipImportSidecarWorkForTesting = true;
      final task = await transfer.importArchive(
        library: library,
        archivePath: output,
        displayName: 'mixed.zip',
      );
      await _wait(task, transfer);
      expect(task.status, PortableTransferStatus.completed, reason: task.error);
      final importedRoot = library
          .getContents(null)
          .whereType<VideoCollection>()
          .single;
      final nested = library
          .getContents(importedRoot.id)
          .whereType<VideoCollection>()
          .single;
      expect(nested.name, '目录');
      expect(library.getContents(nested.id), hasLength(3));
      expect(
        library.storageVideos
            .where((v) => v.sourceRef?.podcast != null)
            .single
            .parentId,
        nested.id,
      );
      expect(store.effective(episode.channelId).number('speed'), 1.75);
      expect(store.state(episode.id).positionMs, isNot(999));
    },
  );
}

String mediaPath(Directory root) => p.join(root.path, 'private-media.mp3');

Future<void> _wait(
  PortableTransferTask task,
  PortableTransferService service,
) async {
  final done = Completer<void>();
  void changed() {
    if (!task.isActive && !done.isCompleted) done.complete();
  }

  service.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 25));
  } finally {
    service.removeListener(changed);
  }
}
