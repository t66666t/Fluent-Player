import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_actions.dart';
import 'package:video_player_app/features/media_cache/media_cache_badge.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/media_cache/media_cache_screen.dart';
import 'package:video_player_app/features/media_cache/media_cache_selection.dart';
import 'package:video_player_app/features/media_cache/media_cache_variants_dialog.dart';
import 'package:video_player_app/features/media_cache/media_cache_widgets.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/widgets/playback_card_layout.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';

import 'media_cache_service_test.dart' show FakeBackend, source, until;

class _Backend extends FakeBackend {
  _Backend(super.root);
  Completer<List<CacheQuality>>? response;
  bool offline = false;
  @override
  Future<List<CacheQuality>> qualities(CacheSource source) async {
    if (offline) throw StateError('offline');
    if (response != null) return response!.future;
    return [
      for (final height in [360, 720, 1080, 2160])
        CacheQuality(
          id: '$height',
          label: '${height}P',
          height: height,
          revision: 'v1',
        ),
    ];
  }
}

class _Service extends MediaCacheService {
  _Service({required super.backend, required super.journal})
    : super(observeNetwork: false);
  void phase(String id, CacheTaskState state) {
    tasks.singleWhere((task) => task.id == id).state = state;
    notifyListeners();
  }
}

class _Playback extends ChangeNotifier implements MediaPlaybackService {
  bool visible = false;
  @override
  bool get shouldShowMiniPlaybackCard => visible;
  void show(bool value) {
    visible = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected playback call: ${invocation.memberName}');
}

Future<void> _finish(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_MEDIA_CACHE_UI')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final picture = await boundary.toImage();
    final bytes = await picture.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    final directory = await Directory(
      '.artifacts/media-cache',
    ).create(recursive: true);
    await File(
      '${directory.path}/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

bool _enabled(String tooltip) {
  final buttons = find
      .byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      )
      .evaluate();
  return buttons.length == 1 &&
      (buttons.single.widget as IconButton).onPressed != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Backend backend;
  late _Service service;
  MediaCacheService? previous;
  final one = source('one'), other = source('other');

  setUpAll(() async {
    if (!const bool.fromEnvironment('CAPTURE_MEDIA_CACHE_UI')) return;
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader(
        'CacheUiPreview',
      )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() async {
    previous = MediaCacheService.instance;
    root = await Directory.systemTemp.createTemp('cache-card-ui-');
    backend = _Backend(root);
    final variants = <CacheVariant>[];
    for (final item in [(one, 360), (one, 720), (other, 1080)]) {
      final directory = await Directory(
        '${root.path}/${item.$1.itemId}',
      ).create();
      final file = await File(
        '${directory.path}/${item.$2}.mp4',
      ).writeAsBytes([1, 2, 3, 4]);
      variants.add(
        CacheVariant(
          source: item.$1,
          quality: CacheQuality(
            id: '${item.$2}',
            label: '${item.$2}P',
            height: item.$2,
            revision: 'v1',
          ),
          path: file.path,
          bytes: 4,
          createdAt: 1,
        ),
      );
    }
    final tasks = [
      for (final height in [1080, 2160])
        CacheTask(
          id: '$height',
          source: one,
          createdAt: height,
          requestedQuality: '$height',
          state: CacheTaskState.paused,
          quality: CacheQuality(
            id: '$height',
            label: '${height}P',
            height: height,
            revision: 'v1',
          ),
          received: 50,
          total: 100,
        ),
    ];
    final journal = File('${root.path}/index.json');
    await journal.writeAsString(
      jsonEncode({
        'version': 1,
        'tasks': tasks.map((task) => task.toJson()).toList(),
        'variants': variants.map((variant) => variant.toJson()).toList(),
      }),
    );
    service = _Service(backend: backend, journal: journal);
    await service.initialize();
    service.preferences.pruneLower = false;
    MediaCacheService.instance = service;
  });
  tearDown(() async {
    MediaCacheService.instance = previous;
    await service.shutdown();
    service.dispose();
    await root.delete(recursive: true);
  });

  void uiTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        // Native filesystem callbacks outlive a frame. Unmount observers and
        // finish transfers and journal writes while the fake clock is active.
        await tester.pumpWidget(const SizedBox.shrink());
        var drained = false;
        unawaited(
          service.shutdown().then<void>(
            (_) {
              drained = true;
            },
            onError: (Object _) {
              drained = true;
            },
          ),
        );
        await _finish(tester, () => drained);
      }
    });
  }

  test(
    'visible media watches external deletions and keeps other media intact',
    () async {
      final stop = service.observeMediaAvailability(one.key);
      final duplicate = service.observeMediaAvailability(one.key);
      await service.refreshAvailability(mediaKey: one.key);
      duplicate();
      final variants = service.variantsFor(one.key);
      await File(variants.first.path).delete();
      await until(() => service.variantsFor(one.key).length == 1);
      expect(service.hasCache(one.key), isTrue);
      await File(variants.last.path).delete();
      await until(() => !service.hasCache(one.key));
      expect(service.hasCache(other.key), isTrue);
      expect(service.taskFor(one.key)!.state, CacheTaskState.paused);
      stop();
    },
  );

  test(
    'unavailable storage suppresses the badge without forgetting its index',
    () async {
      final directory = Directory('${root.path}/one');
      final parked = '${root.path}/one-unmounted';
      await directory.rename(parked);
      await service.refreshAvailability(mediaKey: one.key);
      expect(service.hasCache(one.key), isFalse);
      expect(
        service.variants.where((v) => v.source.key == one.key),
        hasLength(2),
      );
      expect(service.hasCache(other.key), isTrue);
      await Directory(parked).rename(directory.path);
      await service.refreshAvailability(mediaKey: one.key);
      expect(service.hasCache(one.key), isTrue);
    },
  );

  uiTest(
    'blue progress exists only for active work, even after another paused task',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 12,
              child: CacheCardProgress(source: one, onOpen: () {}),
            ),
          ),
        ),
      );
      for (final phase in CacheTaskState.values) {
        service.phase('2160', phase);
        await tester.pump();
        expect(
          find.byType(LinearProgressIndicator),
          phase.running ? findsOneWidget : findsNothing,
          reason: phase.name,
        );
      }
    },
  );

  uiTest(
    'badge follows usable files, not completion history or partial tasks',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 240,
              height: 135,
              child: CacheCardBadge(source: one),
            ),
          ),
        ),
      );
      await _finish(
        tester,
        () => find
            .byKey(const ValueKey('cache-card-badge'))
            .evaluate()
            .isNotEmpty,
      );
      final variants = service.variantsFor(one.key);
      await tester.runAsync(() => service.deleteVariant(variants.first.id));
      await tester.pump();
      expect(find.byKey(const ValueKey('cache-card-badge')), findsOneWidget);
      await tester.runAsync(() => service.deleteVariant(variants.last.id));
      await tester.pump();
      expect(find.byKey(const ValueKey('cache-card-badge')), findsNothing);
      service.phase('1080', CacheTaskState.completed);
      await tester.pump();
      expect(find.byKey(const ValueKey('cache-card-badge')), findsNothing);
      expect(service.hasCache(other.key), isTrue);
    },
  );

  uiTest('a leased file pending deletion is not presented as cached', (
    tester,
  ) async {
    final variants = service.variantsFor(one.key);
    final kept = variants.first;
    final lease = await tester.runAsync(
      () => service.acquire(one.toItem(), qualityId: kept.quality.id),
    );
    expect(lease, isNotNull);
    await tester.runAsync(() => service.deleteVariant(variants.last.id));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 135,
            child: CacheCardBadge(source: one),
          ),
        ),
      ),
    );
    await _finish(
      tester,
      () =>
          find.byKey(const ValueKey('cache-card-badge')).evaluate().isNotEmpty,
    );
    await tester.runAsync(() => service.deleteVariant(kept.id));
    await tester.pump();
    expect(await tester.runAsync(() => File(kept.path).exists()), isTrue);
    expect(find.byKey(const ValueKey('cache-card-badge')), findsNothing);
    await tester.runAsync(() => lease!.release());
  });

  uiTest(
    'a cached grid card can show active progress and moves its badge away from selection',
    (tester) async {
      Widget card(bool selecting) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 200,
              child: MediaLibraryGridCard(
                radius: 12,
                isSelected: false,
                isSelectionMode: selecting,
                onTap: () {},
                cacheItem: one.toItem(),
                child: const ColoredBox(color: Colors.white),
              ),
            ),
          ),
        ),
      );
      service.phase('2160', CacheTaskState.downloading);
      await tester.pumpWidget(card(false));
      final badge = find.byKey(const ValueKey('cache-card-badge'));
      await _finish(tester, () => badge.evaluate().isNotEmpty);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final right = tester.getRect(badge).center.dx;
      service.phase('2160', CacheTaskState.completed);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(badge, findsOneWidget);
      await tester.pumpWidget(card(true));
      expect(tester.getRect(badge).center.dx, lessThan(right));
    },
  );

  uiTest('badge proportions and monochrome contrast hold across cover sizes', (
    tester,
  ) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final extent in [72.0, 108.0, 144.0])
                  for (final color in [Colors.white, Colors.black])
                    SizedBox(
                      width: extent * 16 / 9,
                      height: extent,
                      child: ColoredBox(
                        color: color,
                        child: CacheCardBadge(source: one),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
    await _finish(
      tester,
      () =>
          find.byKey(const ValueKey('cache-card-badge')).evaluate().length == 6,
    );
    final badges = find.byKey(const ValueKey('cache-card-badge'));
    final sizes = [
      for (var i = 0; i < 6; i++) tester.getSize(badges.at(i)).width,
    ];
    expect(sizes, [18, 18, 27, 27, 36, 36]);
    final surface =
        (tester.widget<Container>(badges.first).decoration! as BoxDecoration)
            .color!;
    expect(surface.r, surface.g);
    expect(surface.g, surface.b);
    await _capture(tester, key, 'cache-badges-monochrome');
  });

  for (final size in [
    const Size(320, 640),
    const Size(640, 320),
    const Size(768, 1024),
    const Size(1440, 900),
  ]) {
    for (final scale in [1.0, 2.0]) {
      uiTest('media window fits $size / $scale with a changing mini player', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
        tester.view.systemGestureInsets = const FakeViewPadding(bottom: 24);
        addTearDown(tester.view.reset);
        final playback = _Playback();
        addTearDown(playback.dispose);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData.dark(useMaterial3: true).copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'CacheUiPreview',
                ),
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Stack(
                  children: [
                    ListenableBuilder(
                      listenable: playback,
                      builder: (context, _) => playback.visible
                          ? Positioned(
                              left: 12,
                              right: 12,
                              bottom: 34,
                              height: PlaybackCardLayout.calculate(
                                context,
                              ).height,
                              child: const ColoredBox(
                                color: Color(0xff303033),
                                child: Center(
                                  child: Text('mini playback card'),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    MediaCacheVariantsDialog(
                      service: service,
                      source: one,
                      playback: playback,
                      reserveMiniPlayer: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        for (final visible in [false, true, false]) {
          playback.show(visible);
          await tester.pump();
          final panel = find.byKey(
            const ValueKey('media-cache-variants-dialog'),
          );
          final rect = tester.getRect(panel);
          expect(rect.left, greaterThanOrEqualTo(12));
          expect(rect.right, lessThanOrEqualTo(size.width - 12));
          expect(rect.top, greaterThanOrEqualTo(24));
          final context = tester.element(panel);
          final reserved = visible
              ? PlaybackCardLayout.calculate(context).height + 6
              : 0;
          expect(rect.bottom, lessThanOrEqualTo(size.height - 34 - reserved));
          expect(rect.height, lessThanOrEqualTo(620));
          expect(rect.width, lessThanOrEqualTo(560));
          expect(tester.takeException(), isNull);
          if (visible &&
              scale == 1 &&
              [320.0, 768.0, 1440.0].contains(size.width)) {
            await _capture(tester, key, 'cache-panel-${size.width.toInt()}');
          }
        }
        final scroll = find.descendant(
          of: find.byType(MediaCacheVariantsDialog),
          matching: find.byType(SingleChildScrollView),
        );
        await tester.drag(scroll, const Offset(0, -700));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }

  uiTest(
    'local variants are immediately manageable while online qualities fail and retry',
    (tester) async {
      backend.response = Completer<List<CacheQuality>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaCacheVariantsDialog(service: service, source: one),
          ),
        ),
      );
      await tester.pump();
      expect(find.byTooltip('删除 360P 缓存'), findsOneWidget);
      expect(find.byTooltip('删除 720P 缓存'), findsOneWidget);
      expect(find.text(other.title), findsNothing);
      backend.response!.completeError(StateError('offline'));
      await tester.pump();
      expect(find.textContaining('已有缓存仍可管理'), findsOneWidget);
      await tester.tap(find.byTooltip('删除 360P 缓存'));
      await _finish(tester, () => service.variantsFor(one.key).length == 1);
      expect(service.hasCache(other.key), isTrue);
      backend.response = null;
      await tester.tap(find.text('重新获取'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('cache-variant-quality-2160')),
        findsOneWidget,
      );
      expect(find.textContaining('已有缓存仍可管理'), findsNothing);
    },
  );

  uiTest(
    'isolated video cache belongs to its normal quality row and can be completed or removed',
    (tester) async {
      final file = await tester.runAsync(
        () =>
            File('${root.path}/one/1080-track.m4s').writeAsBytes([9, 8, 7, 6]),
      );
      await tester.runAsync(
        () => service.registerMaterial([
          CacheVariant(
            source: one,
            quality: const CacheQuality(
              id: '1080',
              label: '1080P',
              height: 1080,
              revision: 'v1',
              codec: 'avc1',
            ),
            path: file!.path,
            bytes: 4,
            createdAt: 1,
            content: CacheContent.video,
          ),
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CacheQualityAction(source: one, qualityId: '1080'),
          ),
        ),
      );
      await tester.pump();
      expect(find.byTooltip('此画质已缓存'), findsNothing);
      expect(find.byTooltip('视频轨已缓存，完整离线播放仍需补齐其余轨道'), findsOneWidget);
      expect(find.text('视频轨'), findsOneWidget);
      expect(find.byTooltip('删除此画质缓存'), findsOneWidget);
      expect(find.byTooltip('继续缓存此画质'), findsOneWidget);
      await tester.tap(find.byTooltip('继续缓存此画质'));
      await _finish(
        tester,
        () => find.byTooltip('此画质已缓存').evaluate().isNotEmpty,
      );
      expect(find.byTooltip('此画质已缓存'), findsOneWidget);
      await tester.tap(find.byTooltip('删除此画质缓存'));
      await _finish(
        tester,
        () => service.variantsFor(one.key).every((v) => v.quality.id != '1080'),
      );
      expect(service.variantsFor(other.key), hasLength(1));
    },
  );

  uiTest('quality controls pause, resume and cancel only this media task', (
    tester,
  ) async {
    backend.slow = true;
    service.phase('1080', CacheTaskState.downloading);
    final playback = _Playback();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaCacheVariantsDialog(
            service: service,
            source: one,
            playback: playback,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.byTooltip('暂停 1080P'));
    await tester.tap(find.byTooltip('暂停 1080P'));
    await _finish(tester, () => _enabled('继续 1080P'));
    await tester.tap(find.byTooltip('继续 1080P'));
    await _finish(
      tester,
      () =>
          service.taskFor(one.key, qualityId: '1080')?.state.running == true &&
          _enabled('取消 1080P 任务'),
    );
    await tester.ensureVisible(find.byTooltip('取消 1080P 任务'));
    await tester.tap(find.byTooltip('取消 1080P 任务'));
    await _finish(
      tester,
      () =>
          service.taskFor(one.key, qualityId: '1080') == null &&
          _enabled('缓存 1080P'),
    );
    expect(service.hasCache(other.key), isTrue);
    expect(service.variantsFor(one.key), hasLength(2));
    await tester.ensureVisible(find.byTooltip('缓存 1080P'));
    await tester.tap(find.byTooltip('缓存 1080P'));
    await _finish(
      tester,
      () => service.variantsFor(one.key).any((v) => v.quality.id == '1080'),
    );
    expect(service.hasCache(other.key), isTrue);
    playback.dispose();
  });

  uiTest(
    'delete all is scoped to this media and retains online task identity',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaCacheVariantsDialog(service: service, source: one),
          ),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('cache-variants-delete-all')),
      );
      await tester.tap(find.byKey(const ValueKey('cache-variants-delete-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除缓存'));
      await _finish(
        tester,
        () => !service.hasCache(one.key) && service.taskFor(one.key) == null,
      );
      expect(service.hasCache(other.key), isTrue);
      expect(find.text(one.title), findsOneWidget);
      expect(find.byTooltip('缓存 360P'), findsOneWidget);
    },
  );

  uiTest(
    'cloud card manage opens only its quality window and can add a download',
    (tester) async {
      const entry = CloudDriveEntry(
        providerId: 'baidu',
        accountLocalId: 'local',
        remoteAccountId: 'remote',
        driveId: '0',
        fileId: 'own-media',
        parentFileId: 'root',
        name: '只管理这个网盘视频.mp4',
        kind: CloudDriveEntryKind.video,
      );
      final cloud = cacheSourceForCloudEntry(entry)!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox.square(
                dimension: 36,
                child: CloudEntryCacheMenu(entry: entry),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('cloud-entry-cache-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('管理缓存'));
      await _finish(
        tester,
        () => find
            .byKey(const ValueKey('media-cache-variants-dialog'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(MediaCacheScreen), findsNothing);
      expect(find.text(entry.name), findsOneWidget);
      expect(find.text(one.title), findsNothing);
      await _finish(tester, () => _enabled('缓存 360P'));
      await tester.ensureVisible(find.byTooltip('缓存 360P'));
      await tester.tap(find.byTooltip('缓存 360P'));
      await _finish(tester, () => service.hasCache(cloud.key));
      expect(service.variantsFor(cloud.key).single.quality.id, '360');
      expect(service.variantsFor(one.key), hasLength(2));
      expect(service.hasCache(other.key), isTrue);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('media-cache-variants-dialog')),
        findsNothing,
      );
    },
  );
}
