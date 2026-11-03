import 'dart:io';
import 'dart:ui' as ui;

import 'package:provider/provider.dart';
import 'package:video_player_app/features/media_cache/media_cache_actions.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'media_cache_service_test.dart' show FakeBackend, source;
import 'support/cloud_drive_fixture.dart' show cloudEntry;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/media_library_virtual_selection_actions.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';

void main() {
  final previewDirectory = Platform.environment['SELECTION_BAR_PREVIEWS'];
  final previewKey = GlobalKey();
  setUpAll(() async {
    if (previewDirectory == null) return;
    await (FontLoader(
      'MiSans',
    )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  late Directory root;
  late MediaCacheService service;
  final library = LibraryService();
  setUp(() async {
    library
      ..resetLibraryForTesting()
      ..seedVideoForTesting(source('clip').toItem());
    root = await Directory.systemTemp.createTemp('selection_bar_');
    service = MediaCacheService(
      backend: FakeBackend(root),
      journal: File('${root.path}/cache.json'),
      observeNetwork: false,
    );
    MediaCacheService.instance = service;
  });
  tearDown(() async {
    MediaCacheService.instance = null;
    await service.shutdown();
    service.dispose();
    await root.delete(recursive: true);
    library.resetLibraryForTesting();
  });

  testWidgets(
    'cache visibility follows the selected media and folder contents',
    (tester) async {
      final local = VideoItem(
        id: 'local',
        path: '/media/local.mp4',
        title: 'Local video',
        durationMs: 0,
        lastUpdated: 0,
      );
      final exported = source('exported').toItem()
        ..path = '/media/bilibili.mp4'
        ..isBilibiliExported = true;
      final link = VideoItem(
        id: 'link',
        path: 'https://example.com/video.mp4',
        title: 'Direct URL',
        durationMs: 0,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'https://example.com/video.mp4',
          kind: MediaSourceKind.url,
        ),
      );
      final podcast = VideoItem(
        id: 'podcast',
        path: 'podcast:episode',
        title: 'Podcast',
        durationMs: 0,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'episode',
          kind: MediaSourceKind.podcastEpisode,
          podcast: PodcastEpisodeRef(
            channelId: 'channel',
            episodeId: 'episode',
            feedUrl: 'https://example.com/feed',
            mediaUrl: 'https://example.com/episode.mp3',
          ),
        ),
      );
      library
        ..seedVideoForTesting(local)
        ..seedVideoForTesting(exported)
        ..seedVideoForTesting(link)
        ..seedVideoForTesting(podcast);
      for (final provider in [
        'baidu',
        'quark',
        'uc',
        'aliyun',
        'unsupported',
      ]) {
        final ref = cloudDriveEntrySource(
          cloudEntry(provider, provider: provider),
        );
        library
          ..seedVideoForTesting(
            VideoItem(
              id: provider,
              path: ref.cloudDrive!.logicalUri,
              title: provider,
              durationMs: 0,
              lastUpdated: 0,
              sourceRef: ref,
            ),
          )
          ..seedCollectionForTesting(
            VideoCollection(
              id: '$provider-folder',
              name: provider,
              createTime: 0,
              sourceRef: ref,
            ),
          );
      }
      for (final (id, children) in [
        ('empty-folder', <String>[]),
        ('local-folder', ['local', 'exported', 'link', 'podcast']),
        ('online-folder', ['clip']),
        ('nested-folder', ['local-folder', 'online-folder']),
        ('cycle-folder', ['cycle-folder', 'local']),
      ]) {
        library.seedCollectionForTesting(
          VideoCollection(
            id: id,
            name: id,
            createTime: 0,
            childrenIds: children,
          ),
        );
      }
      for (final (ids, visible) in [
        (<String>{}, false),
        ({'missing'}, false),
        ({'local'}, false),
        ({'exported'}, false),
        ({'link'}, false),
        ({'podcast'}, false),
        ({'clip'}, true),
        ({'baidu'}, true),
        ({'quark'}, true),
        ({'uc'}, true),
        ({'aliyun'}, true),
        ({'unsupported'}, false),
        ({'local', 'clip'}, true),
        ({'local', 'baidu'}, true),
        ({'local', 'link', 'podcast'}, false),
        ({'empty-folder'}, false),
        ({'local-folder'}, false),
        ({'nested-folder'}, true),
        ({'baidu-folder'}, true),
        ({'unsupported-folder'}, false),
        ({'cycle-folder'}, false),
        ({'local'}, false),
      ]) {
        await tester.pumpWidget(
          ChangeNotifierProvider<LibraryService>.value(
            value: library,
            child: MaterialApp(
              home: Scaffold(
                bottomNavigationBar: MediaLibrarySelectionBottomBar.folders(
                  cacheSelectedIds: ids,
                  onMoveToRecycleBin: () {},
                  onExportFluentPack: () {},
                  onRename: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(MediaCacheSelectionControl),
          visible ? findsOneWidget : findsNothing,
          reason: 'selection: $ids',
        );
        expect(
          find.byTooltip('缓存画质设置'),
          visible ? findsOneWidget : findsNothing,
          reason: 'selection: $ids',
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
  for (final size in [
    const Size(280, 640),
    const Size(320, 640),
    const Size(360, 800),
    const Size(390, 844),
    const Size(430, 932),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1440, 900),
  ]) {
    for (final count in [2, 3, 5]) {
      for (final cache in [false, true]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            'single row at $size / scale $scale / $count actions / cache $cache',
            (tester) async {
              tester.view.physicalSize = size;
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.reset);
              final invoked = <MediaLibraryVirtualSelectionActionKind>[];
              final actions =
                  MediaLibraryVirtualSelectionActions.forRecentAdded(
                    selectedIds: {'clip'},
                    pinnedIds: {},
                  ).take(count).toList();
              await tester.pumpWidget(
                ChangeNotifierProvider<LibraryService>.value(
                  value: library,
                  child: MaterialApp(
                    theme: previewDirectory == null
                        ? null
                        : ThemeData(
                            brightness: Brightness.dark,
                            fontFamily: 'MiSans',
                          ),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: Scaffold(
                      bottomNavigationBar: RepaintBoundary(
                        key: previewKey,
                        child: MediaLibrarySelectionBottomBar(
                          cacheSelectedIds: cache ? {'clip'} : {},
                          actions: actions,
                          onAction: invoked.add,
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              expect(
                find.byKey(const ValueKey('selection-transcribe')),
                findsOneWidget,
              );
              expect(find.text('插播'), findsOneWidget);
              if (previewDirectory != null &&
                  count == 5 &&
                  cache &&
                  size.width <= 390) {
                await tester.runAsync(() async {
                  final boundary =
                      previewKey.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary;
                  final image = await boundary.toImage(pixelRatio: 3);
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await Directory(previewDirectory).create(recursive: true);
                  await File(
                    '$previewDirectory/selection-${size.width.toInt()}-$scale.png',
                  ).writeAsBytes(bytes!.buffer.asUint8List());
                  image.dispose();
                });
              }
              expect(find.byType(Scrollable), findsNothing);
              expect(
                tester
                    .getSize(find.byType(MediaLibrarySelectionBottomBar))
                    .height,
                56,
              );
              if (cache) {
                final control = find.byType(MediaCacheSelectionControl);
                final settings = find.descendant(
                  of: control,
                  matching: find.byTooltip('缓存画质设置'),
                );
                expect(settings, findsOneWidget);
                expect(tester.getSize(control).height, 48);
                expect(tester.getRect(control).left, greaterThanOrEqualTo(0));
                expect(
                  tester.getRect(control).right,
                  lessThanOrEqualTo(size.width),
                );
                final shell = find.descendant(
                  of: control,
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is Material &&
                        widget.clipBehavior == Clip.antiAlias,
                  ),
                );
                expect(
                  find.descendant(
                    of: shell,
                    matching: find.byTooltip('缓存画质设置'),
                  ),
                  findsOneWidget,
                );
                expect(
                  find.descendant(of: shell, matching: find.text('缓存')),
                  findsOneWidget,
                );
              } else {
                expect(find.byType(MediaCacheSelectionControl), findsNothing);
              }
              double? buttonTop;
              for (final action in actions) {
                final button = find.widgetWithIcon(TextButton, action.icon);
                final rect = tester.getRect(button);
                buttonTop ??= rect.top;
                expect(rect.top, buttonTop);
                expect(rect.left, greaterThanOrEqualTo(0));
                expect(rect.right, lessThanOrEqualTo(size.width));
                expect(rect.width, greaterThanOrEqualTo(24));
                expect(rect.height, 48);
                if (cache) {
                  final cacheRect = tester.getRect(
                    find.byType(MediaCacheSelectionControl),
                  );
                  expect(cacheRect.top, rect.top);
                  expect(
                    cacheRect.width,
                    closeTo(rect.width < 60 ? 60 : rect.width, 0.01),
                  );
                }
                // The empty area beside the contents must activate the action too.
                await tester.tapAt(Offset(rect.left + 10, rect.center.dy));
                expect(invoked.last, action.kind);
              }
            },
          );
        }
      }
    }
  }
}
