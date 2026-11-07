import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_cache_dialog.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_readiness.dart';
import 'package:video_player_app/features/portable_transfer/portable_media_selection.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

class _ForbiddenCache extends ChangeNotifier implements MediaCacheService {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('readiness must not acquire online media');
  }
}

class _ReadinessLibrary extends ChangeNotifier implements LibraryService {
  final items = <String, VideoItem>{};
  @override
  void seedVideoForTesting(VideoItem item) => items[item.id] = item;
  @override
  VideoItem? getVideo(String id) => items[id];
  @override
  List<dynamic> getContents(String? parentId) =>
      items.values.where((item) => item.parentId == parentId).toList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _ReadinessLibrary library;
  late _ForbiddenCache cache;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('local-export-readiness-');
    library = _ReadinessLibrary();
    cache = _ForbiddenCache();
  });
  tearDown(() async {
    library.dispose();
    cache.dispose();
    await root.delete(recursive: true);
  });

  VideoItem item(String id, String path, MediaSourceKind kind) => VideoItem(
    id: id,
    path: path,
    title: id,
    durationMs: 1000,
    lastUpdated: 1,
    sourceRef: MediaSourceRef(kind: kind, value: 'retained-origin'),
  );

  test(
    'local files retain export readiness for every historical source kind without cache access',
    () async {
      final local = await File(
        p.join(root.path, 'local.mp4'),
      ).writeAsBytes([1, 2, 3]);
      for (final kind in [
        MediaSourceKind.bilibiliStream,
        MediaSourceKind.cloudDrive,
        MediaSourceKind.podcastEpisode,
      ]) {
        final media = item(kind.name, local.path, kind);
        library.seedVideoForTesting(media);
        expect(
          await uncachedCloudExportItems(library, [media.id], cache: cache),
          isEmpty,
        );
        final tree = PortableTreeIndex.fromLibrary(library);
        expect(tree.node(media.id)!.isOnline, isFalse);
        expect(media.sourceRef?.kind, kind);
      }
      expect(cache.calls, 0);
    },
  );

  test('RSS podcast references are ready without downloading media', () async {
    final podcast = VideoItem(
      id: 'podcast',
      path: 'podcast:episode',
      title: 'Podcast',
      durationMs: 1000,
      lastUpdated: 1,
      sourceRef: const MediaSourceRef(
        value: 'https://publisher.test/episode.mp3',
        kind: MediaSourceKind.podcastEpisode,
        podcast: PodcastEpisodeRef(
          channelId: 'channel', episodeId: 'episode',
          feedUrl: 'https://publisher.test/rss',
          mediaUrl: 'https://publisher.test/episode.mp3',
        ),
      ),
    );
    library.seedVideoForTesting(podcast);
    expect(await uncachedCloudExportItems(library, [podcast.id], cache: cache),
        isEmpty);
    expect(cache.calls, 0);
  });

  test(
    'missing and remote media cannot be satisfied by an old cache or playback path',
    () async {
      final empty = await File(p.join(root.path, 'empty.mp4')).writeAsBytes([]);
      final alternate = await File(
        p.join(root.path, 'old-cache.mp4'),
      ).writeAsBytes([1]);
      for (final path in [
        p.join(root.path, 'missing.mp4'),
        empty.path,
        'https://example.test/media.mp4',
        'cloud-drive://old',
        'podcast:old',
      ]) {
        final media = item(path, path, MediaSourceKind.cloudDrive)
          ..playbackPath = alternate.path;
        library.seedVideoForTesting(media);
        expect(
          await uncachedCloudExportItems(library, [media.id], cache: cache),
          [media],
        );
      }
      expect(cache.calls, 0);
    },
  );

  test(
    'local Android document URIs remain delegated to the exporter grant check',
    () async {
      final media = item(
        'document',
        'content://documents/video/1',
        MediaSourceKind.url,
      );
      library.seedVideoForTesting(media);
      expect(
        await uncachedCloudExportItems(library, [media.id], cache: cache),
        isEmpty,
      );
      expect(cache.calls, 0);
    },
  );

  testWidgets(
    'missing media dialog offers local relocation without a cache picker',
    (tester) async {
      final media = item(
        'missing',
        'https://example.test/video',
        MediaSourceKind.url,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => PortableExportCacheDialog(
                    library: library,
                    rootIds: [media.id],
                    missing: [media],
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('需要本地媒体文件'), findsOneWidget);
      expect(find.textContaining('重新定位或导入'), findsOneWidget);
      expect(find.text('选择缓存画质'), findsNothing);
      expect(find.text('检查缓存并继续'), findsNothing);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(find.byType(PortableExportCacheDialog), findsNothing);
      expect(cache.calls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
