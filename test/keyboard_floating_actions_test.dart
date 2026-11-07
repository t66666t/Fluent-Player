import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/media_library_keyboard_navigation.dart';
import 'package:video_player_app/widgets/video_action_buttons.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('floating actions are skipped by arrows but reachable by Tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsService()..resetForTest();
    await settings.init();
    settings.isActionButtonsCollapsed = true;
    addTearDown(settings.resetForTest);
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          home: MediaLibrarySpatialNavigation(
            child: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: 20,
                    top: 100,
                    child: TextButton(
                      autofocus: true,
                      onPressed: () {},
                      child: const Text('left content'),
                    ),
                  ),
                  Positioned(
                    left: 330,
                    top: 100,
                    child: TextButton(
                      onPressed: () {},
                      child: const Text('right content'),
                    ),
                  ),
                  const Positioned(
                    left: 185,
                    top: 95,
                    width: 110,
                    height: 300,
                    child: VideoActionButtons(maxExpandedHeight: 300),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final right = Focus.of(tester.element(find.text('right content')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(right.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    final left = Focus.of(tester.element(find.text('left content')));
    expect(left.hasPrimaryFocus, isTrue);

    var reachedToggle = false;
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext?.findAncestorWidgetOfExactType<VideoActionButtons>() !=
          null) {
        reachedToggle = true;
        break;
      }
    }
    expect(reachedToggle, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(settings.isActionButtonsCollapsed, isFalse);
    left.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(right.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(left.hasPrimaryFocus, isTrue);
    // No underlying control is below the left button; default traversal must
    // not fall back to the floating layer at the page boundary either.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(left.hasPrimaryFocus, isTrue);
  });
}
