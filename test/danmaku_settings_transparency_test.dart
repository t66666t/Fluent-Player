import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/danmaku_settings_dialog.dart';

final _background = find.byKey(const ValueKey('danmaku-dialog-background'));
final _surface = find.byKey(const ValueKey('danmaku-dialog-surface'));

double _backgroundAlpha(WidgetTester tester) =>
    (tester.widget<DecoratedBox>(_background).decoration as BoxDecoration)
        .color!
        .a;

Finder _slider(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.byType(Slider),
);

double _controlOpacity(WidgetTester tester, Finder control) => tester
    .widget<Opacity>(
      find.ancestor(of: control, matching: find.byType(Opacity)).first,
    )
    .opacity;

Future<SettingsService> _open(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  VoidCallback? onBackgroundTap,
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsService()..resetForTest();
  await settings.init();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        // Even a theme with an elevated, tinted dialog must stay transparent.
        theme: ThemeData.light().copyWith(
          dialogTheme: const DialogThemeData(
            elevation: 24,
            surfaceTintColor: Colors.purple,
            shadowColor: Colors.black,
          ),
        ),
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onBackgroundTap,
            child: SizedBox.expand(
              child: Stack(
                children: [
                  Consumer<SettingsService>(
                    builder: (_, value, _) => Text(
                      'live font: ${value.bilibiliDanmakuFontScale}',
                      key: const ValueKey('live-danmaku-settings'),
                    ),
                  ),
                  Center(
                    child: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showDanmakuSettingsDialog(context),
                        child: const Text('打开设置'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开设置'));
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(568, 320),
    const Size(390, 844),
    const Size(844, 390),
    const Size(834, 1194),
    const Size(1194, 834),
    const Size(1280, 800),
    const Size(900, 1440),
  ]) {
    for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
      testWidgets(
        'live transparent drag and release: $kind $size',
        (tester) async {
          var backgroundTaps = 0;
          final settings = await _open(
            tester,
            size: size,
            onBackgroundTap: () => backgroundTaps++,
          );
          final idleAlpha = _backgroundAlpha(tester);
          expect(idleAlpha, allOf(greaterThan(0), lessThan(1)));
          for (final barrier in tester.widgetList<ModalBarrier>(
            find.byType(ModalBarrier),
          )) {
            expect(barrier.color?.a ?? 0, 0);
          }
          final material = tester.widget<Material>(
            find
                .ancestor(of: _background, matching: find.byType(Material))
                .first,
          );
          expect(material.color, Colors.transparent);
          expect(material.elevation, 0);
          expect(material.surfaceTintColor, Colors.transparent);
          final slider = _slider('弹幕字号');
          final sliderRect = tester.getRect(slider);
          final panelRect = tester.getRect(_surface);
          final originalScale = settings.bilibiliDanmakuFontScale;
          final gesture = await tester.startGesture(
            sliderRect.center,
            kind: kind,
          );
          await tester.pump();
          expect(_backgroundAlpha(tester), 0);
          expect(_controlOpacity(tester, slider), 1);
          for (final label in ['显示区域', '弹幕密度', '不透明度', '弹幕速度']) {
            expect(_controlOpacity(tester, _slider(label)), .25);
          }
          expect(_controlOpacity(tester, find.text('弹幕设置')), .25);
          expect(_controlOpacity(tester, find.text('立即更新')), .25);
          await gesture.moveTo(
            Offset(sliderRect.right - 12, sliderRect.center.dy),
          );
          await tester.pump();
          expect(settings.bilibiliDanmakuFontScale, isNot(originalScale));
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('live-danmaku-settings')),
                )
                .data,
            'live font: ${settings.bilibiliDanmakuFontScale}',
          );
          final sliderTheme = SliderTheme.of(tester.element(slider));
          expect(sliderTheme.activeTrackColor!.a, 1);
          expect(sliderTheme.inactiveTrackColor!.a, 1);
          expect(sliderTheme.thumbColor!.a, 1);
          expect(tester.getRect(slider), sliderRect);
          expect(tester.getRect(_surface), panelRect);
          // Releasing outside the panel must still restore its background.
          await gesture.moveTo(const Offset(1, 1));
          await gesture.up();
          await tester.pumpAndSettle();
          expect(_backgroundAlpha(tester), idleAlpha);
          for (final label in ['显示区域', '弹幕密度', '不透明度', '弹幕字号', '弹幕速度']) {
            expect(_controlOpacity(tester, _slider(label)), 1);
          }
          expect(backgroundTaps, 0);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(
          kind == PointerDeviceKind.mouse
              ? TargetPlatform.windows
              : TargetPlatform.android,
        ),
      );
    }
  }

  testWidgets(
    'multi-touch and cancellation restore only after the last pointer',
    (tester) async {
      await _open(tester);
      final idleAlpha = _backgroundAlpha(tester);
      final first = await tester.startGesture(
        tester.getCenter(_slider('弹幕字号')),
        pointer: 1,
      );
      final second = await tester.startGesture(
        tester.getCenter(_slider('不透明度')),
        pointer: 2,
      );
      await tester.pump();
      expect(_backgroundAlpha(tester), 0);
      expect(_controlOpacity(tester, _slider('弹幕字号')), 1);
      expect(_controlOpacity(tester, _slider('不透明度')), 1);
      expect(_controlOpacity(tester, _slider('弹幕速度')), .25);
      await first.up();
      await tester.pump();
      expect(_backgroundAlpha(tester), 0);
      expect(_controlOpacity(tester, _slider('弹幕字号')), .25);
      expect(_controlOpacity(tester, _slider('不透明度')), 1);
      await second.cancel();
      await tester.pumpAndSettle();
      expect(_backgroundAlpha(tester), idleAlpha);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'focus loss, closing during drag and reopening leave no stale state',
    (tester) async {
      await _open(tester);
      final idleAlpha = _backgroundAlpha(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_slider('弹幕字号')),
      );
      await tester.pump();
      expect(_backgroundAlpha(tester), 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(_backgroundAlpha(tester), idleAlpha);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await gesture.cancel();
      await tester.pumpAndSettle();

      final closingGesture = await tester.startGesture(
        tester.getCenter(_slider('弹幕速度')),
      );
      await tester.pump();
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
      await closingGesture.cancel();
      await tester.tap(find.text('打开设置'));
      await tester.pumpAndSettle();
      expect(_backgroundAlpha(tester), idleAlpha);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'advanced preview clears both backdrops and restores the base panel',
    (tester) async {
      final settings = await _open(tester);
      await settings.saveBilibiliDanmakuOutlineType(
        DanmakuOutlineType.projection,
      );
      final idleAlpha = _backgroundAlpha(tester);
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      expect(find.text('弹幕设置'), findsNothing);
      expect(_background, findsOneWidget);
      expect(_backgroundAlpha(tester), idleAlpha);
      await tester.tap(find.text('微调'));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(_slider('阴影距离')),
      );
      await tester.pump();
      expect(_backgroundAlpha(tester), 0);
      expect(_controlOpacity(tester, _slider('阴影距离')), 1);
      expect(_controlOpacity(tester, _slider('描边强度')), .25);
      expect(_controlOpacity(tester, find.text('弹幕高级设置')), .25);
      final preview = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('弹幕预览  Danmaku').first,
              matching: find.byType(Container),
            )
            .first,
      );
      expect((preview.decoration! as BoxDecoration).gradient, isNull);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(_backgroundAlpha(tester), idleAlpha);
      final before = settings.bilibiliDanmakuShadowScale;
      final buttonGesture = await tester.startGesture(
        tester.getCenter(find.byTooltip('增大阴影距离')),
      );
      await tester.pump();
      expect(_backgroundAlpha(tester), 0);
      await buttonGesture.up();
      await tester.pumpAndSettle();
      expect(settings.bilibiliDanmakuShadowScale, greaterThan(before));
      expect(_backgroundAlpha(tester), idleAlpha);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('弹幕设置'), findsOneWidget);
      expect(_backgroundAlpha(tester), idleAlpha);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rotation during a drag keeps the controls usable and cancellation restores',
    (tester) async {
      await _open(tester, size: const Size(390, 844));
      final idleAlpha = _backgroundAlpha(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_slider('弹幕字号')),
      );
      await tester.pump();
      tester.view.physicalSize = const Size(844, 390);
      await tester.pumpAndSettle();
      expect(_backgroundAlpha(tester), 0);
      expect(tester.getRect(_surface).bottom, lessThanOrEqualTo(390));
      expect(_slider('弹幕字号').hitTestable(), findsOneWidget);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(_backgroundAlpha(tester), idleAlpha);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removing an advanced control mid-drag still releases its preview pointer',
    (tester) async {
      await _open(tester);
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('微调'));
      await tester.pumpAndSettle();
      final idleAlpha = _backgroundAlpha(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(_slider('描边强度')),
        pointer: 1,
      );
      await tester.pump();
      expect(_backgroundAlpha(tester), 0);
      await tester.tap(find.text('字体'));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(_backgroundAlpha(tester), idleAlpha);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'transparent panel intercepts taps and outside tap dismisses once',
    (tester) async {
      var backgroundTaps = 0;
      await _open(tester, onBackgroundTap: () => backgroundTaps++);
      final gesture = await tester.startGesture(
        tester.getCenter(_slider('弹幕字号')),
        pointer: 1,
      );
      await tester.pump();
      expect(_backgroundAlpha(tester), 0);
      await tester.tapAt(tester.getTopLeft(_surface) + const Offset(2, 2));
      expect(backgroundTaps, 0);
      expect(_background, findsOneWidget);
      await gesture.up();
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(_background, findsNothing);
      expect(backgroundTaps, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
