import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/clipboard_detection_control.dart';

void main() {
  late SettingsService settings;
  late GlobalKey<NavigatorState> navigator;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService()..resetForTest();
    await settings.init();
    navigator = GlobalKey<NavigatorState>();
  });

  Future<void> app(
    WidgetTester tester, {
    VoidCallback? presented,
    ValueChanged<String?>? result,
    bool automatic = true,
    double scale = 1,
    double keyboard = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final value = await showClipboardDetectionDialog<String>(
                  context: context,
                  settings: settings,
                  automatic: automatic,
                  onPresented: presented,
                  builder: (_) => AlertDialog(
                    key: const ValueKey('clipboard-test-prompt'),
                    scrollable: true,
                    title: const Text('B 站链接'),
                    content: ClipboardDetectionCheckbox(settings: settings),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            Navigator.pop(navigator.currentContext!, 'import'),
                        child: const Text('导入'),
                      ),
                    ],
                  ),
                );
                result?.call(value);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'disabled state cannot push a dialog or mark content as presented',
    (tester) async {
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      var presentations = 0;
      await app(tester, presented: () => presentations++);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(presentations, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(navigator.currentState!.canPop(), isFalse);
    },
  );

  testWidgets(
    'disabled before first paint does not consume clipboard history',
    (tester) async {
      var presentations = 0;
      await app(tester, presented: () => presentations++);
      await tester.tap(find.text('open'));
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      await tester.pumpAndSettle();
      expect(presentations, 0);
      expect(find.byType(AlertDialog), findsNothing);
      await settings.updateSetting('clipboardLinkDetectionEnabled', true);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(presentations, 1);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'unchecked opt-out confirms the setting location and retains the Bilibili prompt',
    (tester) async {
      String? result;
      await app(tester, result: (value) => result = value);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final checkbox = find.byKey(
        const ValueKey('clipboard-detection-checkbox'),
      );
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      expect(find.text(clipboardDetectionDisableLabel), findsOneWidget);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(settings.clipboardLinkDetectionEnabled, isTrue);
      expect(
        find.textContaining(clipboardDetectionSettingsLocation),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('clipboard-test-prompt')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('clipboard-detection-disable-confirm')),
      );
      await tester.pumpAndSettle();
      expect(settings.clipboardLinkDetectionEnabled, isFalse);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      expect(
        find.byKey(const ValueKey('clipboard-detection-disable-confirmation')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('clipboard-test-prompt')),
        findsOneWidget,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('clipboardLinkDetectionEnabled'), isFalse);
      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      expect(result, 'import');
      expect(find.byType(AlertDialog), findsNothing);
      expect(navigator.currentState!.canPop(), isFalse);
    },
  );

  testWidgets(
    'cancel, barrier and back restore the unchecked opt-out without saving',
    (tester) async {
      await app(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getBool('clipboardLinkDetectionEnabled');
      final checkbox = find.byKey(
        const ValueKey('clipboard-detection-checkbox'),
      );
      for (final dismiss in ['cancel', 'barrier', 'back']) {
        await tester.tap(checkbox);
        await tester.pumpAndSettle();
        if (dismiss == 'cancel') {
          await tester.tap(
            find.byKey(const ValueKey('clipboard-detection-disable-cancel')),
          );
        } else if (dismiss == 'barrier') {
          await tester.tapAt(const Offset(1, 1));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(settings.clipboardLinkDetectionEnabled, isTrue);
        expect(prefs.getBool('clipboardLinkDetectionEnabled'), previous);
        expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
        expect(
          find.byKey(const ValueKey('clipboard-test-prompt')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey('clipboard-detection-disable-confirmation'),
          ),
          findsNothing,
        );
      }
      // A cancelled confirmation must not exempt the prompt from later external changes.
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'unchecking re-enables immediately and restores external dismissal',
    (tester) async {
      await app(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final checkbox = find.byKey(
        const ValueKey('clipboard-detection-checkbox'),
      );
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('clipboard-detection-disable-confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(checkbox);
      expect(settings.clipboardLinkDetectionEnabled, isTrue);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      expect(
        find.byKey(const ValueKey('clipboard-detection-disable-confirmation')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('clipboard-test-prompt')),
        findsOneWidget,
      );
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('rapid opt-out activations only open one confirmation', (
    tester,
  ) async {
    await app(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final checkbox = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('clipboard-detection-checkbox')),
    );
    checkbox.onChanged!(true);
    checkbox.onChanged!(true);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('clipboard-detection-disable-confirmation')),
      findsOneWidget,
    );
    expect(settings.clipboardLinkDetectionEnabled, isTrue);
    await tester.tap(
      find.byKey(const ValueKey('clipboard-detection-disable-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('clipboard-detection-disable-confirmation')),
      findsNothing,
    );
  });

  testWidgets(
    'external disable removes the owned confirmation under another page',
    (tester) async {
      await app(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('clipboard-detection-checkbox')),
      );
      await tester.pumpAndSettle();
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('settings cover')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      await tester.pumpAndSettle();
      expect(find.text('settings cover'), findsOneWidget);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing the app with confirmation open removes all listeners',
    (tester) async {
      // ignore: invalid_use_of_protected_member
      final hadListeners = settings.hasListeners;
      await app(tester);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('clipboard-detection-checkbox')),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      // ignore: invalid_use_of_protected_member
      expect(settings.hasListeners, hadListeners);
      expect(settings.clipboardLinkDetectionEnabled, isTrue);
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit drop opt-out stays inverse and confirms future clipboard policy',
    (tester) async {
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      await app(tester, automatic: false);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final checkbox = find.byKey(
        const ValueKey('clipboard-detection-checkbox'),
      );
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      await tester.tap(checkbox);
      expect(settings.clipboardLinkDetectionEnabled, isTrue);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('clipboard-detection-disable-confirmation')),
        findsNothing,
      );
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('clipboard-detection-disable-confirm')),
      );
      await tester.pumpAndSettle();
      expect(settings.clipboardLinkDetectionEnabled, isFalse);
      expect(
        find.byKey(const ValueKey('clipboard-test-prompt')),
        findsOneWidget,
      );
    },
  );

  for (final layout in const [
    (Size(320, 568), 2.0, 0.0),
    (Size(640, 320), 1.8, 0.0),
    (Size(390, 640), 1.5, 300.0),
    (Size(1440, 900), 1.0, 0.0),
  ]) {
    testWidgets(
      'disable confirmation fits ${layout.$1} at scale ${layout.$2}',
      (tester) async {
        tester.view.physicalSize = layout.$1;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await app(tester, scale: layout.$2, keyboard: layout.$3);
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('clipboard-detection-checkbox')),
        );
        await tester.tap(
          find.byKey(const ValueKey('clipboard-detection-checkbox')),
        );
        await tester.pumpAndSettle();
        final confirm = find.byKey(
          const ValueKey('clipboard-detection-disable-confirm'),
        );
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        expect(confirm.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(confirm).bottom,
          lessThanOrEqualTo(layout.$1.height - layout.$3),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(settings.clipboardLinkDetectionEnabled, isFalse);
        expect(
          find.byKey(const ValueKey('clipboard-test-prompt')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'disabling underneath another page removes only the clipboard route',
    (tester) async {
      String? result = 'pending';
      await app(tester, result: (value) => result = value);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('settings cover')),
        ),
      );
      await tester.pumpAndSettle();
      await settings.updateSetting('clipboardLinkDetectionEnabled', false);
      await tester.pumpAndSettle();
      expect(find.text('settings cover'), findsOneWidget);
      expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
      expect(result, isNull);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
    },
  );

  testWidgets('rapid off/on cannot let queued dismissal pop a newer route', (
    tester,
  ) async {
    await app(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final off = settings.updateSetting('clipboardLinkDetectionEnabled', false);
    final on = settings.updateSetting('clipboardLinkDetectionEnabled', true);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('new page')),
      ),
    );
    await tester.pumpAndSettle();
    await Future.wait([off, on]);
    expect(settings.clipboardLinkDetectionEnabled, isTrue);
    expect(find.text('new page'), findsOneWidget);
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
  });

  testWidgets('disposing an open navigator removes its settings listeners', (
    tester,
  ) async {
    // Test listener cleanup without adding a production inspection API.
    // ignore: invalid_use_of_protected_member
    final hadListeners = settings.hasListeners;
    await app(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    // ignore: invalid_use_of_protected_member
    expect(settings.hasListeners, hadListeners);
    await settings.updateSetting('clipboardLinkDetectionEnabled', false);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
