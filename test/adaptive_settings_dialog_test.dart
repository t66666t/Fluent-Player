import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/adaptive_settings_dialog.dart';

void main() {
  test('dialog stays inside every target screen class', () {
    const screens = <String, Size>{
      'small phone portrait': Size(320, 568),
      'small phone landscape': Size(568, 320),
      'large phone': Size(932, 430),
      'small tablet': Size(1024, 600),
      'large tablet': Size(1366, 1024),
      'desktop': Size(1920, 1080),
      'large desktop': Size(3840, 2160),
    };

    for (final entry in screens.entries) {
      final metrics = AdaptiveSettingsDialogMetrics.fromSize(entry.value);
      expect(
        metrics.dialogWidth + metrics.insetPadding.horizontal,
        lessThanOrEqualTo(entry.value.width),
        reason: entry.key,
      );
      expect(
        metrics.dialogMaxHeight + metrics.insetPadding.vertical,
        lessThanOrEqualTo(entry.value.height),
        reason: entry.key,
      );
      expect(
        metrics.contentMaxHeight,
        lessThan(metrics.dialogMaxHeight),
        reason: '${entry.key} must reserve fixed title and action space',
      );
    }
  });

  test('short screens use compact density and wide dialogs use columns', () {
    final phone = AdaptiveSettingsDialogMetrics.fromSize(const Size(568, 320));
    final desktop = AdaptiveSettingsDialogMetrics.fromSize(
      const Size(1920, 1080),
    );

    expect(phone.isCompact, isTrue);
    expect(phone.useTwoColumns, isFalse);
    expect(desktop.isCompact, isFalse);
    expect(desktop.useTwoColumns, isTrue);
    expect(phone.gap, lessThan(desktop.gap));
  });

  testWidgets('setting tile grid reflows without overflow', (tester) async {
    Future<void> pumpAt(double width) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: AdaptiveSettingsTileGrid(
                gap: 8,
                children: const [
                  SwitchListTile(
                    title: Text('下载完成后自动导入媒体库'),
                    value: true,
                    onChanged: null,
                  ),
                  SwitchListTile(
                    title: Text('导入媒体库后自动删除任务记录'),
                    subtitle: Text('不会删除已导入的视频文件'),
                    value: false,
                    onChanged: null,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }

    await pumpAt(300);
    final narrowFirst = tester.getTopLeft(find.byType(SwitchListTile).first);
    final narrowSecond = tester.getTopLeft(find.byType(SwitchListTile).last);
    expect(narrowSecond.dy, greaterThan(narrowFirst.dy));

    await pumpAt(700);
    final wideFirst = tester.getTopLeft(find.byType(SwitchListTile).first);
    final wideSecond = tester.getTopLeft(find.byType(SwitchListTile).last);
    expect(wideSecond.dx, greaterThan(wideFirst.dx));
    expect(wideSecond.dy, wideFirst.dy);
  });
}
