import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/media_library_selection_bottom_bar.dart';
import 'package:video_player_app/widgets/media_library_selection_drop_targets.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_subscription_layout.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/experimental_layout.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PodcastRuntime runtime;
  late PodcastOverviewController pageController;
  late LibraryService library;
  late PlaylistManager queue;
  late MediaPlaybackService playback;
  final haptics = <Object?>[];
  final preview = Platform.environment['PODCAST_LIBRARY_PREVIEW_DIR'];
  final previewKey = GlobalKey();

  PodcastStore getStore() => runtime.store;
  PodcastSubscriptionLayout layout() => PodcastSubscriptionLayout(getStore());

  setUpAll(() async {
    if (preview == null) return;
    for (final font in [
      ('Noto Sans SC', 'assets/fonts/NotoSansCJKsc-Regular.otf'),
      ('Noto Sans CJK Fallback', 'assets/fonts/NotoSansCJKsc-Regular.otf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      await (FontLoader(font.$1)..addFont(rootBundle.load(font.$2))).load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    pageController = PodcastOverviewController();
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    queue = PlaylistManager();
    playback = MediaPlaybackService();
    final settings = SettingsService()..resetForTest();
    await settings.init();
    directory = Directory.systemTemp.createTempSync('podcast-library-ui-');
    final store = PodcastStore(sqlite3.openInMemory());
    final client = PodcastClient();
    runtime = PodcastRuntime.forTesting(
      PodcastController(
        store: store,
        client: client,
        mediaStore: PodcastMediaStore(
          root: directory,
          store: store,
          http: client.http,
        ),
      ),
      library: library,
      playlist: queue,
    );
    PodcastRuntime.debugOverride = runtime;
    for (var i = 0; i < 4; i++) {
      final id = 'channel-$i';
      store.write(
        'channel',
        id,
        PodcastChannel(
          id: id,
          feedUrl: 'https://example.test/$id.xml',
          title: ['日常电台', '城市漫游', '故事之间', '周末来信'][i],
          author: '声音工作室',
          subscribedMs: 100 - i,
        ).toJson(),
      );
    }
    for (final channel in runtime.controller.channels) {
      library.seedCollectionForTesting(
        VideoCollection(
          id: 'card-${channel.id}',
          name: channel.title,
          createTime: 1,
          isHiddenFromFolders: true,
          podcastRef: PodcastChannelRef(
            channelId: channel.id,
            feedUrl: channel.feedUrl,
          ),
        ),
      );
    }
    haptics.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() async {
    await runtime.shutdown();
    PodcastRuntime.debugOverride = null;
    pageController.dispose();
    queue.dispose();
    library.resetLibraryForTesting();
    await playback.stop();
    SettingsService().resetForTest();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    directory.deleteSync(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1100, 900),
    double textScale = 1,
    bool useHome = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SettingsService()),
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: playback),
          ChangeNotifierProvider.value(value: queue),
          ChangeNotifierProvider.value(value: BatchImportService()),
        ],
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            fontFamily: preview == null ? null : 'Noto Sans SC',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepaintBoundary(key: previewKey, child: child!),
          ),
          home: useHome
              ? MediaLibraryShell(home: const HomeScreen())
              : AnimatedBuilder(
                  animation: pageController,
                  builder: (context, _) => Scaffold(
                    appBar: AppBar(
                      title: pageController.isSelecting
                          ? pageController.buildSelectionDropTargets()
                          : const Text('媒体库'),
                      leading: pageController.isSelecting
                          ? IconButton(
                              tooltip: '退出选择',
                              icon: const Icon(Icons.close),
                              onPressed: pageController.exitSelection,
                            )
                          : null,
                      actions: [
                        IconButton(
                          tooltip: pageController.isSelecting ? '全选' : '批量管理',
                          icon: Icon(
                            pageController.isSelecting
                                ? Icons.select_all
                                : Icons.checklist,
                          ),
                          onPressed: pageController.isSelecting
                              ? pageController.toggleSelectAll
                              : pageController.enterSelection,
                        ),
                      ],
                    ),
                    body: PodcastOverviewPage(
                      controller: pageController,
                      bottomPadding: 0,
                    ),
                    bottomNavigationBar: MediaLibrarySelectionBarTransition(
                      child: pageController.buildSelectionBottomBar(),
                    ),
                  ),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder channelCard(int index) => find
      .ancestor(
        of: find.byKey(ValueKey('podcast-channel-title-channel-$index')),
        matching: find.byType(MediaLibraryGridCard),
      )
      .first;

  Future<void> savePreview(WidgetTester tester, String name) async {
    if (preview == null) return;
    await tester.runAsync(() async {
      final boundary =
          previewKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final picture = await boundary.toImage();
      final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$preview/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes!.buffer.asUint8List());
      picture.dispose();
    });
  }

  void startOnPodcasts() {
    SettingsService()
      ..mediaLibraryRootEntry = 'podcasts'
      ..mediaLibraryStartupEntry = 'podcasts'
      ..mediaLibraryRootEntryUserChosen = true
      ..isActionButtonsCollapsed = false;
  }

  Future<void> createFromRail(WidgetTester tester, String name) async {
    final create = find.byIcon(Icons.create_new_folder).hitTestable();
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(find.text('新建合集'), findsWidgets);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      name,
    );
    await tester.runAsync(() => tester.tap(find.text('创建')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'home action rail creates in the current podcast collection and switches back to library creation',
    (tester) async {
      startOnPodcasts();
      await mount(tester, useHome: true, size: const Size(1100, 900));
      expect(find.byType(PodcastOverviewPage).hitTestable(), findsOneWidget);
      expect(find.byType(VideoActionButtons), findsOneWidget);
      expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
      final libraryIds = library.storageCollections
          .map((folder) => folder.id)
          .toSet();
      await createFromRail(tester, '通勤合集');
      final parent = layout().folders.single;
      expect(parent.name, '通勤合集');
      expect(
        library.storageCollections.map((folder) => folder.id).toSet(),
        libraryIds,
      );
      await tester.tap(find.byKey(ValueKey('podcast-folder-${parent.id}')));
      await tester.pumpAndSettle();
      await createFromRail(tester, '深度访谈');
      expect(
        layout().folders
            .where((folder) => folder.parentId == parent.id)
            .single
            .name,
        '深度访谈',
      );
      expect(
        library.storageCollections.map((folder) => folder.id).toSet(),
        libraryIds,
      );
      await tester.tap(find.text('文件夹').hitTestable());
      await tester.pumpAndSettle();
      await createFromRail(tester, '本地合集');
      expect(
        library.collections.where((folder) => folder.name == '本地合集'),
        hasLength(1),
      );
      expect(layout().folders, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'home podcast selection uses the shared toolbar, red unsubscribe and original queue/export/rename actions',
    (tester) async {
      startOnPodcasts();
      await mount(tester, useHome: true, size: const Size(1100, 900));
      await tester.longPress(channelCard(0));
      await tester.pumpAndSettle();
      expect(find.byType(VideoActionButtons), findsNothing);
      expect(find.byType(MediaLibrarySelectionDropTargets), findsOneWidget);
      final bar = find.byType(MediaLibrarySelectionBottomBar);
      expect(bar, findsOneWidget);
      final actions = tester
          .widget<MediaLibrarySelectionBottomBar>(bar)
          .customActions;
      expect(actions.map((action) => action.label), ['取消订阅', '导出', '重命名']);
      expect(actions.first.color, AppTokens.danger);
      expect(find.text('加入播放列表'), findsOneWidget);
      expect(find.byTooltip('移动到文件夹'), findsNothing);
      expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
      final removeButton = find.descendant(
        of: bar,
        matching: find.widgetWithText(TextButton, '取消订阅'),
      );
      final style = tester.widget<TextButton>(removeButton).style!;
      expect(style.foregroundColor!.resolve({}), AppTokens.danger);
      expect(
        style.backgroundColor!.resolve({}),
        AppTokens.danger.withValues(alpha: .045),
      );
      expect(tester.getSize(removeButton).height, 48);
      await savePreview(tester, 'home-desktop-selection');
      await tester.tap(removeButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(runtime.controller.channels, hasLength(4));
      await tester.tap(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(VideoActionButtons), findsOneWidget);
      expect(find.byType(MediaLibrarySelectionBottomBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shared add-to-playlist expands a podcast collection without opening or materializing episodes',
    (tester) async {
      final folder = layout().createFolder('收听合集');
      layout().move(['channel-0', 'channel-1'], folder);
      for (var index = 0; index < 2; index++) {
        final episode = PodcastEpisode(
          id: 'episode-$index',
          channelId: 'channel-$index',
          title: '节目 $index',
          sourceFeedUrl: 'https://publisher.test/rss-$index',
          media: [
            PodcastMedia(
              url: 'https://example.test/episode-$index.mp3',
              mimeType: 'audio/mpeg',
            ),
          ],
        );
        getStore().write(
          'episode',
          episode.id,
          episode.toJson(),
          channel: episode.channelId,
        );
      }
      await mount(tester);
      await tester.longPress(find.byKey(ValueKey('podcast-folder-$folder')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('加入播放列表')));
      await tester.pumpAndSettle();
      expect(queue.playlist.map((item) => item.sourceRef?.podcast?.episodeId), [
        'episode-0',
        'episode-1',
      ]);
      expect(library.storageVideos, isEmpty);
      expect(runtime.persistedEpisodeIds, isEmpty);
      expect(playback.currentItem, isNull);
      expect(pageController.isSelecting, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new-collection keyboard shortcut follows the current podcast folder even from another podcast tab',
    (tester) async {
      final folder = layout().createFolder('专访');
      await mount(tester);
      await tester.tap(find.byKey(ValueKey('podcast-folder-$folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(find.text('新建合集'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '访谈精选');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        layout().folders.where((entry) => entry.parentId == folder).single.name,
        '访谈精选',
      );
      expect(library.storageCollections, hasLength(4));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'experimental sidebar reuses new collection in the podcast destination',
    (tester) async {
      startOnPodcasts();
      SharedPreferences.setMockInitialValues({
        ExperimentalLayout.preferenceKey: true,
      });
      ExperimentalLayout.instance.value = true;
      try {
        await mount(tester, useHome: true, size: const Size(1440, 900));
        expect(find.byType(VideoActionButtons), findsNothing);
        await tester.tap(find.text('新建合集').hitTestable());
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '侧栏创建',
        );
        await tester.tap(find.text('创建'));
        await tester.pumpAndSettle();
        expect(layout().folders.single.name, '侧栏创建');
        expect(library.storageCollections, hasLength(4));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        ExperimentalLayout.instance.value = false;
      }
    },
  );

  testWidgets(
    'long press selects; taps toggle; Escape exits without opening a channel',
    (tester) async {
      await mount(tester);
      await tester.longPress(channelCard(0));
      await tester.pumpAndSettle();
      expect(pageController.selectedIds, hasLength(1));
      await tester.tap(channelCard(1));
      await tester.pumpAndSettle();
      expect(pageController.selectedIds, hasLength(2));
      expect(find.byType(PodcastChannelPage), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(pageController.selectedIds, hasLength(4));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(pageController.isSelecting, isFalse);
      expect(find.byTooltip('批量管理'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'creating a folder from selection groups cards and folder-local select all stays local',
    (tester) async {
      await mount(tester);
      await tester.longPress(channelCard(0));
      await tester.pumpAndSettle();
      await tester.tap(channelCard(1));
      await tester.pumpAndSettle();
      unawaited(pageController.createCollection());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '通勤收听');
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      final folder = layout().folders.single;
      expect(layout().entries(folder.id, runtime.controller.channels), [
        'channel-0',
        'channel-1',
      ]);
      expect(
        find.byKey(const ValueKey('podcast-channel-title-channel-0')),
        findsNothing,
      );
      await tester.tap(find.byKey(ValueKey('podcast-folder-${folder.id}')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(pageController.selectedIds, hasLength(2));
      await tester.tap(find.byKey(mediaLibraryMoveToParentDropKey));
      await tester.pumpAndSettle();
      expect(layout().entries(folder.id, runtime.controller.channels), isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('podcast-channel-title-channel-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'desktop drag reorders and hovering a folder moves the selected block',
    (tester) async {
      final folder = layout().createFolder('通勤收听');
      await mount(tester, size: const Size(1440, 1000));
      var gesture = await tester.startGesture(
        tester.getCenter(channelCard(0)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(channelCard(2)));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(layout().entries(null, runtime.controller.channels), [
        'channel-1',
        'channel-2',
        'channel-0',
        'channel-3',
        folder,
      ]);
      await tester.tap(channelCard(1));
      await tester.pumpAndSettle();
      expect(pageController.selectedIds, hasLength(2));
      final source = tester.getCenter(channelCard(0));
      final target = tester.getCenter(
        find.byKey(ValueKey('podcast-folder-$folder')),
      );
      gesture = await tester.startGesture(
        source,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(layout().entries(folder, runtime.controller.channels), [
        'channel-1',
        'channel-0',
      ]);
      expect(find.byType(PodcastChannelPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'dragging an unselected card leaves the other selected cards in place',
    (tester) async {
      final folder = layout().createFolder('稍后听');
      await mount(tester, size: const Size(1440, 1000));
      await tester.longPress(channelCard(0));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(channelCard(2)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(ValueKey('podcast-folder-$folder'))),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(layout().entries(folder, runtime.controller.channels), [
        'channel-2',
      ]);
      expect(layout().parentOf('channel-0'), isNull);
      expect(pageController.selectedIds, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'selection survives a subscription refresh by ID and checkbox drag selects a range',
    (tester) async {
      await mount(tester, size: const Size(1440, 1000));
      await tester.longPress(channelCard(0));
      await tester.pumpAndSettle();
      final start = tester.getCenter(
        find.byKey(const ValueKey('podcast-select-channel-1')),
      );
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(channelCard(3)));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(pageController.selectedIds, hasLength(4));
      getStore().write(
        'channel',
        'fresh',
        PodcastChannel(
          id: 'fresh',
          title: '新订阅',
          feedUrl: 'https://example.test/fresh',
          subscribedMs: 999,
        ).toJson(),
      );
      runtime.controller.publish();
      await tester.pumpAndSettle();
      expect(pageController.selectedIds, hasLength(4));
      expect(find.byType(PodcastChannelPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('mobile feedback respects the vibration setting', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await mount(tester, size: const Size(390, 844));
    await tester.longPress(channelCard(0));
    await tester.pumpAndSettle();
    expect(haptics, contains('HapticFeedbackType.selectionClick'));
    await tester.tap(find.byTooltip('退出选择'));
    await tester.pumpAndSettle();
    SettingsService().enableHapticFeedback = false;
    haptics.clear();
    await tester.longPress(channelCard(0));
    await tester.pumpAndSettle();
    expect(pageController.selectedIds, hasLength(1));
    expect(haptics, isEmpty);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shared rename and dissolve actions preserve the subscription', (
    tester,
  ) async {
    final folderId = layout().createFolder('待整理');
    layout().move(['channel-0'], folderId);
    await mount(tester);
    await tester.longPress(find.byKey(ValueKey('podcast-folder-$folderId')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('移动到文件夹'), findsNothing);
    expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);
    await tester.tap(find.byTooltip('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('library-rename-name-field')),
      '日常收听',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(layout().folder(folderId)!.name, '日常收听');
    final remove = find.descendant(
      of: find.byType(MediaLibrarySelectionBottomBar),
      matching: find.text('解散合集'),
    );
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(layout().parentOf('channel-0'), folderId);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '解散合集'));
    await tester.pumpAndSettle();
    expect(layout().folder(folderId), isNull);
    expect(layout().parentOf('channel-0'), isNull);
    expect(runtime.controller.channels.length, 4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'new subscriptions imported inside a folder return to that folder',
    (tester) async {
      final folderId = layout().createFolder('随身听');
      await mount(tester);
      await tester.tap(find.byKey(ValueKey('podcast-folder-$folderId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索与导入'));
      await tester.pumpAndSettle();
      getStore().write(
        'channel',
        'imported',
        PodcastChannel(
          id: 'imported',
          title: '新导入',
          feedUrl: 'https://example.test/imported',
        ).toJson(),
      );
      runtime.controller.publish();
      Navigator.of(tester.element(find.byType(PodcastDiscoverPage))).pop();
      await tester.pumpAndSettle();
      expect(layout().parentOf('imported'), folderId);
      expect(find.text('新导入'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('refresh during a drag keeps the dragged channel identity', (
    tester,
  ) async {
    final folderId = layout().createFolder('收藏夹');
    await mount(tester, size: const Size(1440, 1000));
    final gesture = await tester.startGesture(
      tester.getCenter(channelCard(1)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    getStore().write(
      'channel',
      'fresh',
      PodcastChannel(
        id: 'fresh',
        title: '刚订阅',
        feedUrl: 'https://example.test/fresh',
        subscribedMs: 999,
      ).toJson(),
    );
    runtime.controller.publish();
    await tester.pumpAndSettle();
    await gesture.moveTo(
      tester.getCenter(find.byKey(ValueKey('podcast-folder-$folderId'))),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(layout().entries(folderId, runtime.controller.channels), [
      'channel-1',
    ]);
    expect(layout().parentOf('channel-0'), isNull);
    expect(layout().parentOf('fresh'), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'selection edge scroll stops after release even when the source is offscreen',
    (tester) async {
      for (var index = 4; index < 80; index++) {
        final id = 'channel-$index';
        getStore().write(
          'channel',
          id,
          PodcastChannel(
            id: id,
            title: '播客 $index',
            feedUrl: 'https://example.test/$id',
            subscribedMs: 100 - index,
          ).toJson(),
        );
      }
      await mount(tester, size: const Size(390, 844));
      await tester.longPress(channelCard(0));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey('podcast-select-channel-0')),
        ),
      );
      await gesture.moveBy(const Offset(0, 24));
      await tester.pump();
      await gesture.moveTo(const Offset(190, 760));
      await tester.pump(const Duration(seconds: 3));
      final scrollable = find
          .descendant(
            of: find.byType(PodcastOverviewPage),
            matching: find.byType(Scrollable),
          )
          .last;
      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.pixels, greaterThan(0));
      final held = state.position.pixels;
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.position.pixels, greaterThan(held));
      await gesture.up();
      await tester.pump();
      final released = state.position.pixels;
      await tester.pump(const Duration(seconds: 1));
      expect(state.position.pixels, closeTo(released, .01));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'card drag keeps edge scrolling after the dragged source leaves the viewport',
    (tester) async {
      for (var index = 4; index < 80; index++) {
        final id = 'channel-$index';
        getStore().write(
          'channel',
          id,
          PodcastChannel(
            id: id,
            title: '播客 $index',
            feedUrl: 'https://example.test/$id',
            subscribedMs: 100 - index,
          ).toJson(),
        );
      }
      await mount(tester, size: const Size(390, 844));
      final gesture = await tester.startGesture(
        tester.getCenter(channelCard(0)),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      await gesture.moveTo(const Offset(190, 770));
      await tester.pump(const Duration(seconds: 2));
      final scrollable = find
          .descendant(
            of: find.byType(PodcastOverviewPage),
            matching: find.byType(Scrollable),
          )
          .last;
      final state = tester.state<ScrollableState>(scrollable);
      expect(state.position.pixels, greaterThan(0));
      final held = state.position.pixels;
      await tester.pump(const Duration(milliseconds: 500));
      expect(state.position.pixels, greaterThan(held));
      await gesture.up();
      await tester.pump();
      final released = state.position.pixels;
      await tester.pump(const Duration(seconds: 1));
      expect(state.position.pixels, closeTo(released, .01));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (name, size, scale) in [
    ('phone', const Size(390, 844), 1.0),
    ('small-large-text', const Size(320, 640), 1.7),
    ('desktop', const Size(1440, 900), 1.0),
    ('tablet-portrait', const Size(768, 1024), 1.2),
    ('short-landscape', const Size(844, 390), 1.2),
  ]) {
    testWidgets('folders and selection controls fit $name', (tester) async {
      layout().createFolder('通勤收听');
      final parent = layout().createFolder('周末时光');
      layout().createFolder('深度访谈', parentId: parent);
      await mount(tester, size: size, textScale: scale);
      await savePreview(tester, '$name-folders');
      await tester.longPress(channelCard(0));
      await tester.pumpAndSettle();
      expect(find.byType(MediaLibrarySelectionBottomBar), findsOneWidget);
      expect(find.byTooltip('移动到文件夹'), findsNothing);
      expect(find.byTooltip('退出选择'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await savePreview(tester, '$name-selection');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
