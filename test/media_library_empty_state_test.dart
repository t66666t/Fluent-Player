import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/experimental_layout.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_empty_state.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void setSize(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  for (final size in const [
    Size(240, 240),
    Size(320, 568),
    Size(568, 320),
    Size(600, 400),
    Size(800, 1280),
    Size(1440, 900),
    Size(2560, 1440),
  ]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('empty hint fits $size at text scale $scale', (tester) async {
        setSize(tester, size);
        const bottom = 96.0;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(
              body: MediaLibraryEmptyState(
                icon: Icons.folder_open_outlined,
                message: '此文件夹为空',
                bottomPadding: bottom,
              ),
            ),
          ),
        );
        final text = find.text('此文件夹为空');
        await tester.ensureVisible(text);
        final rect = tester.getRect(text);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(size.height - bottom));
        expect(
          find.byWidgetPredicate(
            (widget) => widget is ButtonStyleButton || widget is IconButton,
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  late SettingsService settings;
  late LibraryService library;
  late MediaPlaybackService playback;
  late VideoCollection folder;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService()..resetForTest();
    await settings.init();
    library = LibraryService()..resetLibraryForTesting();
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    folder = VideoCollection(id: 'empty', name: '我的文件夹', createTime: 1);
    library.seedCollectionForTesting(folder);
    playback = MediaPlaybackService();
    await playback.stop();
  });

  tearDown(() async {
    await playback.stop();
    library.resetLibraryForTesting();
    settings.resetForTest();
  });

  Widget harness(Widget page, {GlobalKey? capture}) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: library),
      ChangeNotifierProvider.value(value: playback),
      ChangeNotifierProvider.value(value: BatchImportService()),
    ],
    child: MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'Noto Sans SC',
        scaffoldBackgroundColor: AppTokens.bgBase,
      ),
      builder: capture == null
          ? null
          : (_, child) => RepaintBoundary(key: capture, child: child!),
      home: MediaLibraryShell(home: page),
    ),
  );

  VideoItem clip() => VideoItem(
    id: 'clip',
    path: '/missing/clip.mp4',
    title: '示例视频',
    parentId: folder.id,
    durationMs: 120000,
    lastUpdated: 1,
    hasProbedChapters: true,
  );

  for (final size in const [
    Size(320, 568),
    Size(844, 390),
    Size(800, 1280),
    Size(1440, 900),
  ]) {
    for (final page in ['home', 'folder', 'search']) {
      testWidgets('$page reserves player space at $size', (tester) async {
        setSize(tester, size);
        playback.publishRestoredSessionPreview(
          clip(),
          const Duration(seconds: 5),
        );
        await tester.pumpWidget(
          harness(switch (page) {
            'home' => const HomeScreen(returnToSearchResults: true),
            'folder' => CollectionScreen(collectionId: folder.id),
            _ => const CollectionScreen.search(query: '未找到'),
          }),
        );
        await tester.pumpAndSettle();

        expect(
          find.byType(MediaLibraryEmptyState).hitTestable(),
          findsOneWidget,
        );
        expect(
          find.byType(VideoActionButtons),
          page == 'search' ? findsNothing : findsOneWidget,
        );
        final message = find.descendant(
          of: find.byType(MediaLibraryEmptyState).hitTestable(),
          matching: find.byType(Text),
        );
        final player = find.byType(MiniPlaybackCard);
        expect(player, findsOneWidget);
        for (var i = 0; i < message.evaluate().length; i++) {
          expect(
            tester.getRect(message.at(i)).bottom,
            lessThan(tester.getRect(player).top),
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('floating actions stay mounted as folder content changes', (
    tester,
  ) async {
    setSize(tester, const Size(390, 844));
    await tester.pumpWidget(harness(CollectionScreen(collectionId: folder.id)));
    await tester.pumpAndSettle();
    expect(find.byType(VideoActionButtons), findsOneWidget);
    final actions = tester.state(find.byType(VideoActionButtons));
    final toggle = find.byKey(const ValueKey('action-button-disc-toggle'));
    final initiallyCollapsed = settings.isActionButtonsCollapsed;
    expect(toggle.hitTestable(), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.isActionButtonsCollapsed, !initiallyCollapsed);

    library.seedVideoForTesting(clip());
    folder.childrenIds.add('clip');
    library.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(MediaLibraryEmptyState), findsNothing);
    expect(find.byType(VideoActionButtons), findsOneWidget);
    expect(tester.state(find.byType(VideoActionButtons)), same(actions));

    folder.childrenIds.clear();
    library.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(MediaLibraryEmptyState), findsOneWidget);
    expect(find.byType(VideoActionButtons), findsOneWidget);
    expect(tester.state(find.byType(VideoActionButtons)), same(actions));
    expect(toggle.hitTestable(), findsOneWidget);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(settings.isActionButtonsCollapsed, initiallyCollapsed);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'empty home tabs retain original floating actions when switching',
    (tester) async {
      setSize(tester, const Size(900, 800));
      await tester.pumpWidget(harness(const HomeScreen()));
      await tester.pumpAndSettle();
      for (final tab in {
        '最近添加': '暂无最近添加的内容',
        '继续学习': '暂无播放记录',
        '文件夹': '暂无媒体内容',
      }.entries) {
        await tester.tap(find.text(tab.key));
        await tester.pumpAndSettle();
        expect(find.text(tab.value).hitTestable(), findsOneWidget);
        expect(find.byType(VideoActionButtons), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in const [Size(390, 844), Size(1440, 900)]) {
    testWidgets(
      'existing toolbar keeps empty folder actions accessible at $size',
      (tester) async {
        setSize(tester, size);
        await tester.pumpWidget(
          harness(CollectionScreen(collectionId: folder.id)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(VideoActionButtons), findsOneWidget);
        expect(find.text('导入视频或音频'), findsNothing);

        Finder menu() => size.width < 600
            ? find.byTooltip('更多')
            : find.byWidgetPredicate(
                (widget) =>
                    widget is Tooltip && widget.message!.startsWith('导入与导出'),
              );
        await tester.tap(menu());
        await tester.pumpAndSettle();
        expect(find.text('导入视频或音频'), findsOneWidget);
        expect(find.text('批量导入').hitTestable(), findsOneWidget);
        expect(find.text('语音转录').hitTestable(), findsOneWidget);
        for (final label in [
          '浏览器导入',
          '网站与链接收藏',
          'B站官方播放',
          'YouTube 官方播放',
          '缓存管理',
        ]) {
          expect(find.text(label), findsNothing);
        }
        await tester.tap(find.text('导入视频或音频'));
        await tester.pumpAndSettle();
        expect(find.textContaining('从文件管理导入'), findsWidgets);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();

        await tester.tap(menu());
        await tester.pumpAndSettle();
        await tester.tap(find.text('新建合集').hitTestable());
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '子文件夹');
        await tester.tap(find.text('创建'));
        await tester.pumpAndSettle();
        expect(
          library
              .getContents(folder.id)
              .whereType<VideoCollection>()
              .single
              .name,
          '子文件夹',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'temporary locate hides experimental sidebar and preserves root preference',
    (tester) async {
      setSize(tester, const Size(1440, 900));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(ExperimentalLayout.preferenceKey, true);
      await settings.saveMediaLibraryRootChoice('recent');
      ExperimentalLayout.instance.value = true;
      addTearDown(() => ExperimentalLayout.instance.value = false);
      await tester.pumpWidget(harness(HomeScreen(revealItemId: folder.id)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('experimental-sidebar')), findsNothing);
      expect(find.byType(MediaLibraryEntrySwitcher), findsNothing);
      expect(settings.mediaLibraryRootEntry, 'recent');
      expect(prefs.getString('mediaLibraryRootEntry'), 'recent');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'render empty folder previews',
    (tester) async {
      await tester.runAsync(() async {
        await (FontLoader(
          'Noto Sans SC',
        )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load();
        await (FontLoader('Noto Sans CJK Fallback')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      for (final sample in <String, Size>{
        'phone': const Size(390, 844),
        'landscape': const Size(844, 390),
        'desktop': const Size(1440, 900),
      }.entries) {
        setSize(tester, sample.value);
        final capture = GlobalKey();
        await tester.pumpWidget(
          harness(CollectionScreen(collectionId: folder.id), capture: capture),
        );
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        await tester.runAsync(() async {
          final pixels = await boundary.toImage();
          final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
          final output = File('build/empty-state-previews/${sample.key}.png');
          await output.parent.create(recursive: true);
          await output.writeAsBytes(png!.buffer.asUint8List());
          pixels.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
    skip: !const bool.fromEnvironment('EMPTY_STATE_PREVIEWS'),
  );
}
