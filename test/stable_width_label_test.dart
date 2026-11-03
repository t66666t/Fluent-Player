import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/stable_width_label.dart';

const _variants = ['导入', '正在导入…', '已导入', '导入失败，重试'];

/// 一个带状态文案的按钮，右边紧挨一个邻居文字，用来量位置。
Widget _host({
  required String text,
  required bool busy,
  double scale = 1.0,
  double width = 800,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 600),
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Row(
              children: [
                Flexible(
                  child: OutlinedButton.icon(
                    key: const ValueKey('btn'),
                    onPressed: () {},
                    icon: StableIconSlot(
                      icon: Icons.library_add_outlined,
                      size: 17,
                      busy: busy,
                    ),
                    label: StableWidthLabel(text, variants: _variants),
                  ),
                ),
                const Text('邻居', key: ValueKey('neighbor')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('各状态宽度完全相同、邻居不挪位（字体缩放 $scale）', (tester) async {
      Size? size;
      Offset? neighbor;
      for (final (i, text) in _variants.indexed) {
        await tester.pumpWidget(_host(text: text, busy: i == 1, scale: scale));
        final s = tester.getSize(find.byKey(const ValueKey('btn')));
        final n = tester.getTopLeft(find.byKey(const ValueKey('neighbor')));
        size ??= s;
        neighbor ??= n;
        expect(s, size, reason: '「$text」时按钮尺寸变了');
        expect(n, neighbor, reason: '「$text」时邻居位置变了');
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('只显示当前文案，隐藏文案不被找到也不进无障碍树', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(text: '正在导入…', busy: true));
    expect(find.text('正在导入…'), findsOneWidget);
    expect(find.text('导入'), findsNothing);
    expect(find.text('已导入'), findsNothing);
    expect(find.bySemanticsLabel('导入'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    handle.dispose();
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    for (final width in [120.0, 200.0, 360.0]) {
      testWidgets('窄屏 $width、字体缩放 $scale 不溢出', (tester) async {
        for (final (i, text) in _variants.indexed) {
          await tester.pumpWidget(
            _host(text: text, busy: i == 1, scale: scale, width: width),
          );
          expect(tester.takeException(), isNull, reason: '「$text」溢出');
          final rect = tester.getRect(find.byKey(const ValueKey('btn')));
          expect(rect.right, lessThanOrEqualTo(width));
        }
      });
    }
  }

  testWidgets('转圈替换图标，图标位尺寸不变', (tester) async {
    Future<Size> slot(bool busy) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: StableIconSlot(
              key: const ValueKey('slot'),
              icon: Icons.refresh_rounded,
              size: 18,
              busy: busy,
              spinnerSize: 15,
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const ValueKey('slot')));
    }

    final idle = await slot(false);
    final busy = await slot(true);
    expect(busy, idle);
    expect(idle, const Size(18, 18));
  });

  testWidgets('当前文案不在 variants 里也能显示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: StableWidthLabel('额外', variants: ['甲'])),
      ),
    );
    expect(find.text('额外'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
