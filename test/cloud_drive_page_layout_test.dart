import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_view_options.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_screen.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';
import 'support/cloud_drive_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in ['MiSans', 'Noto Sans SC']) {
      final loader = FontLoader(font)
        ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'));
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  for (final size in [
    const Size(360, 640),
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'cloud viewport and selection clear mini player and system bar at $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final playback = MediaPlaybackService();
        await playback.stop();
        final provider = FixtureCloudProvider('baidu', {
          '/': [
            cloudEntry(
              '/course',
              name: '我的课程',
              kind: CloudDriveEntryKind.folder,
            ),
            for (var i = 1; i <= 40; i++)
              cloudEntry(
                '$i',
                name: '第$i集 · 专注学习与练习.mp4',
                size: i * 1024 * 1024,
              ),
          ],
          '/course': [cloudEntry('inside', name: '课程里的视频.mp4')],
        }, pageSize: 100);
        final quark = FixtureCloudProvider('quark', {
          '0': [
            cloudEntry(
              'q',
              name: '夸克中的音频.mp3',
              provider: 'quark',
              kind: CloudDriveEntryKind.audio,
            ),
          ],
        }, pageSize: 100);
        final runtime = await cloudRuntime([provider, quark]);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.padding = const FakeViewPadding(bottom: 32);
        tester.view.viewPadding = const FakeViewPadding(bottom: 32);
        tester.view.systemGestureInsets = const FakeViewPadding(bottom: 24);
        final boundary = GlobalKey();
        addTearDown(() async {
          tester.view.reset();
          await playback.stop();
          await runtime.shutdown();
          runtime.launch.library.resetLibraryForTesting();
          settings.resetForTest();
        });
        playback.publishRestoredSessionPreview(
          VideoItem(
            id: 'preview',
            path: 'preview.mp4',
            title: '正在学习 · 播放进度',
            durationMs: 120000,
            lastUpdated: 0,
          ),
          const Duration(seconds: 25),
        );
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: playback,
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(
                brightness: Brightness.dark,
                useMaterial3: true,
                fontFamily: 'MiSans',
                scaffoldBackgroundColor: AppTokens.bgBase,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: MediaLibraryShell(
                  home: Scaffold(
                    appBar: AppBar(
                      title: MediaLibraryEntrySwitcher(
                        selected: MediaLibraryRootEntry.cloudDrive,
                        availableEntries: MediaLibraryRootEntry.values.toSet(),
                        onSelected: (_) {},
                      ),
                    ),
                    body: CloudDriveScreen(embedded: true, runtime: runtime),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final grid = find.bySubtype<GridView>();
        expect(grid, findsOneWidget);
        expect(provider.calls, hasLength(1));
        expect(quark.calls, isEmpty);
        final playerTop = tester.getTopLeft(find.byType(MiniPlaybackCard)).dy;
        expect(tester.getBottomRight(grid).dy, lessThanOrEqualTo(playerTop));
        final scrollable = find.descendant(
          of: grid,
          matching: find.byType(Scrollable),
        );
        final scroll = tester.state<ScrollableState>(scrollable);
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
        final last = find.byKey(
          ValueKey('cloud-drive-entry-${cloudDriveEntryKey(cloudEntry('40'))}'),
        );
        expect(tester.getBottomRight(last).dy, lessThanOrEqualTo(playerTop));
        scroll.position.jumpTo(0);
        await tester.pumpAndSettle();
        if (size.width == 1280 || size.width == 390) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage()
                    .timeout(const Duration(seconds: 10));
            final data = await image
                .toByteData(format: ui.ImageByteFormat.png)
                .timeout(const Duration(seconds: 10));
            final file = File(
              '.artifacts/cloud-drive-redesign/${size.width.toInt()}x${size.height.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.text('已选 41 项'), findsOneWidget);
        final importButton = find.byKey(
          const ValueKey('cloud-selection-add-to-library'),
        );
        expect(find.text('加入媒体库'), findsOneWidget);
        expect(importButton.hitTestable(), findsOneWidget);
        expect(
          tester.getBottomRight(importButton).dy,
          lessThanOrEqualTo(size.height - 32),
        );
        expect(
          tester.getBottomRight(grid).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byType(MiniPlaybackCard)).dy,
          ),
        );
        await tester.longPress(
          find.byKey(const ValueKey('cloud-selection-more')),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text('更多操作'), findsOneWidget);
        final pageOverlay = Navigator.of(
          tester.element(importButton),
        ).overlay!.context.findRenderObject();
        RenderObject? hint = tester.renderObject(find.text('更多操作'));
        while (hint != null) {
          expect(hint, isNot(same(pageOverlay)));
          hint = hint.parent;
        }
        await tester.tap(find.byKey(const ValueKey('cloud-selection-more')));
        await tester.pumpAndSettle();
        expect(find.text('选择入库位置…'), findsOneWidget);
        Navigator.of(tester.element(importButton), rootNavigator: true).pop();
        await tester.pumpAndSettle();
        expect(find.text('更多操作'), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        unawaited(settings.updateSetting('showMiniPlaybackCard', false));
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(grid).dy, size.height - 32);
        tester.view.padding = FakeViewPadding.zero;
        tester.view.viewPadding = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(grid).dy, size.height - 32);
        await tester.tap(find.byKey(const ValueKey('cloud-drive-tab-quark')));
        await tester.pumpAndSettle();
        expect(find.text('夸克中的音频.mp3'), findsOneWidget);
        expect(quark.calls, hasLength(1));
        await tester.tap(find.byKey(const ValueKey('cloud-drive-tab-baidu')));
        await tester.pumpAndSettle();
        expect(provider.calls, hasLength(1));
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        await tester.enterText(find.byType(TextField), '第12集');
        await tester.pump();
        expect(find.text('第12集 · 专注学习与练习.mp4'), findsOneWidget);
        expect(find.text('第13集 · 专注学习与练习.mp4'), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
        await tester.pump();
        expect(find.textContaining('已选'), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.pumpAndSettle();
        expect(settings.mediaLibraryViewMode, 1);
        if (size.width == 390) {
          final appContext = tester.element(find.byType(CloudDriveScreen));
          final navigator = Navigator.of(appContext);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
          await tester.pumpAndSettle();
          expect(find.text('排序方式'), findsOneWidget);
          navigator.pop();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
          await tester.pump();
          tester.view.viewInsets = const FakeViewPadding(bottom: 320);
          await tester.pumpAndSettle();
          expect(
            tester.getBottomRight(find.bySubtype<GridView>()).dy,
            lessThanOrEqualTo(size.height - 320),
          );
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          tester.platformDispatcher.textScaleFactorTestValue = 1.6;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final account in runtime.accounts.accounts) {
            await runtime.accounts.signOut(account.localId);
          }
          unawaited(settings.updateSetting('showMiniPlaybackCard', true));
          await tester.pumpAndSettle();
          final login = find.widgetWithText(FilledButton, '登录百度网盘');
          expect(login.hitTestable(), findsOneWidget);
          expect(
            tester.getBottomRight(login).dy,
            lessThanOrEqualTo(
              tester.getTopLeft(find.byType(MiniPlaybackCard)).dy,
            ),
          );
        }

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
