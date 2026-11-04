import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/danmaku_style.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/danmaku_settings_dialog.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('播放页自动选中对应配置，切换配置后四项调整互不影响', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDanmakuSettingsDialog(
                context,
                initialMode: DanmakuPresentationMode.portrait,
              ),
              child: const Text('设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    Slider slider(String label) => tester.widget<Slider>(
      find.descendant(
        of: find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .first,
        matching: find.byType(Slider),
      ),
    );
    expect(slider('显示区域').value, .25);
    expect(slider('弹幕密度').value, .5);
    expect(slider('弹幕字号').value, 1);
    slider('显示区域').onChanged!(.35);
    slider('弹幕密度').onChanged!(.25);
    slider('弹幕字号').onChanged!(1.2);
    slider('弹幕速度').onChanged!(danmakuSpeedToSlider(.6));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('danmaku-profile-landscape')));
    await tester.pumpAndSettle();
    expect(slider('显示区域').value, .5);
    expect(slider('弹幕密度').value, 1);
    expect(slider('弹幕字号').value, .8);
    expect(slider('弹幕速度').value, closeTo(danmakuSpeedToSlider(1), 1e-8));
    slider('弹幕字号').onChanged!(1.5);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('danmaku-profile-portrait')));
    await tester.pumpAndSettle();
    expect(slider('显示区域').value, .35);
    expect(slider('弹幕密度').value, .25);
    expect(slider('弹幕字号').value, 1.2);
    expect(slider('弹幕速度').value, closeTo(danmakuSpeedToSlider(.6), 1e-8));
    expect(settings.bilibiliDanmakuFontScale, 1.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('高级弹幕设置只在按钮点击后打开并可即时更新', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    await tester.binding.setSurfaceSize(const Size(390, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDanmakuSettingsDialog(context),
              child: const Text('设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('弹幕高级设置'), findsNothing);
    expect(find.text('适中 · 1.0×'), findsOneWidget);

    await tester.tap(find.text('高级设置'));
    await tester.pumpAndSettle();
    expect(find.text('弹幕高级设置'), findsOneWidget);
    expect(find.text('思源黑体'), findsOneWidget);
    expect(settings.bilibiliDanmakuFontWeight, 700);
    await tester.tap(find.text('样式'));
    await tester.pumpAndSettle();
    expect(find.text('标准描边'), findsOneWidget);

    await tester.ensureVisible(find.text('45°投影'));
    await tester.tap(find.text('45°投影'));
    await tester.pump();
    expect(settings.bilibiliDanmakuOutlineType, DanmakuOutlineType.projection);
    await tester.tap(find.text('微调'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('增大描边强度'));
    await tester.tap(find.byTooltip('增大阴影距离'));
    await tester.tap(find.byTooltip('增大字距'));
    await tester.pumpAndSettle();
    expect(settings.bilibiliDanmakuOutlineScale, closeTo(1.05, .001));
    expect(settings.bilibiliDanmakuShadowScale, closeTo(1.05, .001));
    expect(settings.bilibiliDanmakuLetterSpacing, closeTo(.01, .001));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'font names preview their own faces and weights follow actual font assets',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDanmakuSettingsDialog(context),
                child: const Text('设置'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      final dropdown = tester.widget<DropdownButton<String>>(
        find.byWidgetPredicate((widget) => widget is DropdownButton<String>),
      );
      for (final item in dropdown.items!) {
        final label = item.child as Text;
        expect(label.style!.fontFamily, item.value == '' ? null : item.value);
      }
      Future<void> select(String family) async {
        tester
            .widget<CapsuleDropdownButtonFormField<String>>(
              find.byWidgetPredicate(
                (widget) => widget is CapsuleDropdownButtonFormField<String>,
              ),
            )
            .onChanged!(family);
        await tester.pumpAndSettle();
      }

      List<int> weights() => tester
          .widget<DropdownButton<int>>(
            find.byWidgetPredicate((widget) => widget is DropdownButton<int>),
          )
          .items!
          .map((item) => item.value!)
          .toList();
      await select('Swei Gothic CJK SC');
      expect(settings.bilibiliDanmakuFontWeight, 700);
      expect(
        find.byKey(const ValueKey('danmaku-fixed-weight')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((widget) => widget is DropdownButton<int>),
        findsNothing,
      );
      await select('Noto Serif CJK SC');
      expect(weights(), [400, 700]);
      tester
          .widget<CapsuleDropdownButtonFormField<int>>(
            find.byWidgetPredicate(
              (widget) => widget is CapsuleDropdownButtonFormField<int>,
            ),
          )
          .onChanged!(400);
      await tester.pumpAndSettle();
      expect(settings.bilibiliDanmakuFontWeight, 400);
      await select('MiSans');
      expect(weights(), [100, 200, 300, 400, 500, 600, 700, 900]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('锁定倍速基准勾选项即时切换且不撑出小屏弹幕设置页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    await tester.binding.setSurfaceSize(const Size(360, 560));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDanmakuSettingsDialog(context),
              child: const Text('设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('以锁定倍速为弹幕速度基准'), findsOneWidget);
    expect(find.text('自动更新弹幕'), findsOneWidget);
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isFalse);
    expect(settings.bilibiliDanmakuAutoUpdate, isTrue);
    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('danmaku-auto-update-checkbox')),
          )
          .value,
      isTrue,
    );

    await tester.tap(find.text('自动更新弹幕'));
    await tester.pump();
    expect(settings.bilibiliDanmakuAutoUpdate, isFalse);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('自动更新弹幕'));
    await tester.pump();
    expect(settings.bilibiliDanmakuAutoUpdate, isTrue);

    await tester.tap(find.text('以锁定倍速为弹幕速度基准'));
    await tester.pump();
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('以锁定倍速为弹幕速度基准'));
    await tester.pump();
    expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, isFalse);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('danmaku-locked-speed-baseline-checkbox')),
      findsOneWidget,
    );
  });

  testWidgets('手机横屏弹幕设置一屏展示全部控件且无需滚动', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService();
    settings.resetForTest();
    await settings.init();
    // Logical landscape phone size; setSurfaceSize does not always update MediaQuery.
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsService>.value(
        value: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDanmakuSettingsDialog(context),
              child: const Text('设置'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    const screen = Size(800, 360);
    final labels = <String>[
      '弹幕仅在视频区域内展示',
      '显示区域',
      '不透明度',
      '弹幕字号',
      '弹幕速度',
      '以锁定倍速为弹幕速度基准',
      '自动更新弹幕',
      '更新弹幕',
      '立即更新',
    ];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
      final rect = tester.getRect(find.text(label));
      expect(
        rect.top >= -0.5 && rect.bottom <= screen.height + 0.5,
        isTrue,
        reason: '$label should stay fully on the landscape viewport',
      );
    }

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('danmaku-settings-scroll')),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
