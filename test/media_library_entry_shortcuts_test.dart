import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/batch_import_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/media_library_entry_shortcuts.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';

void main() {
  test('digits, numpad and cycling respect order and modifiers', () {
    int? match(
      LogicalKeyboardKey key, {
      bool control = false,
      bool shift = false,
      bool alt = false,
      bool meta = false,
      int current = 5,
    }) => mediaLibraryEntryShortcutIndex(
      key,
      currentIndex: current,
      count: 6,
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
    );
    expect(match(LogicalKeyboardKey.digit1), 0);
    expect(match(LogicalKeyboardKey.digit6), 5);
    expect(match(LogicalKeyboardKey.numpad3), 2);
    expect(match(LogicalKeyboardKey.digit7), isNull);
    expect(match(LogicalKeyboardKey.digit2, shift: true), isNull);
    expect(match(LogicalKeyboardKey.digit2, control: true), isNull);
    expect(match(LogicalKeyboardKey.digit2, alt: true), isNull);
    expect(match(LogicalKeyboardKey.digit2, meta: true), isNull);
    expect(match(LogicalKeyboardKey.tab), isNull);
    expect(match(LogicalKeyboardKey.tab, control: true), 0);
    expect(
      match(LogicalKeyboardKey.tab, control: true, shift: true, current: 0),
      5,
    );
  });

  testWidgets(
    'real root pages switch, cycle, and respect modal and selection scopes',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'onboarding.handled.v1': true});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final library = LibraryService()..resetLibraryForTesting();
      library.writeLibrarySnapshotOverrideForTesting = () async {};
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
            home: const MediaLibraryShell(home: HomeScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      MediaLibraryEntrySwitcher switcher() =>
          tester.widget<MediaLibraryEntrySwitcher>(
            find.byType(MediaLibraryEntrySwitcher),
          );
      Future<void> key(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      for (final digit in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.numpad2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.numpad4,
      ]) {
        final index = mediaLibraryEntryShortcutIndex(
          digit,
          currentIndex: 0,
          count: switcher().entries.length,
        )!;
        await key(digit);
        expect(switcher().selected, switcher().entries[index]);
      }
      final selected = switcher().selected;
      await key(LogicalKeyboardKey.digit6);
      expect(switcher().selected, selected);
      expect(switcher().entries.every((entry) => entry.isAvailable), isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await key(LogicalKeyboardKey.tab);
      expect(switcher().selected, switcher().entries.first);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await key(LogicalKeyboardKey.tab);
      expect(switcher().selected, switcher().entries.last);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      final before = switcher().selected;
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      );
      await tester.pumpAndSettle();
      await key(LogicalKeyboardKey.digit1);
      expect(switcher().selected, before);
      FocusManager.instance.primaryFocus?.unfocus();
      await key(LogicalKeyboardKey.digit2);
      expect(switcher().selected, before);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await key(LogicalKeyboardKey.digit2);
      expect(switcher().selected, switcher().entries[1]);
      await key(LogicalKeyboardKey.keyB);
      await key(LogicalKeyboardKey.digit1);
      await key(LogicalKeyboardKey.escape);
      expect(switcher().selected, MediaLibraryRootEntry.folders);
      // Reordering changes both the numeric destination and hover hint.
      switcher().onReorder!(0, 2);
      await tester.pumpAndSettle();
      await key(LogicalKeyboardKey.digit1);
      expect(switcher().selected, switcher().entries.first);
      expect(
        find.byTooltip(
          mediaLibraryEntryShortcutTooltip(switcher().entries.first.label, 0),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await playback.stop();
      library.resetLibraryForTesting();
      settings.resetForTest();
    },
  );
}
