import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_subtitle_tracks.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_subtitle_tracks_section.dart';
import 'package:video_player_app/widgets/cloud_drive_subtitle_tracks_section.dart';
import 'package:video_player_app/widgets/folder_placeholder_cover.dart';
import 'package:video_player_app/widgets/media_library_browse_grid_cards.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';

class _RetiredCache extends ChangeNotifier implements MediaCacheService {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('local cards must not consult an online cache');
  }
}

class _RetiredBiliTracks extends ChangeNotifier
    implements BilibiliSubtitleTracks {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('remote subtitle discovery is retired');
  }
}

class _RetiredCloudTracks extends ChangeNotifier
    implements CloudDriveSubtitleTracks {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('remote subtitle discovery is retired');
  }
}

void main() {
  late LibraryService library;
  late _RetiredCache cache;
  MediaCacheService? previousCache;
  final settings = SettingsService();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    previousCache = MediaCacheService.instance;
    cache = _RetiredCache();
    MediaCacheService.instance = cache;
  });
  tearDown(() {
    MediaCacheService.instance = previousCache;
    cache.dispose();
    library.resetLibraryForTesting();
    settings.resetForTest();
  });

  Widget app(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider<LibraryService>.value(value: library),
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: MediaPlaybackService(),
      ),
    ],
    child: MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  for (final kind in [
    MediaSourceKind.bilibiliStream,
    MediaSourceKind.cloudDrive,
    MediaSourceKind.podcastEpisode,
  ]) {
    testWidgets(
      'a local file with ${kind.name} provenance keeps local actions without cache calls',
      (tester) async {
        final item = VideoItem(
          id: 'local',
          path: File('local-fixture.mp4').absolute.path,
          title: '自己的本地文件',
          durationMs: 1000,
          lastUpdated: 1,
          sourceRef: MediaSourceRef(
            kind: kind,
            value: 'retained-origin',
            bvid: 'BV1xx411c7mD',
            cid: 12,
          ),
        );
        library.seedVideoForTesting(item);
        await tester.pumpWidget(
          app(
            SizedBox(
              width: 320,
              height: 100,
              child: MediaLibraryListTile.video(
                item: item,
                index: 0,
                showIndex: false,
                showThumbnail: true,
                isSelected: false,
                isSelectionMode: false,
                titleScale: 1,
                onTap: () {},
                onMoveToParent: () {},
                showActivityMenu: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('media-library-activity-menu')),
        );
        await tester.pumpAndSettle();
        for (final label in ['重命名', '移动到上一级', '导出', '移入回收站', '打开源文件位置']) {
          expect(find.text(label), findsOneWidget);
        }
        for (final label in ['缓存', '管理缓存', '删除所有缓存', '打开官网', '订阅设置']) {
          expect(find.text(label), findsNothing);
        }
        expect(cache.calls, 0);
        expect(item.sourceRef?.kind, kind);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  }

  for (final list in [true, false]) {
    testWidgets(
      'a historical podcast folder uses the local ${list ? 'list' : 'grid'} cover and folder menu',
      (tester) async {
        final folder = VideoCollection(
          id: 'saved-folder',
          name: '自己的收藏',
          createTime: 1,
          childrenIds: ['one', 'two'],
          podcastRef: const PodcastChannelRef(
            channelId: 'old',
            feedUrl: 'https://example.test/rss',
          ),
        );
        library.seedCollectionForTesting(folder);
        await tester.pumpWidget(
          app(
            SizedBox(
              width: 320,
              height: list ? 100 : 300,
              child: list
                  ? MediaLibraryListTile.collection(
                      collection: folder,
                      index: 0,
                      showIndex: false,
                      showThumbnail: true,
                      isSelected: false,
                      isSelectionMode: false,
                      titleScale: 1,
                      onTap: () {},
                      showActivityMenu: true,
                      allowHidePodcastFromFolders: true,
                    )
                  : MediaLibraryFolderGridCard(
                      collection: folder,
                      titleScale: 1,
                      onTap: () {},
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(FolderPlaceholderCover), findsOneWidget);
        expect(find.text('2 个项目'), findsOneWidget);
        expect(find.byKey(const ValueKey('podcast-card-badge')), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('media-library-activity-menu')),
        );
        await tester.pumpAndSettle();
        expect(find.text('重命名'), findsOneWidget);
        expect(find.text('导出'), findsOneWidget);
        expect(find.text('不在此页面显示'), findsNothing);
        expect(cache.calls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'legacy subtitle sections never bootstrap or call remote tracks',
    (tester) async {
      final bili = _RetiredBiliTracks(), cloud = _RetiredCloudTracks();
      addTearDown(bili.dispose);
      addTearDown(cloud.dispose);
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) {
              final item = VideoItem(
                id: 'local',
                path: '/tmp/local.mp4',
                title: 'local',
                durationMs: 1,
                lastUpdated: 1,
                sourceRef: const MediaSourceRef(
                  kind: MediaSourceKind.bilibiliStream,
                  value: 'BV1xx411c7mD',
                ),
              );
              expect(bilibiliSubtitleTracksFor(context, item), isNull);
              expect(cloudDriveSubtitleTracksFor(context, item), isNull);
              return Column(
                children: [
                  BilibiliSubtitleTracksSection(
                    itemId: item.id,
                    tracks: bili,
                    onPick: (_) => fail('remote pick'),
                    savedRow: (_) => const Text('remote'),
                  ),
                  CloudDriveSubtitleTracksSection(
                    itemId: item.id,
                    tracks: cloud,
                    onPick: (_) => fail('remote pick'),
                    savedRow: (_) => const Text('remote'),
                  ),
                  MediaLibraryGridCard(
                    radius: 8,
                    isSelected: false,
                    onTap: () {},
                    cacheItem: item,
                    child: const Text('local media'),
                  ),
                ],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(bili.calls, 0);
      expect(cloud.calls, 0);
      expect(cache.calls, 0);
      expect(find.text('remote'), findsNothing);
      expect(find.text('local media'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
