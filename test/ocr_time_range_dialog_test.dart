import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/ocr_time_range_dialog.dart';

Future<void> _showEditor(
  WidgetTester tester, {
  Duration duration = const Duration(minutes: 37, seconds: 46),
  RangeValues values = const RangeValues(0, 2266000),
  ValueChanged<RangeValues?>? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final result = await showDialog<RangeValues>(
                context: context,
                builder: (_) =>
                    OcrTimeRangeDialog(duration: duration, values: values),
              );
              onResult?.call(result);
            },
            child: const Text('编辑'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
}

void main() {
  final start = find.byKey(const ValueKey('ocr-range-start'));
  final end = find.byKey(const ValueKey('ocr-range-end'));

  testWidgets(
    'invalid, reversed, empty and out-of-bounds times stay in the editor',
    (tester) async {
      await _showEditor(tester);
      for (final (from, to, error) in [
        ('', '00:30', '请输入有效时间'),
        ('-1', '00:30', '请输入有效时间'),
        ('00:00', '00:60', '请输入有效时间'),
        ('00:00', '37:47', '不能超过视频时长'),
        ('38:00', '37:46', '不能超过视频时长'),
        ('00:30', '00:30', '结束时间需晚于开始时间'),
        ('01:00', '00:30', '结束时间需晚于开始时间'),
        ('99999999999999999999:00', '00:30', '请输入有效时间'),
      ]) {
        await tester.enterText(start, from);
        await tester.enterText(end, to);
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(find.text(error), findsWidgets);
        expect(find.byType(OcrTimeRangeDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.enterText(start, '0');
      await tester.enterText(end, '30');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(OcrTimeRangeDialog), findsNothing);
    },
  );

  testWidgets('hour times and millisecond boundaries round trip exactly', (
    tester,
  ) async {
    const duration = Duration(
      hours: 2,
      minutes: 3,
      seconds: 4,
      milliseconds: 567,
    );
    RangeValues? result;
    await _showEditor(
      tester,
      duration: duration,
      values: RangeValues(0, duration.inMilliseconds.toDouble()),
      onResult: (value) => result = value,
    );
    expect(find.text('2:03:04.567'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, RangeValues(0, duration.inMilliseconds.toDouble()));
  });

  testWidgets('a small landscape screen keeps the editor and actions usable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(568, 320);
    addTearDown(tester.view.reset);
    await _showEditor(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 120);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('确定')).bottom, lessThanOrEqualTo(200));
    await tester.ensureVisible(end);
    await tester.enterText(end, '00:30');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(OcrTimeRangeDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
