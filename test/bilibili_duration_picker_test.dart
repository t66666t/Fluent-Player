import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/app_text_input_focus.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/widgets/bilibili_duration_picker.dart';
import 'package:video_player_app/widgets/bilibili_filter_picker.dart';

Future<void> _edit(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
  await tester.pump();
}

void main() {
  test('precise bounds are inclusive and do not lose server bucket edges', () {
    const range = BilibiliVideoDurationRange(
      minimumSeconds: 750,
      maximumSeconds: 2280,
    );
    expect(range.includes(749), isFalse);
    expect(range.includes(750), isTrue);
    expect(range.includes(2280), isTrue);
    expect(range.includes(2281), isFalse);
    expect(
      const BilibiliVideoDurationRange(maximumSeconds: 300).includes(0),
      isFalse,
    );
    expect(range.apiValue, 0);
    expect(const BilibiliVideoDurationRange(maximumSeconds: 599).apiValue, 1);
    expect(const BilibiliVideoDurationRange(maximumSeconds: 600).apiValue, 0);
    expect(
      const BilibiliVideoDurationRange(
        minimumSeconds: 601,
        maximumSeconds: 1799,
      ).apiValue,
      2,
    );
    expect(const BilibiliVideoDurationRange(minimumSeconds: 3600).apiValue, 0);
    expect(const BilibiliVideoDurationRange(minimumSeconds: 3601).apiValue, 4);
    expect(
      const BilibiliVideoDurationRange(minimumSeconds: 120).includes(100000),
      isTrue,
    );
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(500, 900),
    BilibiliVideoDurationRange selected = const BilibiliVideoDurationRange(),
    ValueChanged<BilibiliVideoDurationRange?>? onResult,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppTextInputFocus(child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showBilibiliDurationPicker(
                  context: context,
                  selected: selected,
                );
                onResult?.call(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'number adjustments keep focus, dialog title dismisses it',
    (tester) async {
      await open(tester);
      final field = find.byKey(const ValueKey('duration-minimum-minutes'));
      await tester.enterText(field, '2');
      await tester.pump();
      final focus = tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .focusNode;
      final increment = find.byKey(const ValueKey('duration-minimum-nudge-60'));
      final gesture = await tester.startGesture(tester.getCenter(increment));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '3');
      expect(focus.hasFocus, isTrue);
      tester.testTextInput.hide();
      await tester.tap(find.text('视频时长'));
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isFalse);
      expect(tester.widget<TextField>(field).controller!.text, '3');
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'arbitrary minutes and seconds expand beyond the slider viewport',
    (tester) async {
      BilibiliVideoDurationRange? result;
      await open(tester, onResult: (value) => result = value);
      await _edit(tester, 'duration-minimum-minutes', '150');
      await _edit(tester, 'duration-minimum-seconds', '7');
      await _edit(tester, 'duration-maximum-minutes', '240');
      await _edit(tester, 'duration-maximum-seconds', '19');
      expect(
        tester.widget<RangeSlider>(find.byType(RangeSlider)).max,
        greaterThanOrEqualTo(14419),
      );
      await tester.tap(find.byKey(const ValueKey('duration-apply')));
      await tester.pumpAndSettle();
      expect(
        result,
        const BilibiliVideoDurationRange(
          minimumSeconds: 9007,
          maximumSeconds: 14419,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reversed ranges and invalid seconds cannot be applied', (
    tester,
  ) async {
    await open(tester);
    await _edit(tester, 'duration-minimum-minutes', '38');
    await _edit(tester, 'duration-maximum-minutes', '12');
    expect(find.text('最长时长不能小于最短时长'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('duration-apply')))
          .onPressed,
      isNull,
    );
    await _edit(tester, 'duration-maximum-minutes', '45');
    await _edit(tester, 'duration-maximum-seconds', '60');
    expect(find.text('请输入有效分钟数，秒数为 0～59'), findsOneWidget);
    await _edit(tester, 'duration-maximum-seconds', '59');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('duration-apply')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'moving one slider thumb preserves seconds on the other endpoint',
    (tester) async {
      BilibiliVideoDurationRange? result;
      await open(
        tester,
        selected: const BilibiliVideoDurationRange(
          minimumSeconds: 750,
          maximumSeconds: 2299,
        ),
        onResult: (value) => result = value,
      );
      final sliderFinder = find.byType(RangeSlider);
      final slider = tester.widget<RangeSlider>(sliderFinder);
      final rect = tester.getRect(sliderFinder);
      final upper = Offset(
        rect.left + 24 + (rect.width - 48) * (2299 / slider.max),
        rect.center.dy,
      );
      await tester.dragFrom(upper, const Offset(-40, 0));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('duration-apply')));
      await tester.pumpAndSettle();
      expect(result!.minimumSeconds, 750);
      expect(result!.maximumSeconds, lessThan(2299));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('minute slider rounding keeps a narrow range valid', (
    tester,
  ) async {
    await open(
      tester,
      selected: const BilibiliVideoDurationRange(
        minimumSeconds: 100,
        maximumSeconds: 110,
      ),
    );
    final slider = tester.widget<RangeSlider>(find.byType(RangeSlider));
    slider.onChanged!(const RangeValues(100, 101));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final nudger = find.byKey(const ValueKey('duration-minimum-nudge-1'));
    await tester.ensureVisible(nudger);
    await tester.tap(nudger);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('presets are drafts and cancel preserves the active range', (
    tester,
  ) async {
    BilibiliVideoDurationRange? result;
    await open(
      tester,
      selected: const BilibiliVideoDurationRange(
        minimumSeconds: 123,
        maximumSeconds: 456,
      ),
      onResult: (value) => result = value,
    );
    await tester.tap(find.text('10～30 分钟'));
    await tester.pump();
    expect(find.text('10 分钟 ～ 30 分钟'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('narrow screens and keyboard retain reachable apply controls', (
    tester,
  ) async {
    BilibiliVideoDurationRange? result;
    await open(
      tester,
      size: const Size(320, 640),
      onResult: (value) => result = value,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    await _edit(tester, 'duration-minimum-minutes', '12');
    await _edit(tester, 'duration-minimum-seconds', '30');
    final unlimited = find.widgetWithText(TextButton, '不限');
    await tester.ensureVisible(unlimited);
    await tester.tap(unlimited);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('duration-apply')));
    await tester.pumpAndSettle();
    expect(result, const BilibiliVideoDurationRange(minimumSeconds: 750));
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchored option menus select and dismiss at a narrow edge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: BilibiliFilterButton(
              label: '最新发布',
              tooltip: '排序',
              onPressed: (anchor) async {
                result = await showBilibiliFilterPicker(
                  context: anchor,
                  anchorContext: anchor,
                  title: '排序',
                  selected: '最新发布',
                  values: ['综合排序', '最新发布', '最多播放'],
                  labelOf: (value) => value,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最多播放'));
    await tester.pumpAndSettle();
    expect(result, '最多播放');
    expect(tester.takeException(), isNull);
  });
}
