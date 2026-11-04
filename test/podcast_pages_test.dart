import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_pages.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_settings_page.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/services/network/scoped_network_image.dart';
import 'package:video_player_app/services/network/network_settings_service.dart';
import 'podcast_core_test.dart' show podcastFixture;

class _PreviewPaths extends PathProviderPlatform {
  _PreviewPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'clipboard entry prefills link import without resolving or subscribing',
    (tester) async {
      const input =
          'https://podcasts.apple.com/podcast/id123?i=456&token=A%2bB';
      final directory = Directory.systemTemp.createTempSync(
        'podcast-link-entry-',
      );
      final store = PodcastStore(sqlite3.openInMemory());
      final http = _ClipboardNoRequestHttp();
      final client = PodcastClient(http: http);
      final controller = PodcastController(
        store: store,
        client: client,
        mediaStore: PodcastMediaStore(
          root: directory,
          store: store,
          http: http,
        ),
      );
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(controller);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(home: const PodcastDiscoverPage(initialInput: input)),
      );
      await tester.pumpAndSettle();
      expect(find.text('链接导入'), findsWidgets);
      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller!.text, input);
      expect(find.text('解析并预览'), findsOneWidget);
      expect(http.requests, 0);
      expect(store.channels, isEmpty);
      await tester.pumpWidget(const SizedBox());
      PodcastRuntime.debugOverride = null;
      controller.dispose();
      store.close();
      directory.deleteSync(recursive: true);
    },
  );
  for (final layout in const [
    ('phone', Size(390, 844), 1.0),
    ('small', Size(320, 640), 1.7),
    ('tablet-portrait', Size(768, 1024), 1.2),
    ('tablet-landscape', Size(1024, 768), 1.2),
    ('desktop', Size(1440, 900), 1.0),
    ('large-portrait', Size(1080, 1600), 1.2),
    ('short-landscape', Size(844, 390), 1.2),
  ]) {
    final (name, size, textScale) = layout;
    testWidgets('podcast pages adapt at $name with accessible controls', (
      tester,
    ) async {
      final directory = Directory.systemTemp.createTempSync('podcast-ui-');
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _PreviewPaths(directory.path);
      final store = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      final controller = PodcastController(
        store: store,
        client: client,
        mediaStore: PodcastMediaStore(
          root: directory,
          store: store,
          http: client.http,
        ),
      );
      final feed = client.parser.parse(
        utf8.encode(
          podcastFixture(
            second: true,
            title: name == 'small' ? '把喜欢的声音留在身边 · 一个有很长名字的中文播客' : '在场之间',
          ),
        ),
        'https://example.com/rss',
      );
      feed.channel.imageUrl = 'https://podcast-preview.test/cover.png';
      feed.channel.author = '小满 × 阿野';
      feed.channel.description =
          '把日常过成值得回味的故事。关于城市、远方，以及那些微小却真实的瞬间。每周五，我们在声音里见面。';
      const titles = [
        '128. 走慢一点，生活并不会因此落后',
        '127. 一个人旅行，也是一种与世界相处的方式',
        '126. 当我们谈论松弛感，我们在向往什么',
        '125. 在一座陌生的城市，重新认识自己',
        '124. 从一顿好好吃的早餐开始',
        '123. 那些不需要答案的周末',
        '122. 和老朋友见面，是生活的充电时刻',
        '121. 让房间里，多一点属于自己的东西',
      ];
      const descriptions = [
        '这期聊聊步行、留白和生活的节奏。当我们不再急着抵达，路上究竟会多出怎样的风景？',
        '从海边的小镇，到深夜的火车站。那些独自出发的时刻，让我们学会自在地与世界打招呼。',
        '不必每时每刻都做得很好。我们分享了最近学会放过自己的几个小瞬间，也聊了聊真正的休息。',
      ];
      final template = feed.episodes.first.toJson();
      feed.episodes.clear();
      for (var index = 0; index < titles.length; index++) {
        feed.episodes.add(
          PodcastEpisode.fromJson({
            ...template,
            'id': 'preview-$index',
            'title': titles[index],
            'description': descriptions[index % descriptions.length],
            'publishedMs': DateTime(
              2026,
              10,
              16 - index * 7,
            ).millisecondsSinceEpoch,
            'durationMs': (52 + index * 3) * 60000 + 18000,
            'number': 128 - index,
          }),
        );
      }
      store.mergeFeed(feed, initial: true);
      store.setSetting(feed.channel.id, 'autoRefresh', false);
      store.saveState(
        feed.episodes[1].id,
        PodcastEpisodeState(positionMs: 780000),
      );
      store.saveState(feed.episodes[2].id, PodcastEpisodeState(favorite: true));
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
        controller,
        playback: MediaPlaybackService(),
      );
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final font = FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'));
        await font.load();
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        await (FontLoader('Noto Sans SC')..addFont(
              rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
            ))
            .load();
        await (FontLoader(
          'Inter',
        )..addFont(rootBundle.load('assets/fonts/Inter-Regular.otf'))).load();
        await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
              rootBundle.load(
                'packages/cupertino_icons/assets/CupertinoIcons.ttf',
              ),
            ))
            .load();
        SharedPreferences.setMockInitialValues({});
        await NetworkSettingsService.instance.init();
        await _primeCover(feed.channel.imageUrl);
      });
      final key = GlobalKey();
      Widget app(Widget page) => ChangeNotifierProvider<SettingsService>.value(
        value: SettingsService()..resetForTest(),
        child: MaterialApp(
          theme:
              ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF4B8EF0),
                  brightness: Brightness.dark,
                ),
                useMaterial3: true,
              ).copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'MiSans',
                ),
              ),
          builder: (context, child) => MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: RepaintBoundary(key: key, child: child!),
          ),
          home: page,
        ),
      );
      await tester.pumpWidget(app(const Scaffold(body: PodcastOverviewPage())));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('订阅'), findsOneWidget);
      final titleRect = tester.getRect(find.text('播客'));
      expect(find.text('订阅喜欢的声音，按自己的节奏收听'), findsNothing);
      final tabRect = tester.getRect(find.text('订阅'));
      for (final (index, label) in [
        '订阅',
        '最新更新',
        '继续收听',
        '收藏',
        '下载',
        '队列',
      ].indexed) {
        final text = find.text(label);
        final button = find.ancestor(of: text, matching: find.byType(TextButton));
        final buttonRect = tester.getRect(button);
        final textRect = tester.getRect(text);
        final indicatorRect = tester.getRect(
          find.byKey(ValueKey('podcast-tab-indicator-$index')),
        );
        expect(buttonRect.center.dy, closeTo(textRect.center.dy, 0.5));
        expect(indicatorRect.top, greaterThanOrEqualTo(buttonRect.bottom));
      }
      final queueRect = tester.getRect(find.text('队列'));
      final refreshRect = tester.getRect(find.byTooltip('检查更新'));
      final settingsRect = tester.getRect(find.byTooltip('播客设置'));
      for (final tooltip in ['检查更新', '搜索与导入', '播客设置']) {
        final actionRect = tester.getRect(find.byTooltip(tooltip));
        expect(titleRect.center.dy, closeTo(actionRect.center.dy, 0.5));
      }
      final landscape = size.width > size.height;
      if (landscape) {
        expect(
          tabRect.top < titleRect.bottom && titleRect.top < tabRect.bottom,
          isTrue,
          reason: 'Landscape filters share the title row when they fit',
        );
        expect(
          settingsRect.top < titleRect.bottom &&
              titleRect.top < settingsRect.bottom,
          isTrue,
          reason: 'Landscape toolbar actions share the title row',
        );
        expect(tabRect.left, greaterThanOrEqualTo(titleRect.right - 1));
        expect(queueRect.right, lessThanOrEqualTo(refreshRect.left + 1));
        expect(settingsRect.right, lessThanOrEqualTo(size.width));
      } else {
        expect(
          tabRect.top,
          greaterThanOrEqualTo(titleRect.bottom - 1),
          reason: 'Portrait keeps filters on their own row',
        );
      }
      final settings = Provider.of<SettingsService>(
        tester.element(find.byType(PodcastOverviewPage)),
        listen: false,
      );
      final gridWidth = tester.getSize(find.bySubtype<GridView>()).width;
      final metrics = MediaLibraryLayoutDefaults.cardGrid(
        screenSize: Size(gridWidth, size.height),
        style: settings.collectionCardStyleFor(size),
      );
      final card = tester.getSize(find.byType(MediaLibraryGridCard).first);
      final cover = tester.getSize(
        find.byKey(ValueKey('podcast-channel-cover-${feed.channel.id}')),
      );
      expect(card.width, closeTo(metrics.cellWidth, 0.5));
      expect(card.height, closeTo(metrics.cellHeightForCoverAspect(1), 0.5));
      expect(cover.width, closeTo(card.width, 0.5));
      expect(cover.height, closeTo(cover.width, 0.5));
      final title = tester.widget<Text>(
        find.byKey(ValueKey('podcast-channel-title-${feed.channel.id}')),
      );
      expect(title.style?.color, Colors.white);
      expect(title.style?.fontWeight, FontWeight.w600);
      expect(
        title.style?.fontSize,
        closeTo(
          MediaLibraryLayoutDefaults.titleFontSize(
            card.width,
            metrics.titleScale,
          ),
          0.1,
        ),
      );
      await tester.tap(
        find.byKey(ValueKey('podcast-channel-menu-${feed.channel.id}')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('podcast-compact-menu')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.text('频道操作')).style?.color,
        AppTokens.text1,
      );
      await _capture(tester, key, 'overview-card-menu-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        app(PodcastChannelPage(channelId: feed.channel.id)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      final headerRect = tester.getRect(
        find.byKey(const ValueKey('podcast-channel-header')),
      );
      final toolbarRect = tester.getRect(
        find.byKey(const ValueKey('podcast-channel-toolbar')),
      );
      final firstRect = tester.getRect(
        find.byKey(const ValueKey('podcast-episode-surface-preview-0')),
      );
      final split = size.width >= 1100 && size.width / size.height >= 1.2;
      if (split) {
        final sidebarRect = tester.getRect(
          find.byKey(const ValueKey('podcast-channel-sidebar')),
        );
        expect(sidebarRect.width, 216);
        expect(sidebarRect.right, lessThan(toolbarRect.left));
        expect(toolbarRect.width, greaterThan(size.width * .7));
        expect(headerRect.top, toolbarRect.top);
      } else {
        expect(firstRect.left, headerRect.left);
        expect(firstRect.right, headerRect.right);
      }
      expect(firstRect.left, toolbarRect.left);
      expect(firstRect.right, toolbarRect.right);
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey('podcast-episode-title-preview-0')),
            )
            .left,
        tester
            .getRect(
              find.byKey(const ValueKey('podcast-channel-episodes-title')),
            )
            .left,
        reason: 'Episode text and section heading share one alignment line',
      );
      if (name == 'phone' || name == 'desktop') {
        expect(
          firstRect.top,
          lessThan(name == 'phone' ? 340 : 220),
          reason: 'Channel information must leave the first screen to episodes',
        );
        final lastVisibleId = name == 'phone' ? 2 : 6;
        expect(
          tester
              .getRect(
                find.byKey(
                  ValueKey('podcast-episode-surface-preview-$lastVisibleId'),
                ),
              )
              .bottom,
          lessThanOrEqualTo(size.height),
          reason:
              'Show three phone episodes with full short summaries or seven desktop episodes',
        );
      }
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory('.artifacts/podcast-previews');
        await folder.create(recursive: true);
        await File(
          '${folder.path}/channel-$name.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      if (name == 'phone' || name == 'desktop') {
        final press = await tester.startGesture(
          tester.getCenter(find.text(titles.first)),
        );
        await tester.pump(const Duration(milliseconds: 120));
        await _capture(tester, key, 'channel-pressed-$name');
        await press.cancel();
        await tester.pumpAndSettle();
      }
      if (name == 'phone') {
        final summary = find.byKey(const ValueKey('podcast-summary-preview-0'));
        expect(
          find.descendant(of: summary, matching: find.text('展开')),
          findsNothing,
        );
        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: summary,
                  matching: find.text(descriptions.first),
                ),
              )
              .maxLines,
          isNull,
        );
      }
      final channelMenuAnchor = tester.getRect(find.byTooltip('更多频道操作'));
      await tester.tap(find.byTooltip('更多频道操作'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final channelMenu = tester.getRect(
        find.byKey(const ValueKey('podcast-compact-menu')),
      );
      expect(channelMenu.top, closeTo(channelMenuAnchor.bottom + 6, .01));
      expect(channelMenu.overlaps(channelMenuAnchor), isFalse);
      expect(find.text('批量管理节目'), findsOneWidget);
      await _capture(tester, key, 'menu-$name');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      if (name == 'phone' || name == 'desktop') {
        final description = find.byKey(
          const ValueKey('podcast-channel-description'),
        );
        expect(find.text(feed.channel.description), findsOneWidget);
        final toggle = find.descendant(
          of: description,
          matching: find.text('展开'),
        );
        if (split) {
          expect(toggle, findsOneWidget);
          final restingHeight = tester.getSize(description).height;
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(
            tester.getSize(description).height,
            greaterThan(restingHeight),
          );
          await tester.tap(
            find.descendant(of: description, matching: find.text('收起')),
          );
          await tester.pumpAndSettle();
          expect(tester.getSize(description).height, restingHeight);
        } else {
          expect(toggle, findsNothing);
          expect(
            tester.widget<Text>(find.text(feed.channel.description)).maxLines,
            isNull,
          );
          expect(find.text('简介'), findsNothing);
        }
        final filterKeys = [
          'all',
          'unplayed',
          'played',
          'favorite',
          'downloaded',
        ];
        Map<String, Rect> filterGeometry() => {
          for (final id in filterKeys)
            id: tester.getRect(find.byKey(ValueKey('podcast-filter-$id'))),
        };
        final beforeFiltering = filterGeometry();
        await tester.tap(find.byKey(const ValueKey('podcast-filter-favorite')));
        await tester.pumpAndSettle();
        expect(filterGeometry(), beforeFiltering);
        expect(find.text(titles[2]), findsOneWidget);
        expect(find.text(titles.first), findsNothing);
        expect(find.text('1 集'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('podcast-filter-all')));
        await tester.pumpAndSettle();
        expect(filterGeometry(), beforeFiltering);
        await tester.tap(find.byTooltip('搜索频道节目'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, '松弛感');
        await tester.pumpAndSettle();
        expect(find.text(titles[2]), findsOneWidget);
        expect(find.text(titles.first), findsNothing);
        await tester.tap(find.byTooltip('清除频道搜索'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('更多频道操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('批量管理节目'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(titles.first));
        await tester.pumpAndSettle();
        await tester.tap(find.text(titles.first));
        await tester.pumpAndSettle();
        expect(find.text('已选 1 集'), findsOneWidget);
        await tester.tap(find.byTooltip('将已选 1 集标为已听'));
        await tester.pumpAndSettle();
        expect(controller.state(feed.episodes.first.id).played, isTrue);
        expect(tester.takeException(), isNull);
        if (name == 'desktop') {
          expect(find.text('已将 1 集标为已听'), findsOneWidget);
          final episodeScroll = find.descendant(
            of: find.byKey(
              PageStorageKey('podcast-channel-${feed.channel.id}'),
            ),
            matching: find.byType(Scrollable),
          );
          Future<void> reveal(Finder target) async {
            final position = tester
                .state<ScrollableState>(episodeScroll)
                .position;
            if (target.evaluate().isEmpty) {
              position.jumpTo(0);
              await tester.pumpAndSettle();
            }
            if (target.evaluate().isEmpty) {
              await tester.scrollUntilVisible(
                target,
                400,
                scrollable: episodeScroll,
                maxScrolls: 40,
              );
            }
            final rect = tester.getRect(target);
            final viewport = tester.getRect(episodeScroll);
            if (rect.top < viewport.top || rect.bottom > viewport.bottom) {
              position.jumpTo(
                (position.pixels + rect.top - viewport.top - 8).clamp(
                  position.minScrollExtent,
                  position.maxScrollExtent,
                ),
              );
              await tester.pumpAndSettle();
            }
          }

          await reveal(find.text('进行中 · 听到 13:00'));
          expect(find.text('进行中 · 听到 13:00'), findsOneWidget);
          await tester.tap(find.byTooltip('更多频道操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('批量管理节目'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('全选当前列表'));
          await tester.pumpAndSettle();
          expect(find.text('取消全选'), findsOneWidget);
          expect(find.text('已选 ${titles.length} 集'), findsOneWidget);
          expect(find.byTooltip('退出多选'), findsOneWidget);
          await tester.tap(find.text('取消全选'));
          await tester.pumpAndSettle();
          expect(find.text('已选 0 集'), findsOneWidget);
          expect(find.text('全选当前列表'), findsOneWidget);
          expect(find.byTooltip('退出多选'), findsOneWidget);
          await reveal(find.text(titles.first));
          await tester.tap(find.text(titles.first));
          await tester.pumpAndSettle();
          await tester.tap(find.text('隐藏节目'));
          await tester.pumpAndSettle();
          expect(find.text('已隐藏 1 集，可在「已隐藏」中恢复'), findsOneWidget);
          expect(find.text(titles.first), findsNothing);
          await tester.tap(find.byKey(const ValueKey('podcast-filter-hidden')));
          await tester.pumpAndSettle();
          expect(find.text('已隐藏'), findsWidgets);
          expect(find.text(titles.first), findsOneWidget);
          await tester.tap(find.byTooltip('更多频道操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('批量管理节目'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(titles.first));
          await tester.pumpAndSettle();
          await tester.tap(find.text('恢复显示'));
          await tester.pumpAndSettle();
          expect(find.text('已恢复 1 集'), findsOneWidget);
          expect(find.text(titles.first), findsNothing);
          await tester.tap(find.byKey(const ValueKey('podcast-filter-all')));
          await tester.pumpAndSettle();
          await reveal(find.text(titles.first));
          expect(find.text(titles.first), findsOneWidget);
          await reveal(find.text('进行中 · 听到 13:00'));
        }
      }
      await tester.pumpWidget(
        app(PodcastSettingsPage(channelId: feed.channel.id)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.text('频道独立设置'), findsOneWidget);
      await _capture(tester, key, 'settings-$name');
      final display = find.byKey(
        const ValueKey('podcast-setting-group-display'),
      );
      await tester.ensureVisible(display);
      await tester.tap(display);
      await tester.pumpAndSettle();
      final density = find.byTooltip('节目列表密度');
      await tester.ensureVisible(density);
      await tester.pumpAndSettle();
      await tester.tap(density);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('紧凑').last);
      await tester.pumpAndSettle();
      expect(store.effective(feed.channel.id).text('density'), 'compact');
      expect(store.preferences.text('density'), 'comfortable');
      await _capture(tester, key, 'settings-display-$name');
      final restore = find.byTooltip('恢复继承');
      await tester.ensureVisible(restore);
      await tester.pumpAndSettle();
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(store.effective(feed.channel.id).text('density'), 'comfortable');
      await tester.pumpWidget(app(const PodcastDiscoverPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('podcast-search-input')),
        findsOneWidget,
      );
      await tester.pumpWidget(
        app(PodcastPlayerPage(episodeId: feed.episodes.first.id)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(MusicPlayerScreen), findsOneWidget);
      final guidance = find.byKey(
        const ValueKey('podcast-transcript-guidance'),
      );
      expect(guidance, findsOneWidget);
      for (final actionKey in [
        'podcast-ai-transcribe',
        'podcast-transcript-notes',
      ]) {
        final action = find.byKey(ValueKey(actionKey));
        expect(action, findsOneWidget);
        final bounds = tester.getRect(action);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(size.width));
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(size.height));
      }
      expect(
        find.byKey(const ValueKey('music-episode-picker-button')),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '.artifacts/podcast-previews/player-$name.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.byTooltip('播客设置与节目操作'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('podcast-compact-menu')),
        findsOneWidget,
      );
      final playerMenuHeading = find.text('节目操作');
      expect(
        tester.widget<Text>(playerMenuHeading).style?.color,
        AppTokens.text1,
      );
      expect(
        find.ancestor(
          of: playerMenuHeading,
          matching: find.byWidgetPredicate(
            (widget) => widget is Opacity && widget.opacity < 1,
          ),
        ),
        findsNothing,
      );
      await _capture(tester, key, 'player-menu-$name');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final playButton = find.byKey(const ValueKey('music-play-pause-button'));
      final beforeLoading = tester.getRect(playButton);
      final runtime = PodcastRuntime.debugOverride!;
      runtime.openingEpisodeId = feed.episodes.first.id;
      controller.publish();
      await tester.pump();
      expect(
        tester
            .widget<MusicPlayerScreen>(find.byType(MusicPlayerScreen))
            .isLoading,
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        find.byKey(const ValueKey('music-playback-loading')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('music-playback-loading')),
        findsOneWidget,
      );
      expect(tester.getRect(playButton), beforeLoading);
      await _capture(tester, key, 'player-loading-$name', settle: false);
      runtime.openingEpisodeId = null;
      controller.publish();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('music-playback-loading')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      PodcastRuntime.debugOverride = null;
      await controller.close();
      store.close();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      directory.deleteSync(recursive: true);
      PathProviderPlatform.instance = previousPaths;
    });
  }
}

class _ClipboardNoRequestHttp extends PodcastHttp {
  int requests = 0;
  @override
  Future<PodcastResponse> get(
    String url, {
    Map<String, String> headers = const {},
    int maxBytes = 32 * 1024 * 1024,
    void Function(HttpClient)? onClient,
    bool Function()? isCancelled,
  }) async {
    requests++;
    throw StateError('opening a prefilled import page must not parse a link');
  }
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey key,
  String name, {
  bool settle = true,
}) async {
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '.artifacts/podcast-previews/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _primeCover(String url) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 480, 480),
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF557A75), Color(0xFF304E4D)],
      ).createShader(const Rect.fromLTWH(0, 0, 480, 480)),
  );
  canvas.drawCircle(
    const Offset(450, 30),
    150,
    Paint()..color = const Color(0xFFE3D9BD),
  );
  canvas.drawCircle(
    const Offset(377, 368),
    44,
    Paint()..color = const Color(0xFFD6A778),
  );
  for (var index = 0; index < 15; index++) {
    final path = Path()
      ..moveTo(-30, 342 + index * 9)
      ..cubicTo(
        130,
        270 + index * 9,
        230,
        472 + index * 8,
        510,
        370 + index * 9,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF85A59C).withValues(alpha: .32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );
  }
  void text(
    String value,
    double size,
    Offset offset, {
    FontWeight weight = FontWeight.w400,
    double spacing = 0,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: 'MiSans',
          color: const Color(0xFFF3ECD7),
          fontSize: size,
          fontWeight: weight,
          height: 1.2,
          letterSpacing: spacing,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 420);
    painter.paint(canvas, offset);
  }

  text('BEING HERE', 15, const Offset(42, 36), spacing: 2.5);
  text('在场\n之间', 92, const Offset(38, 100), weight: FontWeight.w600);
  text('把日常，慢慢听清。', 16, const Offset(42, 423));
  final picture = recorder.endRecording();
  final image = await picture.toImage(480, 480);
  final fixture = await image.toByteData(format: ui.ImageByteFormat.png);
  Directory('.artifacts/podcast-previews').createSync(recursive: true);
  await File(
    '.artifacts/podcast-previews/fixture-cover.png',
  ).writeAsBytes(fixture!.buffer.asUint8List());
  picture.dispose();
  final provider = ScopedNetworkImage(
    url,
    scope: NetworkSites.forPodcast(Uri.parse(url)),
  );
  for (final width in [48, 60, 96, 112, 176, 216, 312, 480]) {
    final key = await ResizeImage(
      provider,
      width: width,
    ).obtainKey(const ImageConfiguration());
    PaintingBinding.instance.imageCache.putIfAbsent(
      key,
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image.clone())),
      ),
    );
  }
  final key = await ResizeImage(
    provider,
    width: 24,
    height: 24,
  ).obtainKey(const ImageConfiguration());
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(
      Future.value(ImageInfo(image: image.clone())),
    ),
  );
  image.dispose();
}
