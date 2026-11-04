import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/playback_speed_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('临时切换倍速后保留原全局锁定勾选框', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    double selectedSpeed = 1.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => showPlaybackSpeedDialog(
                  context: context,
                  anchorContext: context,
                  initialSpeed: selectedSpeed,
                  settings: settings,
                  onSpeedSelected: (speed) async => selectedSpeed = speed,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackSpeedDialog), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);
    final buttonRect = tester.getRect(find.text('打开'));
    final popoverRect = tester.getRect(
      find.byKey(const ValueKey('playback-speed-popover')),
    );
    expect(popoverRect.width, lessThanOrEqualTo(218));
    expect(popoverRect.height, lessThanOrEqualTo(330));
    expect(popoverRect.bottom, lessThanOrEqualTo(buttonRect.top));

    await tester.tap(find.text('2.0x').first);
    await tester.pumpAndSettle();

    expect(find.byType(PlaybackSpeedDialog), findsOneWidget);
    expect(selectedSpeed, 2.0);
    expect(_checkboxForSpeed(tester, 2.0).value, isFalse);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(settings.playbackSpeed, 2.0);
    expect(settings.isPlaybackSpeedLocked, isTrue);
    expect(_checkboxForSpeed(tester, 2.0).value, isTrue);

    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();

    expect(find.byType(PlaybackSpeedDialog), findsOneWidget);
    expect(selectedSpeed, 1.5);
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(_checkboxForSpeed(tester, 2.0).value, isTrue);
    expect(_checkboxForSpeed(tester, 1.5).value, isFalse);
    expect(settings.playbackSpeed, 2.0);
    expect(settings.isPlaybackSpeedLocked, isTrue);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('playback-speed-item-1.5')),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();

    expect(settings.playbackSpeed, 1.5);
    expect(settings.isPlaybackSpeedLocked, isTrue);
    expect(find.byType(Checkbox), findsOneWidget);
    expect(_checkboxForSpeed(tester, 1.5).value, isTrue);
  });

  testWidgets('小屏幕与浮层打开时退出不会溢出或遗留异常', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(240, 320);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlaybackSpeedDialog(
                context: context,
                anchorContext: context,
                initialSpeed: 1.0,
                settings: settings,
                onSpeedSelected: (_) async {},
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final popoverRect = tester.getRect(
      find.byKey(const ValueKey('playback-speed-popover')),
    );
    expect(popoverRect.left, greaterThanOrEqualTo(0));
    expect(popoverRect.right, lessThanOrEqualTo(240));
    expect(popoverRect.top, greaterThanOrEqualTo(0));
    expect(popoverRect.bottom, lessThanOrEqualTo(320));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('1.0x 倍速文案与 1.25x 占用相同宽度', (tester) async {
    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.bold);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              PlaybackSpeedText(
                key: ValueKey('speed-label-1.0'),
                speed: 1.0,
                style: style,
              ),
              PlaybackSpeedText(
                key: ValueKey('speed-label-1.25'),
                speed: 1.25,
                style: style,
              ),
              PlaybackSpeedText(
                key: ValueKey('speed-label-2.0'),
                speed: 2.0,
                style: style,
              ),
            ],
          ),
        ),
      ),
    );

    final width10 = tester
        .getSize(find.byKey(const ValueKey('speed-label-1.0')))
        .width;
    final width125 = tester
        .getSize(find.byKey(const ValueKey('speed-label-1.25')))
        .width;
    final width20 = tester
        .getSize(find.byKey(const ValueKey('speed-label-2.0')))
        .width;

    expect(find.text('1.0x'), findsOneWidget);
    expect(find.text('1.25x'), findsWidgets);
    expect(width10, closeTo(width125, 0.001));
    expect(width20, closeTo(width125, 0.001));
  });
}

Checkbox _checkboxForSpeed(WidgetTester tester, double speed) {
  final checkbox = find.descendant(
    of: find.byKey(ValueKey('playback-speed-item-$speed')),
    matching: find.byType(Checkbox),
  );
  expect(checkbox, findsOneWidget);
  return tester.widget<Checkbox>(checkbox);
}
