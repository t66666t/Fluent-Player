import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/screens/collection_screen.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/android_hardware_input_bridge.dart';
import 'package:video_player_app/utils/desktop_media_management_shortcuts.dart';
import 'package:video_player_app/utils/hardware_keyboard_shortcuts.dart';
import 'package:video_player_app/utils/page_shortcut_keys.dart';
import 'package:video_player_app/widgets/keyboard_shortcut_help.dart';
import 'package:video_player_app/widgets/media_library_page_shortcuts.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

void main() {
  test(
    'new management keys are unique and available on five native platforms',
    () {
      final keys = DesktopMediaManagementShortcuts.defaults;
      expect(keys.length, DesktopMediaManagementShortcutAction.values.length);
      expect(keys.values.toSet().length, keys.length);
      for (final (key, action) in [
        (
          LogicalKeyboardKey.keyH,
          DesktopMediaManagementShortcutAction.toggleActionButtons,
        ),
        (
          LogicalKeyboardKey.keyJ,
          DesktopMediaManagementShortcutAction.openDouyinDownload,
        ),
        (
          LogicalKeyboardKey.keyW,
          DesktopMediaManagementShortcutAction.openWebMedia,
        ),
      ]) {
        expect(DesktopMediaManagementShortcuts.matchAction(key), action);
        for (final platform in TargetPlatform.values) {
          expect(
            DesktopMediaManagementShortcuts.isAvailableOnPlatform(
              action,
              platform,
            ),
            supportsHardwareKeyboardShortcutsOn(platform),
          );
        }
      }
    },
  );

  test('Android fallback decodes parsing, help, search and speed keys', () {
    for (final (code, key) in [
      (66, LogicalKeyboardKey.enter),
      (160, LogicalKeyboardKey.numpadEnter),
      (71, LogicalKeyboardKey.bracketLeft),
      (72, LogicalKeyboardKey.bracketRight),
      (76, LogicalKeyboardKey.slash),
      (131, LogicalKeyboardKey.f1),
      (141, LogicalKeyboardKey.f11),
    ]) {
      expect(
        AndroidHardwareInputBridge.decodeKeyForTesting({
          'keyCode': code,
          'action': 0,
        })?.logicalKey,
        key,
      );
    }
  });

  testWidgets('composing Escape stays in the input and preserves the draft', (
    tester,
  ) async {
    final input = TextEditingController();
    addTearDown(input.dispose);
    var commands = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaLibraryPageShortcuts(
          bindings: {LogicalKeyboardKey.keyH: () => commands++},
          child: Scaffold(body: TextField(controller: input)),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    input.value = const TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    expect(isEditableTextComposing(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    expect(isEditableTextFocused(), isTrue);
    expect(input.text, 'ni');
    expect(commands, 0);
    input.clearComposing();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    expect(commands, 1);
  });

  testWidgets(
    'a floating scope requires focus and never takes keys from a sibling',
    (tester) async {
      final browser = FocusNode();
      final queue = FocusNode();
      addTearDown(browser.dispose);
      addTearDown(queue.dispose);
      var commands = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: browser,
                  autofocus: true,
                  child: const Text('browser'),
                ),
                MediaLibraryPageShortcuts(
                  captureUnfocusedKeys: false,
                  bindings: {LogicalKeyboardKey.space: () => commands++},
                  child: Focus(focusNode: queue, child: const Text('queue')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(commands, 0);
      queue.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      expect(commands, 1);
      browser.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(commands, 1);
    },
  );

  for (final home in [true, false]) {
    testWidgets(
      '${home ? 'home' : 'collection'} H toggles once and dialog input shields it',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final library = LibraryService()..resetLibraryForTesting();
        library.writeLibrarySnapshotOverrideForTesting = () async {};
        library.seedCollectionForTesting(
          VideoCollection(id: 'folder', name: 'folder', createTime: 1),
        );
        final playback = MediaPlaybackService();
        await playback.stop();
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: settings),
              ChangeNotifierProvider.value(value: library),
              ChangeNotifierProvider.value(value: playback),
              ChangeNotifierProvider.value(value: BatchImportService()),
            ],
            child: MaterialApp(
              navigatorKey: navigator,
              home: MediaLibraryShell(
                home: home
                    ? const HomeScreen(returnToSearchResults: true)
                    : const CollectionScreen(collectionId: 'folder'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final collapsed = settings.isActionButtonsCollapsed;
        await tester.sendKeyDownEvent(LogicalKeyboardKey.keyH);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyH);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.keyH);
        await tester.pumpAndSettle();
        expect(settings.isActionButtonsCollapsed, !collapsed);
        unawaited(
          showDialog<void>(
            context: navigator.currentContext!,
            builder: (_) =>
                const AlertDialog(content: TextField(autofocus: true)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.pump();
        expect(settings.isActionButtonsCollapsed, !collapsed);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await playback.stop();
        library.resetLibraryForTesting();
        settings.resetForTest();
      },
    );
  }

  testWidgets('help stays closed during input and fits a small window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: TextField(autofocus: true)),
      ),
    );
    await tester.pump();
    invokeKeyboardShortcutHelp(nav.currentContext);
    await tester.pump();
    expect(find.text('键盘快捷键'), findsNothing);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    invokeKeyboardShortcutHelp(nav.currentContext);
    await tester.pumpAndSettle();
    expect(find.text('键盘快捷键'), findsOneWidget);
    expect(find.textContaining('展开 / 收起操作按钮'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });
}
