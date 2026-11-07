import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/clipboard_detection_routes.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';
import 'package:video_player_app/widgets/media_library_settings_controls.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';
import 'package:video_player_app/widgets/clipboard_detection_scope.dart';

void main() {
  final preview = Platform.environment['SETTINGS_PREVIEW'] == '1';
  late SettingsService settings;
  late LibraryService library;
  late ProgressSyncService sync;
  late ClipboardDetectionRoutes clipboardRoutes;

  setUpAll(() async {
    if (preview) {
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await (FontLoader(
            'Noto Sans SC',
          )..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf')))
          .load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'mediaLibraryRestoreLastPage': false,
      'mediaLibraryStartupEntry': 'folders',
    });
    settings = SettingsService()..resetForTest();
    await settings.init();
    library = LibraryService()..resetLibraryForTesting();
    clipboardRoutes = ClipboardDetectionRoutes();
    sync = ProgressSyncService(
      library: library,
      store: MemoryProgressSyncStore(),
      enableNetwork: false,
    );
  });

  tearDown(() {
    sync.dispose();
    clipboardRoutes.dispose();
    library.resetLibraryForTesting();
    settings.resetForTest();
  });

  Future<void> open(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('settings-preview'),
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<ProgressSyncService>.value(value: sync),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appInteractionTheme(
              ThemeData(
                brightness: Brightness.dark,
                colorScheme: const ColorScheme.dark(primary: Color(0xFF4B8EF0)),
                fontFamily: preview ? 'Noto Sans SC' : null,
              ),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: ClipboardDetectionScope(
                routes: clipboardRoutes,
                completeStartup: () async {},
                inspectClipboard: () {},
                child: child!,
              ),
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showMediaLibrarySettingsBottomSheet(
                    context,
                    settings,
                    showSystemMediaNotificationSetting: false,
                  ),
                  child: const Text('打开设置'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开设置'));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!preview) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('settings-preview')),
      );
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('artifacts/media_library_settings_redesign/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final (size, columns, name) in [
    (const Size(320, 568), 1, 'small-phone'),
    (const Size(390, 844), 1, 'phone'),
    (const Size(600, 960), 1, 'small-tablet'),
    (const Size(768, 1024), 1, 'tablet'),
    (const Size(1024, 768), 2, 'tablet-landscape'),
    (const Size(1440, 900), 2, 'desktop'),
    (const Size(1920, 1080), 2, 'wide-desktop'),
  ]) {
    testWidgets(
      'priority destinations and every setting remain usable at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await open(tester);
        final destinationKeys = [
          'modelCenterSettings',
          'storageManagement',
          'globalNetworkSettings',
          'progressSyncSettings',
        ];
        final positions = [
          for (final key in destinationKeys)
            tester.getTopLeft(find.byKey(ValueKey(key))),
        ];
        for (var i = 1; i < positions.length; i++) {
          if (i % columns == 0) {
            expect(positions[i].dy, greaterThan(positions[i - 1].dy));
          } else {
            expect(positions[i].dy, positions[i - 1].dy);
            expect(positions[i].dx, greaterThan(positions[i - 1].dx));
          }
        }
        final normalHeight = tester
            .getSize(find.byKey(const ValueKey('showMiniPlaybackCard')))
            .height;
        for (final key in destinationKeys) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            normalHeight,
          );
        }
        expect(find.text('隐藏卡片不影响播放'), findsOneWidget);
        expect(find.byTooltip('显示迷你播放卡片说明'), findsNothing);
        expect(find.byType(TextField), findsNothing);
        for (final duplicate in ['键盘快捷键', '连接外部 AI', '卡片与列表样式']) {
          expect(find.text(duplicate), findsNothing);
        }
        await capture(tester, name);
        for (final key in [
          'copyImportedMediaToPrivateStorage',
          'processing-protection-wait',
          'privacy-notice',
        ]) {
          final control = find.byKey(ValueKey(key));
          await tester.ensureVisible(control);
          await tester.pumpAndSettle();
          expect(control.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final size in [const Size(320, 568), const Size(1440, 900)]) {
    testWidgets(
      'short explanations are visible and only detailed help opens at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await open(tester);
        expect(find.text('隐藏卡片不影响播放'), findsOneWidget);
        expect(find.text('代理与连接方式'), findsOneWidget);
        expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
        final protectionBefore = settings.processingScreenProtection;
        final info = find.byKey(const ValueKey('processing-protection-info'));
        await tester.ensureVisible(info);
        await tester.tap(info);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('防烧屏有什么用？'), findsOneWidget);
        expect(settings.processingScreenProtection, protectionBefore);
        await capture(tester, size.width < 600 ? 'phone-info' : 'desktop-info');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(settings.processingScreenProtection, protectionBefore);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('startup dropdown and its selection survive window resizing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    expect(settings.mediaLibraryRestoreLastPage, isFalse);
    expect(settings.mediaLibraryStartupEntry, 'folders');
    final restore = find.byKey(const ValueKey('mediaLibraryRestoreLastPage'));
    final beforeHeight = tester.getSize(restore).height;
    final miniBefore = tester.getTopLeft(
      find.byKey(const ValueKey('showMiniPlaybackCard')),
    );
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(tester.getSize(restore).height, beforeHeight);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('showMiniPlaybackCard'))),
      miniBefore,
    );
    expect(settings.mediaLibraryRestoreLastPage, isTrue);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(tester.getSize(restore).height, beforeHeight);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('showMiniPlaybackCard'))),
      miniBefore,
    );
    final startup = find.byKey(const ValueKey('mediaLibraryStartupEntry'));
    await tester.tap(startup);
    await tester.pumpAndSettle();
    final recent = find.byKey(
      const ValueKey('mediaLibraryStartupEntry-recent'),
    );
    await tester.tap(recent.last);
    await tester.pumpAndSettle();
    for (final size in [
      const Size(390, 844),
      const Size(768, 1024),
      const Size(1440, 1000),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      await tester.ensureVisible(startup);
      expect(
        tester
            .widget<MediaLibrarySettingsDropdown<MediaLibraryRootEntry>>(
              startup,
            )
            .value,
        MediaLibraryRootEntry.recent,
      );
      expect(settings.mediaLibraryRestoreLastPage, isFalse);
      expect(settings.mediaLibraryStartupEntry, 'recent');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    '200 percent text remains reachable on a narrow landscape window',
    (tester) async {
      tester.view.physicalSize = const Size(568, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester, scale: 2);
      for (final key in [
        'modelCenterSettings',
        'progressSyncSettings',
        'showMiniPlaybackCard',
        'privacy-notice',
      ]) {
        final control = find.byKey(ValueKey(key));
        await tester.ensureVisible(control);
        await tester.pumpAndSettle();
        expect(control.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'switch supports row taps, native keyboard activation and disabled semantics',
    (tester) async {
      var value = false;
      var disabled = false;
      late StateSetter update;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MediaLibrarySettingsSwitchTile(
                  title: const Text('开关测试'),
                  value: value,
                  onChanged: disabled
                      ? null
                      : (next) => setState(() => value = next),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('开关测试'));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(value, isFalse);
      final target = tester.getSize(find.byType(MediaLibrarySettingsSwitch));
      expect(target.width, greaterThanOrEqualTo(48));
      expect(target.height, greaterThanOrEqualTo(48));
      update(() => disabled = true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('开关测试'));
      expect(value, isFalse);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );
}
