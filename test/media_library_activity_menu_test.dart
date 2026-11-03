import 'package:video_player_app/services/media_playback_service.dart';
import 'package:flutter/gestures.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_library_list_tile.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/utils/open_with_other_apps.dart';
import 'package:video_player_app/widgets/media_library_activity_menu.dart';
import 'package:video_player_app/widgets/media_library_anchor_menu.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LibraryService library;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    library = LibraryService();
    library.resetLibraryForTesting();
    library.seedVideoForTesting(
      VideoItem(
        id: 'clip',
        path: '/tmp/clip.mp4',
        title: 'clip',
        durationMs: 1000,
        lastUpdated: 1,
        hasProbedChapters: true,
      ),
    );
  });

  tearDown(() {
    library.resetLibraryForTesting();
  });

  for (final list in [false, true]) {
    testWidgets(
      'right click opens the same overflow menu (list: $list)',
      (tester) async {
        var taps = 0;
        var selections = 0;
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<LibraryService>.value(value: library),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: MediaPlaybackService(),
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 300,
                    height: list ? 100 : 240,
                    child: list
                        ? MediaLibraryListTile.video(
                            item: library.getVideo('clip')!,
                            index: 0,
                            showIndex: false,
                            showThumbnail: false,
                            isSelected: false,
                            isSelectionMode: false,
                            titleScale: 1,
                            showActivityMenu: true,
                            allowHide: true,
                            onTap: () => taps++,
                            onSecondaryTap: () => selections++,
                          )
                        : MediaLibraryGridCard(
                            radius: 8,
                            isSelected: false,
                            onTap: () => taps++,
                            onSecondaryTap: () => selections++,
                            child: const Align(
                              alignment: Alignment.bottomRight,
                              child: SizedBox(
                                width: 40,
                                height: 40,
                                child: MediaLibraryActivityMenuButton(
                                  targetId: 'clip',
                                  isCollection: false,
                                  allowHide: true,
                                  fillSlot: true,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        );
        final gesture = await tester.startGesture(
          const Offset(30, 30),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(taps, 0);
        expect(selections, 0);
        expect(find.text('重命名'), findsOneWidget);
        expect(find.text('从本页移除'), findsOneWidget);
        final rightClickPosition = tester.getRect(find.text('重命名'));
        await tester.tapAt(const Offset(700, 500));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('media-library-activity-menu')),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('重命名')), rightClickPosition);
        expect(find.text('从本页移除'), findsOneWidget);
        await tester.tapAt(const Offset(700, 500));
        await tester.pumpAndSettle();
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }),
    );
  }

  testWidgets(
    'activity menu stays on screen and dismisses from a blank tap',
    (tester) async {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        library.getVideo('clip')!.path = r'C:\media\clip.mp4';
      }
      await tester.pumpWidget(
        ChangeNotifierProvider<LibraryService>.value(
          value: library,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomRight,
                child: MediaLibraryActivityMenuButton(
                  targetId: 'clip',
                  isCollection: false,
                  allowHide: true,
                  onLocate: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('media-library-activity-menu')),
      );
      await tester.pumpAndSettle();
      expect(find.text('置顶到「继续学习」'), findsOneWidget);
      expect(find.text('显示所在目录'), findsOneWidget);
      expect(find.text('导出'), findsOneWidget);
      expect(find.text('移入回收站'), findsOneWidget);
      expect(find.text('从本页移除'), findsOneWidget);
      expect(find.text('移动到上一级'), findsNothing);
      expect(find.text('打开源文件位置'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('source-media-file-menu')),
        findsOneWidget,
      );

      final menu = tester.getRect(find.text('置顶到「继续学习」'));
      final screen = tester.getRect(find.byType(MaterialApp));
      expect(menu.left >= screen.left, isTrue);
      expect(menu.right <= screen.right, isTrue);
      expect(menu.top >= screen.top, isTrue);
      expect(menu.bottom <= screen.bottom, isTrue);

      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(find.text('置顶到「继续学习」'), findsNothing);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('move to parent appears only when the folder page provides it', (
    tester,
  ) async {
    var moved = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: MediaLibraryActivityMenuButton(
                targetId: 'clip',
                isCollection: false,
                onMoveToParent: () => moved += 1,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('media-library-activity-menu')));
    await tester.pumpAndSettle();
    expect(find.text('移动到上一级'), findsOneWidget);
    expect(find.text('从本页移除'), findsNothing);

    await tester.tap(find.text('移动到上一级'));
    await tester.pumpAndSettle();
    expect(moved, 1);
    expect(find.text('移动到上一级'), findsNothing);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform shows share, gives immediate feedback, and prevents duplicate requests',
      (tester) async {
        final pending = Completer<bool>();
        var requests = 0;
        const updatedSource = '/private/中文 空格, #100% %20.mp4';
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(openWithOtherAppsChannel, (
          call,
        ) async {
          expect(call.method, 'shareFile');
          expect((call.arguments as Map)['path'], updatedSource);
          requests++;
          return pending.future;
        });
        addTearDown(() {
          if (!pending.isCompleted) pending.complete(true);
          messenger.setMockMethodCallHandler(openWithOtherAppsChannel, null);
          AppToast.dismiss(immediate: true);
        });
        await tester.pumpWidget(
          ChangeNotifierProvider<LibraryService>.value(
            value: library,
            child: MaterialApp(
              navigatorKey: AppToast.navigatorKey,
              home: const Scaffold(
                body: Center(
                  child: MediaLibraryActivityMenuButton(
                    targetId: 'clip',
                    isCollection: false,
                  ),
                ),
              ),
            ),
          ),
        );
        final button = find.byKey(
          const ValueKey('media-library-activity-menu'),
        );
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('分享源媒体文件'), findsOneWidget);
        expect(find.text('打开源文件位置'), findsNothing);
        expect(find.text('导出'), findsOneWidget);
        // A source can be relocated while the menu is open. Resolve the
        // current record on selection, without using the displayed title.
        library.getVideo('clip')!.path = updatedSource;
        await tester.tap(find.text('分享源媒体文件'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(requests, 1);
        expect(find.text('正在打开分享菜单…'), findsOneWidget);
        await tester.tap(button);
        await tester.pump();
        expect(requests, 1);
        expect(find.text('分享源媒体文件'), findsNothing);
        pending.complete(true);
        await tester.pumpAndSettle();
        expect(find.text('正在打开分享菜单…'), findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets('online media does not offer a source-file action', (
    tester,
  ) async {
    final clip = library.getVideo('clip')!;
    clip.path = 'https://example.com/online.mp4';
    clip.sourceRef = const MediaSourceRef(
      value: 'https://example.com/online.mp4',
      kind: MediaSourceKind.url,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: MediaLibraryActivityMenuButton(
                targetId: 'clip',
                isCollection: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('media-library-activity-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('source-media-file-menu')), findsNothing);
    expect(find.text('导出'), findsOneWidget);
    await tester.tapAt(const Offset(12, 12));
    await tester.pumpAndSettle();
  });

  testWidgets('recent dismiss removes a folder card and undo puts it back', (
    tester,
  ) async {
    addTearDown(() => AppToast.dismiss(immediate: true));
    library.seedCollectionForTesting(
      VideoCollection(id: 'folder', name: '导入', createTime: 1),
    );
    library.writeLibrarySnapshotOverrideForTesting = () async {};
    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryService>.value(
        value: library,
        child: MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: MediaLibraryActivityMenuButton(
                targetId: 'folder',
                isCollection: true,
                allowDismissFromRecent: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('media-library-activity-menu')));
    await tester.pumpAndSettle();
    expect(find.text('从本页移除'), findsOneWidget);
    expect(find.text('移入回收站'), findsOneWidget);

    expect(find.byKey(const ValueKey('source-media-file-menu')), findsNothing);

    await tester.tap(find.text('从本页移除'));
    // Saving is queued behind the widget-test zone, so let that future finish
    // before looking for the toast.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(library.recentDismissedIds, ['folder']);
    expect(find.text('已从本页移除'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    expect(library.recentDismissedIds, isEmpty);
  });

  test('menu glyph follows card width instead of a 24px floor', () {
    expect(
      MediaLibraryActivityMenuMetrics.glyphSize(103),
      closeTo(12.36, 0.05),
    );
    expect(MediaLibraryActivityMenuMetrics.layoutSize(103) < 24, isTrue);
    expect(MediaLibraryActivityMenuMetrics.hitSize(103), closeTo(37.08, 0.05));
    expect(MediaLibraryActivityMenuMetrics.glyphSize(280), 20);
    expect(MediaLibraryActivityMenuMetrics.hitSize(280), 40);
  });

  test('anchor menu stays compact on phone tablet and desktop', () {
    final phone = MediaLibraryAnchorMenuMetrics.of(const Size(390, 844));
    expect(phone.width, lessThan(230));
    expect(phone.width, greaterThan(160));
    expect(phone.rowHeight, 38);

    final tablet = MediaLibraryAnchorMenuMetrics.of(const Size(820, 1180));
    expect(tablet.width, inInclusiveRange(180, 240));
    expect(tablet.rowHeight, lessThan(44));

    final desktop = MediaLibraryAnchorMenuMetrics.of(const Size(1920, 1080));
    expect(desktop.width, lessThan(220));
    expect(desktop.rowHeight, 32);
    expect(desktop.fontSize, 13);
  });
}
