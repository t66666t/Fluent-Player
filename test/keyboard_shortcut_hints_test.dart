import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/desktop_media_management_shortcuts.dart';
import 'package:video_player_app/utils/desktop_player_shortcuts.dart';
import 'package:video_player_app/utils/keyboard_shortcut_hints.dart';
import 'package:video_player_app/utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/media_library_settings_sheet.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/player_top_bar.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

const _channel = MethodChannel(HardwareKeyboardPresence.channelName);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  var connected = false;
  var queries = 0;

  Future<void> nativeChange(Object? value) async {
    if (value is bool) connected = value;
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('keyboardChanged', value),
      ),
      (_) {},
    );
  }

  HardwareKeyboardPresence presence(TargetPlatform platform) {
    final result = HardwareKeyboardPresence(platform: platform);
    addTearDown(result.dispose);
    return result;
  }

  setUp(() {
    connected = false;
    queries = 0;
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
      call,
    ) async {
      expect(call.method, 'isKeyboardConnected');
      queries++;
      return connected;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform handles attachment, detachment and resume', (
      tester,
    ) async {
      final keyboard = presence(platform)..start();
      await tester.pump();
      expect(keyboard.showHints, isFalse);
      await nativeChange(true);
      expect(keyboard.showHints, isTrue);
      // Duplicate and malformed events do not trigger redundant rebuilds.
      var notifications = 0;
      keyboard.addListener(() => notifications++);
      await nativeChange(true);
      await nativeChange('mouse');
      expect(notifications, 0);
      await nativeChange(false);
      expect(keyboard.showHints, isFalse);
      connected = true; // A connection while the app was suspended.
      keyboard.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(keyboard.showHints, isTrue);
      expect(queries, 2);
    });

    testWidgets('$platform detects a keyboard already attached at launch', (
      tester,
    ) async {
      connected = true;
      final keyboard = presence(platform)..start();
      await tester.pump();
      expect(keyboard.showHints, isTrue);
    });
  }

  testWidgets(
    'desktop hints need no device queries; unsupported platforms stay quiet',
    (tester) async {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        final keyboard = presence(platform)..start();
        await tester.pump();
        expect(keyboard.showHints, platform != TargetPlatform.fuchsia);
      }
      expect(queries, 0);
    },
  );

  testWidgets('a native change wins over a stale startup or resume snapshot', (
    tester,
  ) async {
    final pending = <Completer<bool>>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (_) {
      final request = Completer<bool>();
      pending.add(request);
      return request.future;
    });
    final keyboard = presence(TargetPlatform.android)..start();
    await tester.pump();
    await nativeChange(true);
    pending[0].complete(false);
    await tester.pump();
    expect(keyboard.showHints, isTrue);
    final refresh = keyboard.refresh();
    await tester.pump();
    await nativeChange(false);
    pending[1].complete(true);
    await refresh;
    expect(keyboard.showHints, isFalse);
  });

  testWidgets(
    'missing or failing native queries keep the last confirmed state',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      final keyboard = presence(TargetPlatform.iOS)..start();
      await tester.pump();
      expect(keyboard.showHints, isFalse);
      await nativeChange(true);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (
        _,
      ) async {
        throw PlatformException(code: 'temporarily_unavailable');
      });
      await keyboard.refresh();
      expect(keyboard.showHints, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an outstanding query can finish safely after disposal', (
    tester,
  ) async {
    final pending = Completer<bool>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (_) => pending.future,
    );
    final keyboard = HardwareKeyboardPresence(platform: TargetPlatform.android)
      ..start();
    await tester.pump();
    keyboard.dispose();
    pending.complete(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile long-press labels update without replacing the tooltip or draft',
    (tester) async {
      final keyboard = presence(TargetPlatform.android);
      final draft = TextEditingController(text: '未完成的输入');
      addTearDown(draft.dispose);
      await tester.pumpWidget(
        _host(
          keyboard,
          Builder(
            builder: (context) => Column(
              children: [
                TextField(controller: draft),
                IconButton(
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () {},
                  tooltip: DesktopPlayerShortcuts.buildTooltip(
                    '播放/暂停',
                    DesktopPlayerShortcutAction.playPause,
                    context: context,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {},
                  tooltip: hoverAwareShortcutTooltip(
                    '搜索',
                    LogicalKeyboardKey.keyS,
                    context: context,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {},
                  tooltip: DesktopMediaManagementShortcuts.buildTooltip(
                    '回收站',
                    DesktopMediaManagementShortcutAction.openRecycleBin,
                    context: context,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tooltip = tester.state(find.byTooltip('播放/暂停'));
      await tester.longPress(find.byIcon(Icons.play_arrow));
      await tester.pump();
      expect(find.text('播放/暂停'), findsOneWidget);
      await nativeChange(true);
      await tester.pump();
      expect(find.byTooltip('播放/暂停 (Space)'), findsOneWidget);
      expect(tester.state(find.byTooltip('播放/暂停 (Space)')), same(tooltip));
      expect(find.text('播放/暂停 (Space)'), findsOneWidget);
      expect(find.byTooltip('搜索 (S)'), findsOneWidget);
      expect(find.byTooltip('回收站 (R)'), findsOneWidget);
      await nativeChange(false);
      await tester.pump();
      expect(find.byTooltip('播放/暂停'), findsOneWidget);
      expect(find.byTooltip('搜索'), findsOneWidget);
      expect(find.byTooltip('回收站'), findsOneWidget);
      expect(draft.text, '未完成的输入');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mouse hover, soft-key events and IME insets do not enable hints',
    (tester) async {
      final keyboard = presence(TargetPlatform.android);
      await tester.pumpWidget(
        _host(
          keyboard,
          Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {},
              tooltip: hoverAwareShortcutTooltip(
                '搜索',
                LogicalKeyboardKey.keyS,
                context: context,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.search)));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump();
      expect(keyboard.showHints, isFalse);
      expect(find.byTooltip('搜索'), findsOneWidget);
      expect(queries, 1);
      tester.view.resetViewInsets();
      await mouse.removePointer();
    },
  );

  testWidgets(
    'an open popup updates hints and help entries on repeated hot-plug',
    (tester) async {
      final keyboard = presence(TargetPlatform.android);
      String? selected;
      await tester.pumpWidget(
        _host(
          keyboard,
          CapsulePopupMenuButton<String>(
            tooltip: '操作菜单',
            onSelected: (value) => selected = value,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'search',
                child: Text(
                  hoverAwareShortcutTooltip(
                    '搜索',
                    LogicalKeyboardKey.keyS,
                    context: context,
                  ),
                ),
              ),
              if (KeyboardShortcutHints.of(context))
                const PopupMenuItem(value: 'help', child: Text('快捷键帮助')),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('操作菜单'));
      await tester.pumpAndSettle();
      expect(find.text('搜索'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await nativeChange(true);
        await tester.pumpAndSettle();
        expect(find.text('搜索 (S)'), findsOneWidget);
        expect(find.text('快捷键帮助'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // Focus help.
        await nativeChange(false); // Remove the focused option.
        await tester.pumpAndSettle();
        expect(find.text('快捷键帮助'), findsNothing);
        expect(find.text('搜索'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await nativeChange(true);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 'search');
    },
  );

  testWidgets('the player overflow menu updates labels while it stays open', (
    tester,
  ) async {
    final keyboard = presence(TargetPlatform.android);
    var selections = 0;
    await tester.pumpWidget(
      _host(
        keyboard,
        SizedBox(
          width: 180,
          child: PlayerTopBar(
            leading: const [],
            leadingWidth: 0,
            title: const Text('视频'),
            gap: 8,
            mirrored: false,
            buttonExtent: 48,
            iconSize: 20,
            buttonPadding: EdgeInsets.zero,
            actions: [
              PlayerTopBarAction(
                action: PlayerTopAction.settings,
                button: const Icon(Icons.settings),
                width: 96,
                icon: Icons.settings,
                label: '设置',
                menuLabelBuilder: (context) =>
                    DesktopPlayerShortcuts.buildTooltip(
                      '设置',
                      DesktopPlayerShortcutAction.openSettings,
                      context: context,
                    ),
                onSelected: () => selections++,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('video-controls-top-more')));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    await nativeChange(true);
    await tester.pumpAndSettle();
    expect(find.text('设置 (S)'), findsOneWidget);
    await nativeChange(false);
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(selections, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an already open import sheet follows the device state', (
    tester,
  ) async {
    // The local-only import sheet has fewer entries; keep this fixture small
    // enough to exercise scroll retention when keyboard hints change.
    await tester.binding.setSurfaceSize(const Size(390, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final keyboard = presence(TargetPlatform.android);
    await tester.pumpWidget(
      _host(
        keyboard,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => VideoActionButtons.showImportMenu(context, null),
            child: const Text('打开导入'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开导入'));
    await tester.pumpAndSettle();
    expect(find.text('从文件管理导入'), findsOneWidget);
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).last,
    );
    final position = scrollable.position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pump();
    final offset = position.pixels;
    await nativeChange(true);
    await tester.pumpAndSettle();
    expect(position.pixels, offset);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable).last).position,
      same(position),
    );
    position.jumpTo(0);
    await tester.pump();
    expect(find.text('从文件管理导入 (F)'), findsOneWidget);
    position.jumpTo(offset);
    await tester.pump();
    await nativeChange(false);
    await tester.pumpAndSettle();
    expect(position.pixels, offset);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable).last).position,
      same(position),
    );
    position.jumpTo(0);
    await tester.pump();
    expect(find.text('从文件管理导入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a popup closes safely when its last available entry disappears',
    (tester) async {
      connected = true;
      final keyboard = presence(TargetPlatform.android);
      var cancellations = 0;
      await tester.pumpWidget(
        _host(
          keyboard,
          CapsulePopupMenuButton<String>(
            tooltip: '键盘帮助菜单',
            onCanceled: () => cancellations++,
            itemBuilder: (context) => [
              if (KeyboardShortcutHints.of(context))
                const PopupMenuItem(value: 'help', child: Text('快捷键帮助')),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('键盘帮助菜单'));
      await tester.pumpAndSettle();
      expect(find.text('快捷键帮助'), findsOneWidget);
      await nativeChange(false);
      await tester.pumpAndSettle();
      expect(find.text('快捷键帮助'), findsNothing);
      expect(cancellations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [390.0, 1100.0]) {
    testWidgets('home help follows keyboard availability at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final keyboard = presence(TargetPlatform.android);
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
      final playback = MediaPlaybackService();
      await playback.stop();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: playback),
            ChangeNotifierProvider.value(value: BatchImportService()),
          ],
          child: MaterialApp(
            builder: (context, navigator) =>
                KeyboardShortcutHints(presence: keyboard, child: navigator!),
            home: const MediaLibraryShell(
              home: HomeScreen(returnToSearchResults: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 600) {
        await tester.tap(find.byTooltip('更多').first);
        await tester.pumpAndSettle();
        expect(find.text('快捷键 (F1)'), findsNothing);
        await nativeChange(true);
        await tester.pumpAndSettle();
        expect(find.text('快捷键 (F1)'), findsOneWidget);
        await tester.tap(find.text('快捷键 (F1)'));
        await tester.pumpAndSettle();
        expect(find.text('键盘快捷键'), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await nativeChange(false);
        await tester.tap(find.byTooltip('更多').first);
        await tester.pumpAndSettle();
        expect(find.text('快捷键 (F1)'), findsNothing);
      } else {
        expect(find.byTooltip('快捷键 (F1)'), findsNothing);
        await nativeChange(true);
        await tester.pumpAndSettle();
        expect(find.byTooltip('快捷键 (F1)'), findsOneWidget);
        await nativeChange(false);
        await tester.pumpAndSettle();
        expect(find.byTooltip('快捷键 (F1)'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await playback.stop();
      library.resetLibraryForTesting();
      settings.resetForTest();
    });
  }

  testWidgets(
    'settings omit duplicate keyboard help when a keyboard connects',
    (tester) async {
      final keyboard = presence(TargetPlatform.android);
      final settings = SettingsService()..resetForTest();
      await settings.init();
      addTearDown(settings.resetForTest);
      await tester.pumpWidget(
        _host(
          keyboard,
          Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              child: const Text('打开设置'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(
        find.byKey(const ValueKey('keyboardShortcutSettings')),
        findsNothing,
      );
      await nativeChange(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('keyboardShortcutSettings')),
        findsNothing,
      );
      expect(find.text('媒体库设置'), findsOneWidget);
      await nativeChange(false);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('keyboardShortcutSettings')),
        findsNothing,
      );
      expect(find.text('媒体库设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _host(HardwareKeyboardPresence presence, Widget child) => MaterialApp(
  builder: (context, navigator) =>
      KeyboardShortcutHints(presence: presence, child: navigator!),
  home: Scaffold(body: child),
);
