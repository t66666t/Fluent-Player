import 'dart:async';
import 'dart:io';
import 'package:video_player_app/models/import_card_placement.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili/bilibili_import_buttons.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_quick_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/library_folder_picker.dart';

const _bvid = 'BV1xx411c7mD';
const _otherBvid = 'BV1GJ411x7h7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late LibraryService library;
  late SettingsService settings;
  late BilibiliHistoryService history;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = SettingsService()..resetForTest();
    await settings.init();
    history = BilibiliHistoryService.instance..resetForTest();
    root = await Directory.systemTemp.createTemp('bilibili_quick_import_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TempPathProvider(root.path);
    settings.largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    settings.resetForTest();
    settings.largeDataRootPath = null;
    history.resetForTest();
    PathProviderPlatform.instance = originalPathProvider;
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // Left to the system temp cleanup.
    }
  });

  BilibiliDownloadService newService(_FakeApi api) {
    final service = BilibiliDownloadService(apiService: api);
    addTearDown(service.shutdown);
    return service;
  }

  Future<BilibiliQuickImportResult> quickImport(
    BilibiliDownloadService service, {
    String bvid = _bvid,
    int? page,
    BilibiliImportTarget? target,
    bool? allParts,
    bool remember = false,
    String? playingItemId,
  }) {
    return runBilibiliQuickImport(
      service: service,
      library: library,
      bvid: bvid,
      page: page,
      target: target,
      allParts: allParts,
      rememberTarget: remember,
      settings: settings,
      history: history,
      playingItemId: playingItemId,
    );
  }

  /// Library writes run one after another on a single chain. A link made on
  /// a widget test's fake clock would stall every later write (its callbacks
  /// are scheduled on that clock), so such a test moves the chain back onto
  /// the real clock before it ends.
  Future<void> releaseLibraryQueue(WidgetTester tester) async {
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        library.saveLibraryForTesting().whenComplete(() => done = true),
      );
    });
    for (var i = 0; i < 200 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    expect(done, isTrue);
  }

  group('one-tap import', () {
    test('goes to the default place and says where', () async {
      final service = newService(_FakeApi());
      final result = await quickImport(service);
      expect(result.createdAny, isTrue);
      expect(result.item.isTransient, isFalse);
      expect(library.bilibiliStreamItems, [result.item]);
      expect(result.item.parentId, isNull);
      expect(result.message, '已导入到 媒体库根目录');

      final folder = await library.createCollection('学习', null);
      await settings.updateSetting<String>(
        'bilibiliImportTarget',
        BilibiliImportTarget.folder(folder.id).encode(),
      );
      final next = await quickImport(service, bvid: _otherBvid);
      expect(next.item.parentId, folder.id);
      expect(next.message, '已导入到 学习');
    });

    test('a place picked once becomes the new default', () async {
      final service = newService(_FakeApi());
      final folder = await library.createCollection('稍后看', null);
      final picked = await quickImport(
        service,
        target: BilibiliImportTarget.picked(folder.id),
        remember: true,
      );
      expect(picked.item.parentId, folder.id);
      expect(settings.bilibiliImportTarget, 'folder:${folder.id}');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bilibiliImportTarget'), 'folder:${folder.id}');

      final next = await quickImport(service, bvid: _otherBvid);
      expect(next.item.parentId, folder.id);

      // Picking without "set as default" leaves the default alone.
      await quickImport(
        service,
        bvid: 'BV1Q541167Qg',
        target: BilibiliImportTarget.root,
      );
      expect(settings.bilibiliImportTarget, 'folder:${folder.id}');
    });

    test(
      'a deleted default folder asks for a new target without rerouting',
      () async {
        final service = newService(_FakeApi());
        await settings.updateSetting<String>(
          'bilibiliImportTarget',
          BilibiliImportTarget.folder('gone-folder').encode(),
        );
        await expectLater(
          quickImport(service),
          throwsA(isA<ImportPlacementException>()),
        );
        expect(settings.bilibiliImportTarget, 'folder:gone-folder');
        expect(library.getContents(null).whereType<VideoItem>(), isEmpty);

        // A folder in the recycle bin counts as deleted too.
        final binned = await library.createCollection('回收', null);
        binned.isRecycled = true;
        await settings.updateSetting<String>(
          'bilibiliImportTarget',
          BilibiliImportTarget.folder(binned.id).encode(),
        );
        await expectLater(
          quickImport(service, bvid: _otherBvid),
          throwsA(isA<ImportPlacementException>()),
        );
      },
    );

    test(
      'a default folder inside a binned folder is an unavailable target',
      () async {
        final service = newService(_FakeApi());
        final courses = await library.createCollection('课程', null);
        final math = await library.createCollection('数学', courses.id);
        await settings.updateSetting<String>(
          'bilibiliImportTarget',
          BilibiliImportTarget.folder(math.id).encode(),
        );
        // Only the folder moved to the bin is marked, not the one inside it.
        await library.moveToRecycleBin([courses.id]);
        expect(library.getCollection(math.id)?.isRecycled, isFalse);

        await expectLater(
          quickImport(service),
          throwsA(isA<ImportPlacementException>()),
        );
        expect(settings.bilibiliImportTarget, 'folder:${math.id}');
        expect(library.getContents(null).whereType<VideoItem>(), isEmpty);
      },
    );

    test('an imported part is not imported twice', () async {
      final api = _FakeApi();
      final service = newService(api);
      final first = await quickImport(service);
      final requests = api.infoRequests;
      final second = await quickImport(service);
      expect(second.alreadyImported, isTrue);
      expect(second.item, same(first.item));
      expect(second.message, '已在媒体库中（媒体库根目录），未重复导入');
      expect(api.infoRequests, requests, reason: 'nothing was fetched');
      expect(library.bilibiliStreamItems, hasLength(1));

      // Even with a place picked, the existing card is kept.
      final picked = await quickImport(
        service,
        target: BilibiliImportTarget.root,
      );
      expect(picked.createdAny, isFalse);
      expect(library.bilibiliStreamItems, hasLength(1));
    });

    test('the watch-only card being watched becomes the library card, '
        'position kept, only one card', () async {
      final service = newService(_FakeApi(pages: 1));
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        history: history,
      );
      final watchOnly = plan.item;
      expect(watchOnly.isTransient, isTrue);
      await library.updateVideoProgress(watchOnly.id, 90000);
      final folder = await library.createCollection('学习', null);

      final result = await quickImport(
        service,
        target: BilibiliImportTarget.picked(folder.id),
        playingItemId: watchOnly.id,
      );
      expect(result.item, same(watchOnly));
      expect(result.item.isTransient, isFalse);
      expect(result.item.lastPositionMs, 90000);
      expect(result.message, '已导入到 学习');
      expect(library.transientVideos, isEmpty);
      expect(library.bilibiliStreamItems, [watchOnly]);
      expect(library.getVideo(watchOnly.id), same(watchOnly));
      expect(
        library.getContents(folder.id).whereType<VideoItem>().map((v) => v.id),
        [watchOnly.id],
      );
      final recent = library.activityProjection.recentAddedMediaIds();
      expect([
        ...recent.datedIds,
        ...recent.unknownAddedIds,
      ], contains(watchOnly.id));

      // The clean-up no longer touches it.
      final janitor = BilibiliTransientCardJanitor(
        library: library,
        inUseIds: () => const <String>{},
        grace: Duration.zero,
      );
      addTearDown(janitor.dispose);
      expect(await janitor.sweep(), 0);
      expect(library.getVideo(watchOnly.id), same(watchOnly));

      await library.saveLibraryForTesting();
      final saved = await File(
        '${root.path}${Platform.pathSeparator}library.json',
      ).readAsString();
      expect(saved, contains(watchOnly.id));
    });

    test('multi-part: every part is imported and the current part takes the '
        'position from the watch history', () async {
      final service = newService(_FakeApi(pages: 3));
      await history.recordWatch(
        BilibiliWatchHistoryEntry(
          bvid: _bvid,
          title: '三集',
          watchedAt: DateTime(2026, 10, 8),
          page: 2,
          positionMs: 30000,
        ),
      );
      final result = await quickImport(service);
      final cards = library.bilibiliStreamItems;
      expect(cards, hasLength(3));
      expect(result.item.sourceRef?.page, 2);
      expect(result.item.lastPositionMs, 30000);
      final others = cards.where((c) => c.sourceRef?.page != 2);
      expect(others.every((c) => c.lastPositionMs == 0), isTrue);
      // The parts share their own folder inside the target.
      expect(cards.map((c) => c.parentId).toSet(), hasLength(1));
      expect(cards.first.parentId, isNotNull);
      expect(result.currentPartOnly, isFalse);
      expect(result.message, '已导入到 媒体库根目录');
    });

    test('multi-part over the limit: only the current part, and the message '
        'says so', () async {
      final service = newService(
        _FakeApi(pages: kBilibiliAutoFillPartLimit + 1),
      );
      final result = await quickImport(service, page: 7);
      expect(library.bilibiliStreamItems, [result.item]);
      expect(result.item.sourceRef?.page, 7);
      expect(result.currentPartOnly, isTrue);
      expect(result.partCount, 51);
      expect(result.message, '已导入当前P到 媒体库根目录（共 51 P，要导入全部请点右侧按钮）');

      final folder = await library.createCollection('长合集', null);
      final next = await quickImport(
        service,
        bvid: _otherBvid,
        target: BilibiliImportTarget.picked(folder.id),
      );
      expect(next.message, '已导入当前P到 长合集（共 51 P，要导入全部请点右侧按钮）');

      // Asking for one part on purpose keeps the plain message.
      final picked = await quickImport(
        service,
        bvid: 'BV1Q541167Qg',
        target: BilibiliImportTarget.root,
        allParts: false,
      );
      expect(picked.currentPartOnly, isFalse);
      expect(picked.message, '已导入到 媒体库根目录');
    });

    test(
      'a failed promotion leaves the card watch-only and cleanable',
      () async {
        final service = newService(_FakeApi(pages: 1));
        final plan = await prepareBilibiliWatch(
          service: service,
          library: library,
          bvid: _bvid,
          history: history,
        );
        final watchOnly = plan.item;
        expect(watchOnly.isTransient, isTrue);
        final folder = await library.createCollection('学习', null);

        library.failAddSingleVideoAfterInsertForTesting = true;
        await expectLater(
          quickImport(
            service,
            target: BilibiliImportTarget.picked(folder.id),
            playingItemId: watchOnly.id,
          ),
          throwsStateError,
        );
        library.failAddSingleVideoAfterInsertForTesting = false;

        expect(watchOnly.isTransient, isTrue);
        expect(watchOnly.parentId, isNull);
        expect(library.transientVideos, [watchOnly]);
        expect(library.bilibiliStreamItems, isEmpty);
        expect(library.getContents(folder.id), isEmpty);
        expect(library.getContents(null).whereType<VideoItem>(), isEmpty);
        final ledger = await library.transientLedgerFileForTesting
            .readAsString();
        expect(ledger, contains(watchOnly.id));

        final janitor = BilibiliTransientCardJanitor(
          library: library,
          inUseIds: () => const <String>{},
          grace: Duration.zero,
        );
        addTearDown(janitor.dispose);
        expect(await janitor.sweep(), 1);
        expect(library.getVideo(watchOnly.id), isNull);
        expect(await library.transientLedgerFileForTesting.exists(), isFalse);
      },
    );

    test('multi-part: "current part only" from the picker', () async {
      final service = newService(_FakeApi(pages: 3));
      final result = await quickImport(
        service,
        page: 3,
        target: BilibiliImportTarget.root,
        allParts: false,
      );
      expect(library.bilibiliStreamItems, [result.item]);
      expect(result.item.sourceRef?.page, 3);
    });

    test(
      'explicit selected pages imports all 51 and reuses existing parts',
      () async {
        final service = newService(_FakeApi(pages: 51));
        final first = await quickImport(service, page: 1, allParts: false);
        final result = await runBilibiliQuickImport(
          service: service,
          library: library,
          bvid: _bvid,
          selectedPages: List.generate(51, (i) => i + 1),
          settings: settings,
          history: history,
        );
        expect(library.bilibiliStreamItems, hasLength(51));
        expect(result.currentPartOnly, isFalse);
        expect(result.batch?.createdCount, 50);
        expect(library.bilibiliStreamItems.map((c) => c.parentId).toSet(), {
          first.item.parentId,
        });
      },
    );

    test(
      'selected pages excludes current part and rejects empty selection',
      () async {
        final service = newService(_FakeApi(pages: 3));
        final result = await runBilibiliQuickImport(
          service: service,
          library: library,
          bvid: _bvid,
          page: 1,
          selectedPages: [2, 3, 2],
          settings: settings,
          history: history,
        );
        expect(result.batch?.cards.map((c) => c.item.sourceRef?.page), [2, 3]);
        await expectLater(
          runBilibiliQuickImport(
            service: service,
            library: library,
            bvid: _bvid,
            selectedPages: [],
            settings: settings,
            history: history,
          ),
          throwsArgumentError,
        );
        expect(library.bilibiliStreamItems, hasLength(2));
      },
    );

    test('target encoding', () {
      expect(BilibiliImportTarget.parse(''), BilibiliImportTarget.automatic);
      expect(BilibiliImportTarget.parse('root'), BilibiliImportTarget.root);
      expect(
        BilibiliImportTarget.parse('folder:abc'),
        BilibiliImportTarget.folder('abc'),
      );
      expect(
        BilibiliImportTarget.parse('folder:'),
        BilibiliImportTarget.automatic,
      );
      expect(BilibiliImportTarget.picked(null), BilibiliImportTarget.root);
      expect(BilibiliImportTarget.folder('x').encode(), 'folder:x');
    });
  });

  group('folder picker', () {
    // Widget tests run on a fake clock: library.json writes started there
    // would never finish and block later tests, so they are skipped here.
    setUp(() {
      library.writeLibrarySnapshotOverrideForTesting = () async {};
    });

    late VideoCollection courses;
    late VideoCollection math;

    Future<void> seedFolders(WidgetTester tester) async {
      await tester.runAsync(() async {
        courses = await library.createCollection('课程', null);
        math = await library.createCollection('数学', courses.id);
        await library.createCollection('英语', courses.id);
        await library.createCollection('随手', null);
        await library.addSingleVideo(
          VideoItem(
            id: 'local-1',
            path: 'bilibili://stream/$_bvid?cid=101',
            title: '一张卡',
            durationMs: 1000,
            lastUpdated: 1,
            parentId: courses.id,
          ),
          reuseExistingItem: false,
        );
      });
    }

    Future<LibraryFolderPick?> openPicker(
      WidgetTester tester, {
      Size size = const Size(400, 800),
      String? initialFolderId,
      WidgetBuilder? header,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      LibraryFolderPick? result;
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppTextInputFocus(child: child!),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showLibraryFolderPicker(
                    context,
                    library: library,
                    initialFolderId: initialFolderId,
                    header: header,
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      addTearDown(() => expect(closed || true, isTrue));
      return result;
    }

    Finder crumb(String key) =>
        find.byKey(ValueKey('folder-picker-crumb-$key'));
    Finder row(String id) => find.byKey(ValueKey('folder-picker-folder-$id'));

    testWidgets('narrow screens get a bottom sheet, wide ones a dialog', (
      tester,
    ) async {
      await openPicker(tester);
      expect(
        find.byKey(const ValueKey('library-folder-picker-sheet')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      Navigator.of(tester.element(find.byType(LibraryFolderPicker))).pop();
      await tester.pumpAndSettle();

      await openPicker(tester, size: const Size(1280, 800));
      expect(
        find.byKey(const ValueKey('library-folder-picker-dialog')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('breadcrumb shows the path and goes back level by level', (
      tester,
    ) async {
      await seedFolders(tester);
      await openPicker(tester, initialFolderId: math.id);
      expect(crumb('root'), findsOneWidget);
      expect(crumb(courses.id), findsOneWidget);
      expect(crumb(math.id), findsOneWidget);
      expect(find.text('这里没有子文件夹'), findsOneWidget);

      await tester.tap(crumb(courses.id));
      await tester.pumpAndSettle();
      expect(crumb(math.id), findsNothing);
      expect(row(math.id), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('folder-picker-up')));
      await tester.pumpAndSettle();
      expect(crumb(courses.id), findsNothing);
      expect(row(courses.id), findsOneWidget);
    });

    testWidgets('breadcrumb stays left aligned inside a chosen folder', (
      tester,
    ) async {
      await seedFolders(tester);
      await openPicker(
        tester,
        initialFolderId: math.id,
        size: const Size(1280, 800),
      );
      final root = tester.getRect(crumb('root'));
      final search = tester.getRect(
        find.byKey(const ValueKey('folder-picker-search')),
      );
      // The trail used to shrink-wrap and sit in the centre (or on the right
      // when reversed). It should line up with the search field.
      expect((root.left - search.left).abs(), lessThan(12));
      expect(tester.getRect(crumb(math.id)).left, greaterThan(root.left));
    });

    testWidgets('a long breadcrumb keeps the current folder in view', (
      tester,
    ) async {
      late VideoCollection deep;
      await tester.runAsync(() async {
        VideoCollection? parent;
        for (var i = 0; i < 6; i++) {
          parent = await library.createCollection('很长的文件夹名称$i', parent?.id);
        }
        deep = parent!;
      });
      await openPicker(
        tester,
        initialFolderId: deep.id,
        size: const Size(1280, 800),
      );
      final bar = tester.getRect(
        find.byKey(const ValueKey('folder-picker-breadcrumb')),
      );
      final current = tester.getRect(crumb(deep.id));
      expect(current.right, lessThanOrEqualTo(bar.right + 1));
      expect(current.right, greaterThan(bar.right - 48));
      expect(tester.getRect(crumb('root')).left, lessThan(bar.left));
    });

    Future<void> systemBack(WidgetTester tester) async {
      final navigator = Navigator.of(
        tester.element(find.byType(LibraryFolderPicker)),
      );
      expect(await navigator.maybePop(), isTrue);
      await tester.pumpAndSettle();
    }

    testWidgets('phone back and desktop escape step out one folder at a time', (
      tester,
    ) async {
      await seedFolders(tester);
      await openPicker(tester, initialFolderId: math.id);
      await systemBack(tester);
      expect(find.byType(LibraryFolderPicker), findsOneWidget);
      expect(crumb(math.id), findsNothing);
      expect(crumb(courses.id), findsOneWidget);

      await systemBack(tester);
      expect(find.byType(LibraryFolderPicker), findsOneWidget);
      expect(crumb(courses.id), findsNothing);
      expect(row(courses.id), findsOneWidget);

      await systemBack(tester);
      expect(find.byType(LibraryFolderPicker), findsNothing);

      await openPicker(
        tester,
        initialFolderId: math.id,
        size: const Size(1280, 800),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryFolderPicker), findsOneWidget);
      expect(crumb(math.id), findsNothing);
      expect(crumb(courses.id), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(crumb(courses.id), findsNothing);
      expect(row(courses.id), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryFolderPicker), findsNothing);
    });

    testWidgets(
      'back drops the new folder field and search before the folder',
      (tester) async {
        await seedFolders(tester);
        await openPicker(tester, initialFolderId: courses.id);
        await tester.tap(find.byKey(const ValueKey('folder-picker-new')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('folder-picker-new-name')),
          findsOneWidget,
        );

        await systemBack(tester);
        expect(
          find.byKey(const ValueKey('folder-picker-new-name')),
          findsNothing,
        );
        expect(crumb(courses.id), findsOneWidget);

        await tester.enterText(
          find.byKey(const ValueKey('folder-picker-search')),
          '数',
        );
        await tester.pumpAndSettle();
        expect(find.text('媒体库 / 课程 · 0 项'), findsOneWidget);

        await systemBack(tester);
        expect(find.text('媒体库 / 课程 · 0 项'), findsNothing);
        expect(crumb(courses.id), findsOneWidget);
        expect(row(math.id), findsOneWidget);

        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(LibraryFolderPicker), findsNothing);
      },
    );

    testWidgets('each folder shows how many items it holds', (tester) async {
      await seedFolders(tester);
      await openPicker(tester);
      expect(
        find.descendant(of: row(courses.id), matching: find.text('3 项')),
        findsOneWidget,
      );
      await tester.tap(row(courses.id));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: row(math.id), matching: find.text('0 项')),
        findsOneWidget,
      );
    });

    testWidgets('search finds folders on any level with their path', (
      tester,
    ) async {
      await seedFolders(tester);
      await openPicker(tester);
      await tester.enterText(
        find.byKey(const ValueKey('folder-picker-search')),
        '数',
      );
      await tester.pumpAndSettle();
      expect(row(math.id), findsOneWidget);
      expect(find.text('媒体库 / 课程 · 0 项'), findsOneWidget);
      expect(row(courses.id), findsNothing);
      await tester.tap(row(math.id));
      await tester.pumpAndSettle();
      expect(crumb(math.id), findsOneWidget);
    });

    testWidgets('a new folder is created in the current level', (tester) async {
      await seedFolders(tester);
      await openPicker(tester, initialFolderId: courses.id);
      await tester.tap(find.byKey(const ValueKey('folder-picker-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('folder-picker-new-name')),
        '物理',
      );
      final nameField = find.byKey(const ValueKey('folder-picker-new-name'));
      final focus = tester
          .widget<EditableText>(
            find.descendant(of: nameField, matching: find.byType(EditableText)),
          )
          .focusNode;
      final create = find.byKey(const ValueKey('folder-picker-new-confirm'));
      final gesture = await tester.startGesture(tester.getCenter(create));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await gesture.up();
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find
            .byKey(const ValueKey('folder-picker-new-name'))
            .evaluate()
            .isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle();
      final created = library
          .getContents(courses.id)
          .whereType<VideoCollection>()
          .where((f) => f.name == '物理')
          .toList();
      expect(created, hasLength(1));
      expect(created.single.parentId, courses.id);
      expect(crumb(created.single.id), findsOneWidget, reason: 'opened');
      await releaseLibraryQueue(tester);
    });

    testWidgets('confirm returns the folder and the default tick', (
      tester,
    ) async {
      await seedFolders(tester);
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final results = <LibraryFolderPick?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => results.add(
                  await showLibraryFolderPicker(
                    context,
                    library: library,
                    initialFolderId: courses.id,
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
      expect(find.text('设为默认位置'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
      await tester.pumpAndSettle();
      expect(results.single?.folderId, courses.id);
      expect(results.single?.setAsDefault, isTrue);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-picker-set-default')));
      await tester.tap(find.byKey(const ValueKey('folder-picker-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
      await tester.pumpAndSettle();
      expect(results.last?.folderId, isNull, reason: 'library root');
      expect(results.last?.setAsDefault, isFalse);
    });

    testWidgets('the import picker offers the part range', (tester) async {
      await seedFolders(tester);
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      BilibiliImportPick? pick;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => pick = await showBilibiliImportPicker(
                  context,
                  library: library,
                  current: BilibiliImportTarget.folder(math.id),
                  partCount: 3,
                  currentPage: 2,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('导入到…'), findsOneWidget);
      expect(crumb(math.id), findsOneWidget, reason: 'opens at the default');
      expect(find.text('全部分P（3 个）'), findsOneWidget);
      await tester.tap(find.text('仅当前 P2'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
      await tester.pumpAndSettle();
      expect(pick?.folderId, math.id);
      expect(pick?.allParts, isFalse);
      expect(pick?.setAsDefault, isTrue);
    });
  });

  group('import buttons', () {
    // Widget tests run on a fake clock: library.json writes started there
    // would never finish and block later tests, so they are skipped here.
    setUp(() {
      library.writeLibrarySnapshotOverrideForTesting = () async {};
    });

    Widget host(Widget child, {BilibiliDownloadService? service}) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryService>.value(value: library),
          if (service != null)
            ChangeNotifierProvider<BilibiliDownloadService>.value(
              value: service,
            ),
        ],
        child: MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: Scaffold(body: Center(child: child)),
        ),
      );
    }

    testWidgets('main button and folder button', (tester) async {
      final calls = <(String, bool)>[];
      await tester.pumpWidget(
        host(
          BilibiliImportButtons(
            bvid: _bvid,
            history: history,
            onImport:
                (context, {required bvid, page, required pickPlace}) async {
                  calls.add((bvid, pickPlace));
                },
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('bilibili-import-$_bvid')));
      await tester.tap(
        find.byKey(const ValueKey('bilibili-import-pick-$_bvid')),
      );
      expect(calls, [(_bvid, false), (_bvid, true)]);
    });

    testWidgets('an imported part stays tappable and imports again', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final service = BilibiliDownloadService(apiService: _FakeApi());
        await quickImport(service);
        await service.shutdown();
      });
      final calls = <bool>[];
      await tester.pumpWidget(
        host(
          BilibiliImportButtons(
            bvid: _bvid,
            history: history,
            onImport:
                (context, {required bvid, page, required pickPlace}) async {
                  calls.add(pickPlace);
                },
          ),
        ),
      );
      expect(find.text('已导入'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bilibili-import-$_bvid')));
      await tester.tap(
        find.byKey(const ValueKey('bilibili-import-pick-$_bvid')),
      );
      expect(calls, [false, true]);
      expect(library.bilibiliStreamItems, hasLength(1));
    });

    testWidgets('one tap imports and shows where it went', (tester) async {
      addTearDown(() => AppToast.dismiss(immediate: true));
      // Started inside the widget test's clock, so it is shut down there
      // too (a tear-down would wait on that clock forever).
      final service = BilibiliDownloadService(apiService: _FakeApi());
      await tester.pumpWidget(
        host(
          BilibiliImportButtons(bvid: _bvid, history: history),
          service: service,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('bilibili-import-$_bvid')));
      for (var i = 0; i < 100; i++) {
        if (find.text('已导入').evaluate().isNotEmpty) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('已导入'), findsOneWidget);
      expect(library.bilibiliStreamItems, hasLength(1));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('bilibili-import-$_bvid')),
        findsOneWidget,
      );
      unawaited(AppToast.dismiss(immediate: true));
      var drained = false;
      unawaited(service.shutdown().whenComplete(() => drained = true));
      for (var i = 0; i < 200 && !drained; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(drained, isTrue);
      await releaseLibraryQueue(tester);
    });
  });
}

class _FakeApi extends BilibiliApiService {
  _FakeApi({this.pages = 1});

  final int pages;
  int infoRequests = 0;

  @override
  Future<void> init() async {}

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    infoRequests++;
    return BilibiliVideoInfo(
      title: '测试视频',
      desc: '',
      pic: '',
      bvid: bvid,
      aid: '123',
      ownerName: 'UP',
      ownerMid: '1',
      pubDate: 0,
      pages: <BilibiliPage>[
        for (var i = 1; i <= pages; i++)
          BilibiliPage(
            cid: 100 + i,
            page: i,
            part: '第 $i 部分',
            duration: 600,
            bvid: bvid,
            aid: '123',
          ),
      ],
    );
  }

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async => const BilibiliPlayerMetadata();

  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getApplicationCachePath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;

  @override
  Future<String?> getDownloadsPath() async => rootPath;
}
