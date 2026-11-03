import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_screen.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/media_cache/media_cache_widgets.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'media_cache_service_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MediaCacheService service;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('media_cache_layout_');
    final sources = [
      const CacheSource(
        ref: MediaSourceRef(
          value: 'BV1',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1',
          cid: 100,
        ),
        itemId: 'one',
        title: '星空之下 · 一段漫长的旅行',
        kind: MediaType.video,
      ),
      const CacheSource(
        ref: MediaSourceRef(
          value: 'cloud-drive://baidu/file',
          kind: MediaSourceKind.cloudDrive,
          cloudDrive: CloudDriveSourceRef(
            providerId: 'baidu',
            remoteAccountId: 'one',
            driveId: '0',
            fileId: 'two',
          ),
        ),
        itemId: 'two',
        title: '摄影课程 · 光线与构图.mp4',
        kind: MediaType.video,
      ),
    ];
    final file = File(p.join(root.path, 'complete.mp4'))
      ..writeAsBytesSync(List.filled(100, 1));
    final tasks = [
      for (var i = 0; i < 2; i++)
        CacheTask(
          id: '$i',
          source: sources[i],
          state: CacheTaskState.paused,
          createdAt: i,
          received: 360 * 1024 * 1024,
          total: 800 * 1024 * 1024,
          quality: const CacheQuality(
            id: '1080',
            label: '1080P 高清',
            height: 1080,
          ),
        ),
    ];
    File(p.join(root.path, 'media_cache.json')).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'variants': [
          CacheVariant(
            source: sources[0],
            quality: const CacheQuality(
              id: '80',
              label: '1080P 高清',
              height: 1080,
            ),
            path: file.path,
            bytes: 100,
            createdAt: 1,
          ).toJson(),
        ],
      }),
    );
    service = MediaCacheService(
      backend: FakeBackend(root),
      journal: File(p.join(root.path, 'media_cache.json')),
      observeNetwork: false,
    );
    await service.initialize();
    MediaCacheService.instance = service;
    service.tasks.first.state = CacheTaskState.downloading;
    service.tasks.first.bytesPerSecond = 12.5 * 1024 * 1024;
  });
  tearDown(() async {
    await service.shutdown();
    service.dispose();
    await root.delete(recursive: true);
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 320),
    const Size(768, 1024),
    const Size(1440, 900),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cache manager stays scrollable at $size / $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = FakeViewPadding(bottom: 24);
        tester.view.systemGestureInsets = FakeViewPadding(bottom: 24);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: MediaCacheScreen(service: service),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        final scroll = find.byType(CustomScrollView);
        await tester.drag(scroll, const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('cache-task-0')), findsOneWidget);
        expect(tester.takeException(), isNull);
        tester.widget<CustomScrollView>(scroll).controller!.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('已缓存 1'));
        await tester.tap(find.text('已缓存 1'));
        await tester.pumpAndSettle();
        await tester.drag(scroll, const Offset(0, -800));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'retrying tasks expose pause and selection limits the bulk operation',
    (tester) async {
      service.tasks[0].state = CacheTaskState.retrying;
      service.tasks[1].state = CacheTaskState.retrying;
      await tester.pumpWidget(
        MaterialApp(home: MediaCacheScreen(service: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂停'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('cache-task-select-0')));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('暂停所选 1 项'));
        await service.flush();
      });
      await tester.pump();
      expect(service.tasks[0].state, CacheTaskState.paused);
      expect(service.tasks[1].state, CacheTaskState.retrying);
      service.tasks[0].state = CacheTaskState.failed;
      await tester.pumpWidget(
        MaterialApp(home: MediaCacheScreen(service: service)),
      );
      await tester.pump();
      expect(find.text('重试'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '继续所选 0 项'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextField).first, '不存在的媒体');
      await tester.pump();
      expect(find.text('已选 1 项'), findsNothing);
      expect(find.text('全选当前列表'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'settings fit a small screen with large text and keyboard insets',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: MediaCacheSettings(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('settings open on Windows through the modal route', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMediaCacheSettings(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('缓存设置'), findsOneWidget);
  });

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(800, 360),
  ]) {
    testWidgets('settings stay compact and editable at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      service.preferences.limits['bilibili'] = 900;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: MediaCacheSettings(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final label = tester.getRect(find.text('哔哩哔哩'));
      final dropdown = tester.getRect(find.byType(DropdownButton<int>).first);
      expect((label.center.dy - dropdown.center.dy).abs(), lessThan(2));
      expect(find.text('900P'), findsWidgets);
      await tester.ensureVisible(find.byTooltip('增加同时缓存任务'));
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('增加同时缓存任务'));
        await service.flush();
      });
      await tester.pumpAndSettle();
      expect(service.preferences.parallelTasks, 3);
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    });
  }

  testWidgets('blue gray count badge hides zero and excludes paused tasks', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaCacheCountBadge(
            child: const Icon(Icons.download_outlined),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);
    service.tasks.first.state = CacheTaskState.paused;
    await tester.runAsync(service.updatePreferences);
    await tester.pump();
    expect(find.text('1'), findsNothing);
    expect(find.text('0'), findsNothing);
  });
  testWidgets('cache screen preview', (tester) async {
    if (!Platform.isWindows ||
        !Platform.environment.containsKey('CACHE_PREVIEW')) {
      return;
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('CachePreview')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    final icons = File(
      'D:/FlutterSDK/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(ByteData.sublistView(icons.readAsBytesSync())),
          ))
          .load();
    }
    for (final size in [const Size(390, 844), const Size(1200, 800)]) {
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme:
              ThemeData(
                colorScheme: ColorScheme.fromSeed(
                  seedColor: const Color(0xFF4B8EF0),
                  brightness: Brightness.dark,
                ),
              ).copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'CachePreview',
                ),
              ),
          home: RepaintBoundary(
            key: const ValueKey('preview'),
            child: Platform.environment.containsKey('CACHE_SETTINGS_PREVIEW')
                ? Scaffold(
                    body: Align(
                      alignment: Alignment.bottomCenter,
                      child: Material(
                        color: const Color(0xFF202020),
                        child: MediaCacheSettings(service: service),
                      ),
                    ),
                  )
                : MediaCacheScreen(service: service),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final prefix =
            Platform.environment.containsKey('CACHE_SETTINGS_PREVIEW')
            ? 'settings-'
            : '';
        final output = File(
          '.artifacts/media-cache/$prefix${size.width.toInt()}.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }
    tester.view.reset();
  });
}
