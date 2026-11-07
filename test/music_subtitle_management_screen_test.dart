import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/screens/music_player_screen.dart';
import 'package:video_player_app/widgets/music_subtitle_management_dialog.dart';
import 'package:video_player_app/widgets/model_center_button.dart';
import 'package:video_player_app/services/embedded_subtitle_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_file_processing_settings.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'package:video_player_app/widgets/subtitle_processing_stage.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/ai_transcription_panel.dart';
import 'package:video_player_app/widgets/subtitle_management_sheet.dart';
import 'package:video_player_app/widgets/music_album_cover.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late SettingsService settings;
  late LibraryService library;
  late MediaPlaybackService playback;
  late TranscriptionManager transcription;
  late VideoItem item;
  late File english;
  late File chinese;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('music_subtitle_page_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          (call) async =>
              call.method == 'getLocalAppDataPath' ? root.path : null,
        );
    settings = SettingsService()..resetForTest();
    settings.largeDataRootPath = root.path;
    await settings.init();
    settings.autoCacheSubtitles = false;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    english = File(p.join(root.path, 'English.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:04,000\nEnglish lyric\n');
    chinese = File(p.join(root.path, 'Chinese.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:04,000\n中文字幕\n');
    item = VideoItem(
      id: 'music-subtitle-test',
      path: p.join(root.path, 'music.mp3'),
      title: 'Midnight · 夜曲',
      type: MediaType.audio,
      durationMs: 4000,
      lastUpdated: 0,
      usesManagedAssociatedSubtitles: true,
      additionalSubtitles: {'English': english.path, '中文': chinese.path},
    );
    library.seedVideoForTesting(item);
    playback = MediaPlaybackService()
      ..debugOverrideStreamQualityChrome(item: item);
    playback.setSubtitleState(paths: [], primary: [], secondary: []);
    transcription = TranscriptionManager(settings: settings);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          null,
        );
    playback.debugOverrideStreamQualityChrome();
    playback.setSubtitleState(paths: [], primary: [], secondary: []);
    transcription.dispose();
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    // This fixture owns the freshly created temporary directory.
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Widget host(Widget page, {GlobalKey? capture}) => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsService>.value(value: settings),
      ChangeNotifierProvider<LibraryService>.value(value: library),
      ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
      ChangeNotifierProvider<EmbeddedSubtitleService>(
        create: (_) => _Embedded(),
      ),
      ChangeNotifierProvider<TranscriptionManager>.value(value: transcription),
    ],
    child: RepaintBoundary(
      key: capture,
      child: MaterialApp(debugShowCheckedModeBanner: false, home: page),
    ),
  );

  Future<void> flushIO(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> pumpPage(
    WidgetTester tester,
    Widget page, {
    GlobalKey? capture,
  }) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(host(page, capture: capture));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(target);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await flushIO(tester);
  }

  testWidgets('landscape title opens a modal above the unchanged player', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(const MusicPlayerScreen()));
    await tester.pumpAndSettle();
    final button = find.byKey(
      const ValueKey('music-landscape-subtitle-management'),
    );
    expect(button, findsOneWidget);
    expect(find.text('字幕管理'), findsOneWidget);
    final playerBounds = tester.getRect(
      find.byKey(const ValueKey('music-landscape-left-panel')),
    );
    final chip = tester.getRect(button);
    final slider = tester.getRect(
      find.byKey(const ValueKey('music-progress-slider')),
    );
    final play = tester.getRect(find.byIcon(CupertinoIcons.play_fill));
    expect(chip.center.dy, greaterThan(slider.bottom));
    expect(chip.center.dy, lessThan(play.top));
    expect(chip.center.dx, closeTo(slider.center.dx, 1));
    // 参考图胶囊约为播放图标的 0.56 倍高、1.41 倍宽。
    expect(chip.height / play.height, inInclusiveRange(0.45, 0.85));
    expect(chip.width / play.width, inInclusiveRange(1.15, 2.0));
    expect(
      tester.getTopLeft(button).dy,
      greaterThan(tester.getTopLeft(find.text(item.title)).dy),
    );
    await tap(tester, button);
    await flushIO(tester);
    expect(find.byType(MusicSubtitleManagementDialog), findsOneWidget);
    final manager = tester.widget<SubtitleManagementSheet>(
      find.byType(SubtitleManagementSheet),
    );
    expect(manager.appearance, SubtitleManagementAppearance.musicIOS);
    expect(manager.onOpenOcrSubtitle, isNull);
    expect(find.text('OCR字幕'), findsNothing);
    expect(manager.videoId, item.id);
    expect(manager.associatedSubtitles, item.downloadAssociatedSubtitles);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(MusicPlayerScreen), findsOneWidget);
    final lyricSearch = find.byKey(
      const ValueKey('subtitle-lyric-search-entry'),
    );
    final onlineSearch = find.byKey(
      const ValueKey('subtitle-online-search-entry'),
    );
    expect(lyricSearch, findsOneWidget);
    expect(onlineSearch, findsOneWidget);
    final lyricRect = tester.getRect(lyricSearch);
    final onlineRect = tester.getRect(onlineSearch);
    expect(lyricRect.right, lessThan(onlineRect.left));
    expect((lyricRect.center.dy - onlineRect.center.dy).abs(), lessThan(4));
    expect(
      find.byKey(const ValueKey('music-landscape-lyric-search')),
      findsNothing,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('music-landscape-left-panel'))),
      playerBounds,
    );
    await tester.tap(find.byKey(const ValueKey('music-subtitle-dialog-close')));
    await tester.pumpAndSettle();
    expect(find.byType(MusicSubtitleManagementDialog), findsNothing);
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();
    expect(button, findsNothing);
    expect(
      find.byKey(const ValueKey('music-portrait-lyric-search')),
      findsNothing,
    );
    final portraitChip = find.byKey(
      const ValueKey('music-portrait-subtitle-management'),
    );
    expect(portraitChip, findsOneWidget);
    expect(
      tester.getCenter(portraitChip).dx,
      closeTo(
        tester
            .getCenter(find.byKey(const ValueKey('music-progress-slider')))
            .dx,
        1,
      ),
    );
    await tester.pumpWidget(host(const SizedBox.shrink()));
  });

  testWidgets(
    'keyboard animation in input subpages does not relayout the covered manager or player',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
        tester.view.resetViewInsets();
        tester.view.resetViewPadding();
        tester.view.resetPadding();
        return tester.binding.setSurfaceSize(null);
      });
      playback.setSubtitleState(
        paths: [english.path],
        primary: [
          SubtitleItem(
            index: 1,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 4),
            text: 'English lyric',
          ),
        ],
        secondary: [],
      );
      await pumpPage(tester, const MusicPlayerScreen());
      await tester.pumpAndSettle();
      await tap(
        tester,
        find.byKey(const ValueKey('music-portrait-subtitle-management')),
      );
      await flushIO(tester);
      await tap(tester, find.text('导入字幕'));
      await tester.pumpAndSettle();
      await tap(tester, find.text('手动输入文本'));
      await tester.pumpAndSettle();
      expect(find.text('手动输入字幕'), findsOneWidget);
      final manager = find.byKey(ValueKey('music-subtitle-manager-${item.id}'));
      final managerBounds = tester.getRect(manager);
      final cover = find.byKey(const ValueKey('music-portrait-metadata'));
      final coverBounds = tester.getRect(cover);
      expect(find.byType(MusicLyricView), findsOneWidget);
      final fields = find.byType(TextField);
      await tester.tap(fields.first);
      await tester.pump();
      final previous = debugOnRebuildDirtyWidget;
      final builds = <Type, int>{};
      const protectedTypes = {
        MusicPlayerScreen,
        MusicAlbumCover,
        MusicLyricView,
        MusicSubtitleManagementDialog,
        SubtitleManagementSheet,
      };
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        final type = element.widget.runtimeType;
        if (protectedTypes.contains(type)) {
          builds.update(type, (n) => n + 1, ifAbsent: () => 1);
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (final inset in [
        0,
        50,
        100,
        150,
        200,
        250,
        300,
        250,
        200,
        150,
        100,
        50,
        0,
      ]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset.toDouble());
        tester.view.padding = FakeViewPadding(
          top: 24,
          bottom: inset > 0 ? 0 : 34,
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(manager), managerBounds);
        expect(tester.getRect(cover), coverBounds);
        expect(tester.getRect(fields.first).bottom, lessThan(844 - inset));
        expect(tester.takeException(), isNull);
      }
      expect(
        builds,
        isEmpty,
        reason: 'IME frames should only rebuild the visible input dialog',
      );
      debugOnRebuildDirtyWidget = previous;
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(const SizedBox.shrink()));
    },
  );

  testWidgets(
    'album cover no longer hosts lyric search beside the song title',
    (tester) async {
      for (final size in [
        const Size(480, 320),
        const Size(844, 390),
        const Size(1440, 900),
      ]) {
        await tester.binding.setSurfaceSize(size);
        for (final artist in ['', 'Artist · Album']) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: MusicAlbumCover(
                    title: 'A media title that can occupy two reserved lines',
                    artist: artist,
                    coverSize: 120,
                    infoWidth: 240,
                    onExitTrigger: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(MusicAlbumCover), findsOneWidget);
          expect(
            find.byKey(const ValueKey('music-landscape-lyric-search')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    },
  );

  for (final appearance in SubtitleManagementAppearance.values) {
    testWidgets('growing files keep stop and resume actions in $appearance', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(
        appearance == SubtitleManagementAppearance.standard
            ? const Size(480, 900)
            : const Size(220, 640),
      );
      transcription.dispose();
      final streamManager = _StreamingManager(settings: settings);
      transcription = streamManager;
      final cues = SubtitleCueBuffer()
        ..addAll([
          SubtitleItem(
            index: 1,
            startTime: Duration.zero,
            endTime: const Duration(seconds: 1),
            text: 'First',
          ),
        ]);
      void publish(SubtitleStreamPhase phase, int bytes) {
        streamManager.publish(
          SubtitleStreamUpdate(
            generationId: 'stream',
            mediaKey: 'id:${item.id}',
            videoId: item.id,
            videoPath: item.path,
            revision: cues.snapshot.length,
            primaryPath: english.path,
            secondaryPath: chinese.path,
            primary: cues.snapshot,
            secondary: cues.snapshot,
            addedPrimary: const [],
            addedSecondary: const [],
            primaryBytes: bytes,
            secondaryBytes: bytes,
            processedThrough: const Duration(seconds: 30),
            phase: phase,
          ),
        );
      }

      publish(SubtitleStreamPhase.generating, 1024);
      await pumpPage(
        tester,
        Scaffold(
          body: SubtitleManagementSheet(
            videoPath: item.path,
            videoId: item.id,
            appearance: appearance,
            showEmbeddedSubtitles: false,
            onSubtitleChanged: () {},
            onOpenAi: () {},
          ),
        ),
      );
      await flushIO(tester);
      expect(find.textContaining('生成中 · 1 条 · 已处理 0:30'), findsWidgets);
      cues.addAll([
        SubtitleItem(
          index: 2,
          startTime: const Duration(seconds: 2),
          endTime: const Duration(seconds: 3),
          text: 'Second',
        ),
      ]);
      publish(SubtitleStreamPhase.generating, 2048);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(find.textContaining('2.0 KB · 生成中 · 2 条'), findsWidgets);
      await tester.tap(find.byTooltip('停止并保留进度').first);
      expect(streamManager.stops, 1);
      publish(SubtitleStreamPhase.stopping, 2048);
      await tester.pump();
      expect(find.textContaining('正在停止 · 2 条'), findsWidgets);
      expect(
        tester
            .widget<IconButton>(
              find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is IconButton && widget.tooltip == '停止并保留进度',
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      publish(SubtitleStreamPhase.failed, 2048);
      await tester.pump();
      expect(find.textContaining('出错可续传 · 2 条'), findsWidgets);
      await tester.tap(find.byTooltip('继续生成').first);
      expect(streamManager.resumes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(host(const SizedBox.shrink()));
    });
  }

  testWidgets('search entries stay beside close in the header at every width', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    const lyricKey = ValueKey('subtitle-lyric-search-entry');
    const onlineKey = ValueKey('subtitle-online-search-entry');
    var lyricSearches = 0;
    try {
      for (final appearance in SubtitleManagementAppearance.values) {
        for (final width in [220.0, 320.0, 390.0, 768.0, 1280.0]) {
          for (final scale in [1.0, 1.6]) {
            await tester.binding.setSurfaceSize(Size(width, 800));
            await pumpPage(
              tester,
              Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 800),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: SubtitleManagementSheet(
                    key: ValueKey('$appearance-$width-$scale'),
                    videoPath: item.path,
                    videoId: item.id,
                    appearance: appearance,
                    showEmbeddedSubtitles: false,
                    associatedSubtitles: item.downloadAssociatedSubtitles,
                    onSubtitleChanged: () {},
                    onOpenAi: () {},
                    onSearchLyrics: () async => lyricSearches++,
                  ),
                ),
              ),
            );
            final header = find.byKey(
              const ValueKey('subtitle-management-header'),
            );
            final lyric = find.byKey(lyricKey);
            final online = find.byKey(onlineKey);
            final close = find.byKey(
              ValueKey(
                appearance == SubtitleManagementAppearance.musicIOS
                    ? 'music-subtitle-dialog-close'
                    : 'subtitle-management-close',
              ),
            );
            expect(
              find.descendant(of: header, matching: lyric),
              findsOneWidget,
            );
            expect(
              find.descendant(of: header, matching: online),
              findsOneWidget,
            );
            final lyricRect = tester.getRect(lyric);
            final onlineRect = tester.getRect(online);
            final closeRect = tester.getRect(close);
            expect(lyricRect.right, lessThan(onlineRect.left));
            expect(onlineRect.right, lessThan(closeRect.left));
            expect(
              (lyricRect.center.dy - closeRect.center.dy).abs(),
              lessThan(1),
            );
            expect(
              (onlineRect.center.dy - closeRect.center.dy).abs(),
              lessThan(1),
            );
            expect(tester.getRect(header).contains(lyricRect.topLeft), isTrue);
            expect(onlineRect.right, lessThanOrEqualTo(width));
            for (final label in ['搜索歌词', '搜索在线字幕']) {
              final node = find.byWidgetPredicate(
                (widget) =>
                    widget is Semantics && widget.properties.label == label,
              );
              expect(
                tester
                    .getSemantics(node)
                    .getSemanticsData()
                    .hasAction(ui.SemanticsAction.tap),
                isTrue,
              );
            }
            for (final button in [lyric, online]) {
              final labels = find.descendant(
                of: button,
                matching: find.byType(Text),
              );
              if (labels.evaluate().isNotEmpty) {
                expect(
                  tester
                      .renderObject<RenderParagraph>(labels.first)
                      .didExceedMaxLines,
                  isFalse,
                  reason:
                      'Search labels must stay readable at $appearance $width $scale',
                );
              }
            }
            if (scale == 1) {
              expect(
                tester.getSize(header).height - onlineRect.height,
                lessThanOrEqualTo(10),
              );
            }
            expect(
              tester.takeException(),
              isNull,
              reason: '$appearance $width $scale',
            );
            if (width == 390 && scale == 1) {
              await tap(tester, lyric);
              expect(
                lyricSearches,
                appearance == SubtitleManagementAppearance.standard ? 1 : 2,
              );
              expect(find.byType(SubtitleManagementSheet), findsOneWidget);
              expect(find.text('English'), findsOneWidget);
            }
            await tester.pumpWidget(const SizedBox.shrink());
            await flushIO(tester);
          }
        }
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('translation model entry fits narrow standard and music panels', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final appearance in SubtitleManagementAppearance.values) {
      for (final width in [220.0, 320.0]) {
        await tester.binding.setSurfaceSize(Size(width, 800));
        await pumpPage(
          tester,
          Scaffold(
            body: SubtitleManagementSheet(
              key: ValueKey('$appearance-$width'),
              videoPath: item.path,
              videoId: item.id,
              appearance: appearance,
              showEmbeddedSubtitles: false,
              associatedSubtitles: item.downloadAssociatedSubtitles,
              onSubtitleChanged: () {},
              onOpenAi: () {},
            ),
          ),
        );
        await tap(tester, find.byTooltip('优化 / 翻译字幕').first);
        await tester.pumpAndSettle();
        expect(find.byType(ModelCenterButton), findsOneWidget);
        await tester.ensureVisible(find.byType(ModelCenterButton));
        final modelEntry = tester.getRect(find.byType(ModelCenterButton));
        expect(modelEntry.left, greaterThanOrEqualTo(0));
        expect(modelEntry.right, lessThanOrEqualTo(width));
        expect(find.byType(ModelCenterButton).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: '$appearance at $width');
        // Scrolling to the model entry must not leave PageStorage offsets in
        // the shared Navigator for the next independent width/appearance.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    }
  });

  testWidgets('music subtitle actions stay compact at every width', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const localName = '音乐访谈原文字幕（完整校对版）.srt';
    final local = File(
      p.join(root.path, localName),
    )..writeAsStringSync('1\n00:00:00,000 --> 00:00:04,000\nMusic interview\n');
    item.localSubtitles = {'访谈字幕': local.path};
    const captureUI = bool.fromEnvironment('CAPTURE_MUSIC_ROW_ACTIONS');
    if (captureUI) {
      for (final font in {
        'Noto Sans SC': 'assets/fonts/NotoSansCJKsc-Regular.otf',
        'Roboto': 'assets/fonts/NotoSansCJKsc-Regular.otf',
        'Inter': 'assets/fonts/Inter-Regular.otf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        'packages/cupertino_icons/CupertinoIcons':
            'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      }.entries) {
        await tester.runAsync(
          () => (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load(),
        );
      }
    }

    Finder row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(CupertinoListTile),
    );
    Finder action(Finder row, String tooltip) =>
        find.descendant(of: row, matching: find.byTooltip(tooltip));
    final capture = GlobalKey();
    for (final (size, name) in [
      (const Size(220, 640), 'narrow'),
      (const Size(320, 720), 'small-phone'),
      (const Size(390, 844), 'phone'),
      (const Size(844, 390), 'landscape'),
      (const Size(1440, 900), 'desktop'),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await pumpPage(
        tester,
        const MusicSubtitleManagementDialog(),
        capture: capture,
      );
      await flushIO(tester);
      final localRow = row(localName);
      final boundRow = row('English');
      await tester.ensureVisible(localRow);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: localRow,
          matching: find.byIcon(CupertinoIcons.ellipsis),
        ),
        findsNothing,
      );
      expect(action(boundRow, '删除字幕'), findsNothing);
      expect(action(boundRow, '导出字幕'), findsOneWidget);
      expect(action(boundRow, '优化 / 翻译字幕'), findsOneWidget);
      final rowRect = tester.getRect(localRow);
      final buttons = [
        for (final tooltip in ['导出字幕', '优化 / 翻译字幕', '删除字幕'])
          tester.getRect(action(localRow, tooltip)),
      ];
      for (final button in buttons) {
        expect(button.size, Size(size.width == 220 ? 28 : 32, 40));
        expect(button.center.dy, closeTo(rowRect.center.dy, .1));
      }
      expect(buttons[0].right, closeTo(buttons[1].left, .1));
      expect(buttons[1].right, closeTo(buttons[2].left, .1));
      expect(buttons.last.right, closeTo(rowRect.right - 8, .1));
      expect(
        tester.getSize(find.text(localName)).width,
        greaterThan(size.width == 220 ? 45 : 80),
      );
      expect(action(localRow, '删除字幕').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size');
      if (captureUI && size.width >= 320) {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('artifacts/music_subtitle_row_actions/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await tap(tester, action(row(localName), '删除字幕'));
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.text('删除外部字幕文件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(local.existsSync(), isTrue);
    expect(playback.subtitlePaths, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (music, width) in [
    (false, 220.0),
    (false, 1280.0),
    (true, 320.0),
    (true, 1280.0),
  ]) {
    testWidgets('subtitle details in ${music ? 'music' : 'video'} at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 680));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const name = '深夜访谈 · 原声对谈 · 嘉宾逐字稿（完整校对版与双语时间轴）.srt';
      final local = File(p.join(root.path, name))
        ..writeAsStringSync(
          '1\n00:00:00,000 --> 00:00:04,000\nMusic interview\n',
        );
      item.localSubtitles = {'访谈字幕': local.path};
      List<String> selected = [];
      final clipboard =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? copied;
      clipboard.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => clipboard.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pumpPage(
        tester,
        music
            ? const MusicSubtitleManagementDialog()
            : Theme(
                data: ThemeData.dark().copyWith(
                  platform: width > 700 ? TargetPlatform.windows : null,
                ),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width > 700 ? 420 : width,
                      child: SubtitleManagementSheet(
                        videoPath: item.path,
                        videoId: item.id,
                        showEmbeddedSubtitles: false,
                        associatedSubtitles: item.downloadAssociatedSubtitles,
                        localSubtitles: item.localSubtitles,
                        onSubtitleChanged: () {},
                        onOpenAi: () {},
                        onSubtitleSelected: (paths) {
                          selected = List.of(paths);
                        },
                      ),
                    ),
                  ),
                ),
              ),
      );
      await flushIO(tester);

      final title = find.byWidgetPredicate((w) => w is Text && w.data == name);
      final details = find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == name,
      );
      expect(details, findsNothing);
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      if (width > 700) {
        await tester.tap(
          title,
          buttons: kSecondaryMouseButton,
          kind: ui.PointerDeviceKind.mouse,
        );
      } else {
        await tester.longPress(title);
      }
      await tester.pumpAndSettle();
      expect(details, findsOneWidget);
      expect(
        tester.getTopLeft(details).dy,
        greaterThan(tester.getBottomLeft(title).dy),
      );
      expect(find.textContaining('SRT ·'), findsOneWidget);
      expect(music ? playback.subtitlePaths : selected, isEmpty);

      await tap(tester, find.byTooltip('复制完整名称'));
      expect(copied, name);
      await tap(tester, find.byTooltip('收起字幕信息'));
      expect(details, findsNothing);
      expect(tester.takeException(), isNull);

      await tap(tester, title);
      expect(music ? playback.subtitlePaths : selected, [local.path]);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'import keeps its action sheet and translate opens directly from the row',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpPage(tester, const MusicSubtitleManagementDialog());
      await flushIO(tester);
      await tap(tester, find.text('导入字幕'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.text('从文件导入'), findsOneWidget);
      expect(find.text('手动输入文本'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('导出字幕'), findsNWidgets(2));
      await tap(tester, find.byTooltip('优化 / 翻译字幕').first);
      expect(find.byType(CupertinoActionSheet), findsNothing);
      expect(playback.subtitlePaths, isEmpty);
      expect(
        find.byType(CupertinoSlidingSegmentedControl<bool>),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('subtitle-file-translation-options')),
        findsOneWidget,
      );
      expect(
        find.byType(CapsuleDropdownButtonFormField<SubtitleTranslateProvider>),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('smart-rule-0-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-rule-0-target')), findsOneWidget);
      expect(find.text('当前翻译：必应翻译'), findsOneWidget);
      expect(find.byType(ModelCenterButton), findsOneWidget);
      await tap(tester, find.text('手动翻译'));
      expect(find.text('输入翻译结果'), findsOneWidget);
      // 手动翻译不调用内部引擎，语言设置里不能再标出必应/AI/本地模型。
      expect(find.textContaining('当前翻译：'), findsNothing);
      await tester.pumpWidget(host(const SizedBox.shrink()));
    },
  );

  testWidgets(
    'music selections share playback and persisted primary/secondary paths',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpPage(tester, const MusicSubtitleManagementDialog());
      await flushIO(tester);
      await tap(tester, find.text('English'));
      await flushIO(tester);
      expect(playback.subtitlePaths, [english.path]);
      expect(playback.subtitles.single.text, 'English lyric');
      expect(library.getVideo(item.id)!.subtitlePath, english.path);
      await tap(tester, find.text('中文'));
      await flushIO(tester);
      expect(playback.subtitlePaths, [english.path, chinese.path]);
      expect(playback.secondarySubtitles.single.text, '中文字幕');
      expect(library.getVideo(item.id)!.secondarySubtitlePath, chinese.path);
      // Selecting the primary again promotes the secondary, as the original sheet does.
      await tap(tester, find.text('English'));
      await flushIO(tester);
      expect(playback.subtitlePaths, [chinese.path]);
      expect(item.subtitlePath, chinese.path);
      expect(item.secondarySubtitlePath, isNull);
      await tap(tester, find.text('中文'));
      await flushIO(tester);
      expect(playback.subtitlePaths, isEmpty);
      expect(item.subtitlePath, isNull);
      await tester.pumpWidget(host(const SizedBox.shrink()));
    },
  );

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'manual translation prompt stays editable through keyboard frames at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        await pumpPage(tester, const MusicSubtitleManagementDialog());
        await flushIO(tester);
        await tap(tester, find.byTooltip('优化 / 翻译字幕').first);
        await tap(tester, find.text('手动翻译'));
        await tap(tester, find.text('编辑翻译提示词'));
        await tester.pumpAndSettle();
        final field = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '可编辑提示词',
        );
        await tester.enterText(field, 'Keep this translation prompt');
        await tester.pump();
        final peak = size.height < 500 ? 180.0 : 320.0;
        for (final inset in [0.0, 48.0, 96.0, peak, 96.0, 48.0, 0.0]) {
          tester.view.viewInsets = FakeViewPadding(bottom: inset);
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.getRect(field).bottom,
            lessThanOrEqualTo(size.height - inset),
          );
          expect(
            tester.widget<TextField>(field).controller!.text,
            'Keep this translation prompt',
          );
          expect(MediaQuery.viewInsetsOf(tester.element(field)).bottom, 0);
          expect(tester.takeException(), isNull);
        }
        Navigator.of(tester.element(field)).pop();
        await tester.pumpAndSettle();
        await tap(tester, find.text('编辑翻译提示词'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(field).controller!.text,
          'Keep this translation prompt',
        );
        await tester.pumpWidget(host(const SizedBox.shrink()));
      },
    );
  }

  testWidgets(
    'AI action reuses transcription panel and preserves manager state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(844, 390));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpPage(tester, const MusicSubtitleManagementDialog());
      await flushIO(tester);
      final managerState = tester.state(find.byType(SubtitleManagementSheet));
      await tap(tester, find.text('语音转录'));
      await tester.pump();
      expect(find.byType(AiTranscriptionPanel), findsOneWidget);
      expect(
        tester
            .widget<AiTranscriptionPanel>(find.byType(AiTranscriptionPanel))
            .sourceItem,
        same(item),
      );
      await tester.tap(
        find.byKey(const ValueKey('music-subtitle-dialog-ai-back')),
      );
      await tester.pump();
      expect(
        tester.state(find.byType(SubtitleManagementSheet)),
        same(managerState),
      );
      expect(find.text('导入字幕'), findsOneWidget);
      await tester.pumpWidget(host(const SizedBox.shrink()));
    },
  );

  for (final appearance in SubtitleManagementAppearance.values) {
    testWidgets(
      'file stages persist independently of expansion and transcription in $appearance',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const optimizeKey = ValueKey('subtitle-optimization-toggle');
        const translateKey = ValueKey('subtitle-file-translation-toggle');
        const settingsKey = ValueKey('subtitle-file-translation-settings');
        final options = find.byKey(
          const ValueKey('subtitle-file-translation-options'),
        );
        Future<void> open(
          String path, {
          SubtitleManagementAppearance? nextAppearance,
        }) async {
          await pumpPage(
            tester,
            Scaffold(
              body: SubtitleManagementSheet(
                videoPath: item.path,
                videoId: item.id,
                appearance: nextAppearance ?? appearance,
                showEmbeddedSubtitles: false,
                associatedSubtitles: item.downloadAssociatedSubtitles,
                onSubtitleChanged: () {},
                onOpenAi: () {},
              ),
            ),
          );
          // The fixture renders English first and Chinese second.
          await tap(
            tester,
            find.byTooltip('优化 / 翻译字幕').at(path == english.path ? 0 : 1),
          );
          await flushIO(tester);
        }

        bool selected(Key key) => tester.widget<Switch>(find.byKey(key)).value;
        Future<void> setStage(Key key, bool value) async {
          await tester.runAsync(() async {
            tester.widget<Switch>(find.byKey(key)).onChanged!(value);
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await flushIO(tester);
        }

        await open(english.path);
        final panel = tester.widget<Container>(
          find.byKey(const ValueKey('subtitle-processing-panel')),
        );
        expect((panel.margin as EdgeInsets).top, 12);
        final stages = find.byType(SubtitleProcessingStage);
        expect(stages, findsNWidgets(2));
        expect(
          tester.getSize(stages.first).height,
          tester.getSize(stages.last).height,
        );
        expect(selected(optimizeKey), isFalse);
        expect(selected(translateKey), isTrue);
        expect(
          find.byKey(const ValueKey('subtitle-file-translation-options')),
          findsOneWidget,
        );
        // Both shortcuts are visible actions; neither enables processing.
        expect(find.text('模型'), findsNWidgets(2));
        expect(find.text('提示词'), findsOneWidget);
        await tap(
          tester,
          find.byKey(const ValueKey('subtitle-optimization-settings')),
        );
        expect(find.text('优化模型'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('subtitle-api-model')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('subtitle-optimization-prompt')),
          findsNothing,
        );
        await tap(tester, find.byTooltip('关闭优化设置'));
        await tap(
          tester,
          find.byKey(const ValueKey('subtitle-optimization-prompt-button')),
        );
        final prompt = find.byKey(
          const ValueKey('subtitle-optimization-prompt'),
        );
        expect(prompt, findsOneWidget);
        await tester.ensureVisible(prompt);
        await tester.enterText(prompt, '保留原意与时间轴');
        await tap(tester, find.text('保存'));
        expect(selected(optimizeKey), isFalse);
        expect(selected(translateKey), isTrue);
        final configuration = await tester.runAsync(
          SubtitleOptimizationSettings.load,
        );
        expect(configuration!.prompt, '保留原意与时间轴');
        expect(configuration.enabled, isFalse);
        await setStage(optimizeKey, true);
        await setStage(translateKey, false);
        expect(tester.widget(find.byKey(settingsKey)), isA<TextButton>());
        await tap(tester, find.byKey(settingsKey));
        expect(
          find.byKey(const ValueKey('subtitle-file-translation-options')),
          findsNothing,
        );
        final expandButton = find.byKey(
          const ValueKey('subtitle-file-translation-expand'),
        );
        expect(
          tester
              .getRect(find.byKey(settingsKey))
              .contains(tester.getCenter(expandButton)),
          isTrue,
          reason: 'Label and expansion arrow share one action.',
        );
        await tap(tester, expandButton);
        expect(options, findsOneWidget);
        expect(selected(translateKey), isFalse);
        await tap(tester, find.byKey(settingsKey));
        expect(options, findsNothing);
        await tap(
          tester,
          find.byKey(const ValueKey('subtitle-processing-close')),
        );
        expect(
          find.byKey(const ValueKey('subtitle-processing-panel')),
          findsNothing,
        );
        await tap(tester, find.byTooltip('优化 / 翻译字幕').first);
        expect(options, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await flushIO(tester);
        // Another workflow changes the shared optimizer enable flag.
        await tester.runAsync(
          () => const SubtitleOptimizationSettings(enabled: false).save(),
        );
        await tester.runAsync(() async {
          await (await SharedPreferences.getInstance()).reload();
        });
        await open(
          chinese.path,
          nextAppearance: appearance == SubtitleManagementAppearance.standard
              ? SubtitleManagementAppearance.musicIOS
              : SubtitleManagementAppearance.standard,
        );
        expect(options, findsNothing);
        expect(selected(optimizeKey), isTrue);
        expect(selected(translateKey), isFalse);
        expect(find.text('仅优化字幕'), findsOneWidget);
        await setStage(optimizeKey, false);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('subtitle-file-processing-start')),
              )
              .onPressed,
          isNull,
        );
        await tap(tester, find.byKey(settingsKey));
        expect(options, findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await flushIO(tester);
        await open(english.path);
        expect(options, findsOneWidget);
        expect(selected(optimizeKey), isFalse);
        expect(selected(translateKey), isFalse);
        expect(
          (await tester.runAsync(SubtitleFileProcessingSettings.load))!.hasWork,
          isFalse,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await flushIO(tester);
      },
    );
  }

  testWidgets('subtitle header previews', (tester) async {
    const captureUI = bool.fromEnvironment('CAPTURE_SUBTITLE_HEADER');
    if (!captureUI) return;
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final family in [
      'Roboto',
      '.SF Pro Text',
      '.SF Pro Display',
      'Noto Sans SC',
      'monospace',
    ]) {
      await tester.runAsync(
        () =>
            (FontLoader(family)..addFont(
                  rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
                ))
                .load(),
      );
    }
    for (final font in {
      'Inter': 'assets/fonts/Inter-Regular.otf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      await tester.runAsync(
        () =>
            (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load(),
      );
    }
    final capture = GlobalKey();
    for (final music in [false, true]) {
      for (final size in [
        const Size(390, 844),
        const Size(768, 900),
        const Size(1280, 900),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await pumpPage(
          tester,
          Theme(
            data: ThemeData.dark(),
            child: music
                ? const MusicSubtitleManagementDialog()
                : Scaffold(
                    backgroundColor: const Color(0xFF151618),
                    body: Center(
                      child: SizedBox(
                        width: size.width > 700 ? 640 : size.width,
                        child: SubtitleManagementSheet(
                          key: ValueKey(size),
                          videoPath: item.path,
                          videoId: item.id,
                          showEmbeddedSubtitles: false,
                          associatedSubtitles: item.downloadAssociatedSubtitles,
                          onSubtitleChanged: () {},
                          onOpenAi: () {},
                        ),
                      ),
                    ),
                  ),
          ),
          capture: capture,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'artifacts/subtitle_header_redesign/${music ? 'music' : 'standard'}-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await flushIO(tester);
      }
    }
  });

  testWidgets('subtitle processing previews', (tester) async {
    const captureUI = bool.fromEnvironment('CAPTURE_SUBTITLE_PROCESSING');
    if (!captureUI) return;
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final family in [
      'Roboto',
      '.SF Pro Text',
      '.SF Pro Display',
      'Noto Sans SC',
      'monospace',
    ]) {
      await tester.runAsync(
        () =>
            (FontLoader(family)..addFont(
                  rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
                ))
                .load(),
      );
    }
    for (final font in {
      'Inter': 'assets/fonts/Inter-Regular.otf',
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      await tester.runAsync(
        () =>
            (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load(),
      );
    }
    await tester.runAsync(
      () => SubtitleFileProcessingSettings.update(
        optimize: false,
        translate: true,
      ),
    );
    final capture = GlobalKey();
    for (final size in [const Size(390, 844), const Size(1280, 900)]) {
      await tester.binding.setSurfaceSize(size);
      await pumpPage(
        tester,
        Theme(
          data: ThemeData.dark(),
          child: Scaffold(
            backgroundColor: const Color(0xFF151618),
            body: Center(
              child: SizedBox(
                width: size.width > 700 ? 640 : size.width,
                child: SubtitleManagementSheet(
                  key: ValueKey(size),
                  videoPath: item.path,
                  videoId: item.id,
                  showEmbeddedSubtitles: false,
                  associatedSubtitles: item.downloadAssociatedSubtitles,
                  onSubtitleChanged: () {},
                  onOpenAi: () {},
                ),
              ),
            ),
          ),
        ),
        capture: capture,
      );
      await tap(tester, find.byTooltip('优化 / 翻译字幕').first);
      for (final expanded in [true, false]) {
        if (!expanded) {
          await tap(
            tester,
            find.byKey(const ValueKey('subtitle-file-translation-settings')),
          );
        }
        await tester.ensureVisible(
          find.byKey(const ValueKey('subtitle-processing-panel')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'artifacts/subtitle_processing_redesign/${size.width < 700 ? 'mobile' : 'desktop'}-${expanded ? 'expanded' : 'compact'}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await flushIO(tester);
    }
  });

  testWidgets(
    'music manager fits small landscape, portrait and desktop viewports',
    (tester) async {
      const captureUI = bool.fromEnvironment('CAPTURE_MUSIC_UI');
      if (captureUI) {
        for (final family in [
          'Roboto',
          '.SF Pro Text',
          '.SF Pro Display',
          'Noto Sans SC',
        ]) {
          await tester.runAsync(
            () =>
                (FontLoader(family)..addFont(
                      rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'),
                    ))
                    .load(),
          );
        }
        for (final font in {
          'Inter': 'assets/fonts/Inter-Regular.otf',
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          'packages/cupertino_icons/CupertinoIcons':
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
        }.entries) {
          await tester.runAsync(
            () => (FontLoader(
              font.key,
            )..addFont(rootBundle.load(font.value))).load(),
          );
        }
      }
      final capture = GlobalKey();
      for (final size in [
        const Size(480, 320),
        const Size(844, 390),
        const Size(390, 844),
        const Size(1440, 900),
      ]) {
        await tester.binding.setSurfaceSize(size);
        await pumpPage(
          tester,
          const MusicSubtitleManagementDialog(),
          capture: capture,
        );
        await flushIO(tester);
        expect(tester.takeException(), isNull, reason: '$size');
        expect(find.text('导入字幕').hitTestable(), findsOneWidget);
        expect(find.text('语音转录').hitTestable(), findsOneWidget);
        if (captureUI) {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '.artifacts/music-player/subtitle-manager-${size.width.toInt()}x${size.height.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      if (captureUI) {
        await tester.binding.setSurfaceSize(const Size(844, 390));
        playback.setSubtitleState(
          paths: [],
          primary: [
            SubtitleItem(
              index: 0,
              startTime: Duration.zero,
              endTime: const Duration(seconds: 4),
              text: 'In the quiet of the night',
            ),
            SubtitleItem(
              index: 1,
              startTime: const Duration(seconds: 5),
              endTime: const Duration(seconds: 9),
              text: 'We find a little light',
            ),
            SubtitleItem(
              index: 2,
              startTime: const Duration(seconds: 10),
              endTime: const Duration(seconds: 14),
              text: 'And let the music play',
            ),
          ],
          secondary: [],
        );
        await pumpPage(tester, const MusicPlayerScreen(), capture: capture);
        await tester.pumpAndSettle();
        Future<void> snapshot(String name) async {
          final boundary =
              capture.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              '.artifacts/music-player/$name.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await snapshot('apple-music-subtitle-entry');
        await tap(
          tester,
          find.byKey(const ValueKey('music-landscape-subtitle-management')),
        );
        await tester.pumpAndSettle();
        await snapshot('apple-music-subtitle-modal');
        await tester.tap(
          find.byKey(const ValueKey('music-subtitle-dialog-close')),
        );
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(host(const SizedBox.shrink()));
      await tester.binding.setSurfaceSize(null);
    },
  );
}

class _Embedded extends EmbeddedSubtitleService {
  @override
  Future<List<EmbeddedSubtitleTrack>> getEmbeddedSubtitles(
    String videoPath,
  ) async => [];
}

class _StreamingManager extends TranscriptionManager {
  _StreamingManager({required super.settings});
  SubtitleStreamUpdate? current;
  int stops = 0, resumes = 0;
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => [?current];
  @override
  SubtitleStreamUpdate? streamForPath(String path) =>
      current?.paths.contains(path) == true ? current : null;
  void publish(SubtitleStreamUpdate update) {
    current = update;
    subtitleFilesRevision.value++;
  }

  @override
  Future<void> stopStreamForPath(String path) async {
    stops++;
  }

  @override
  void resumeStreamForPath(String path) {
    resumes++;
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getDownloadsPath() async => path;
}
