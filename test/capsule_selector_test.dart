import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

void main() {
  const menuKey = ValueKey('capsule-choice-menu');
  for (final useButton in [true, false]) {
    testWidgets('checked action menus show both checkbox states ($useButton)', (
      tester,
    ) async {
      final choices = <String?>[];
      const items = [
        CheckedPopupMenuItem(
          value: 'desktop',
          checked: true,
          child: Text('桌面模式'),
        ),
        CheckedPopupMenuItem(
          value: 'optional',
          checked: false,
          child: Text('可选功能'),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: useButton
                ? CapsulePopupMenuButton<String>(
                    tooltip: '菜单',
                    onSelected: choices.add,
                    itemBuilder: (_) => items,
                  )
                : Builder(
                    builder: (context) => TextButton(
                      onPressed: () async {
                        choices.add(
                          await showCapsuleMenu<String>(
                            context: context,
                            position: const RelativeRect.fromLTRB(0, 40, 0, 0),
                            items: items,
                          ),
                        );
                      },
                      child: const Text('菜单'),
                    ),
                  ),
          ),
        ),
      );
      await tester.tap(useButton ? find.byTooltip('菜单') : find.text('菜单'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      for (final (label, checked) in [('桌面模式', true), ('可选功能', false)]) {
        expect(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Semantics && widget.properties.checked == checked,
            ),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.byIcon(Icons.check_box_outline_blank));
      await tester.pumpAndSettle();
      expect(choices, ['optional']);
      expect(find.byKey(menuKey), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  for (final nearRightEdge in [false, true]) {
    testWidgets(
      'page menu fits its labels and follows the left edge ($nearRightEdge)',
      (tester) async {
        tester.view.physicalSize = const Size(800, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final left = nearRightEdge ? 740.0 : 40.0;
        final triggerWidth = nearRightEdge ? 52.0 : 700.0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: left,
                    top: 80,
                    width: triggerWidth,
                    child: CapsuleDropdownButton<String>(
                      plain: true,
                      isExpanded: true,
                      value: 'zh',
                      onChanged: (_) {},
                      items: const [
                        DropdownMenuItem(value: 'zh', child: Text('简体中文')),
                        DropdownMenuItem(value: 'en', child: Text('English')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byType(CapsuleDropdownButton<String>));
        await tester.pumpAndSettle();
        final menu = tester.getRect(find.byKey(menuKey));
        expect(menu.width, inInclusiveRange(160, 240));
        if (nearRightEdge) {
          expect(menu.right, closeTo(792, 0.01));
        } else {
          expect(menu.left, closeTo(left, 0.01));
          expect(menu.width, lessThan(triggerWidth / 2));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('compact download controls keep text and arrows inside 28px', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            height: 28,
            child: CapsuleDropdownButton<int>(
              value: 1,
              isExpanded: true,
              isDense: true,
              items: const [
                DropdownMenuItem(
                  value: 1,
                  child: Text(
                    '1080P · HEVC 编码格式',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(CapsuleDropdownButton<int>));
    final label = tester.getRect(find.text('1080P · HEVC 编码格式'));
    final arrow = tester.getRect(
      find.byIcon(Icons.keyboard_arrow_down_rounded),
    );
    expect(label.top, greaterThanOrEqualTo(bounds.top));
    expect(label.bottom, lessThanOrEqualTo(bounds.bottom));
    expect(arrow.top, greaterThanOrEqualTo(bounds.top));
    expect(arrow.bottom, lessThanOrEqualTo(bounds.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('menus avoid safe areas and the keyboard', (tester) async {
    tester.view.physicalSize = const Size(360, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            padding: const EdgeInsets.fromLTRB(16, 28, 16, 20),
            viewInsets: const EdgeInsets.only(bottom: 240),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: CapsuleDropdownButton<int>(
              value: 0,
              onChanged: (_) {},
              items: List.generate(
                30,
                (index) =>
                    DropdownMenuItem(value: index, child: Text('语言 $index')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(CapsuleDropdownButton<int>));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byKey(menuKey));
    expect(rect.left, greaterThanOrEqualTo(24));
    expect(rect.right, lessThanOrEqualTo(336));
    expect(rect.top, greaterThanOrEqualTo(36));
    expect(rect.bottom, lessThanOrEqualTo(352));
    expect(tester.takeException(), isNull);
  });
  for (final size in [
    const Size(220, 480),
    const Size(320, 568),
    const Size(360, 800),
    const Size(844, 320),
    const Size(1440, 900),
  ]) {
    for (final bottom in [false, true]) {
      testWidgets('long options fit $size, bottom=$bottom', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        int? picked;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(size.width == 220 ? 1.5 : 1.2),
              ),
              child: child!,
            ),
            home: Scaffold(
              body: Align(
                alignment: bottom ? Alignment.bottomRight : Alignment.topLeft,
                child: SizedBox(
                  width: 190,
                  child: CapsuleDropdownButtonFormField<int>(
                    initialValue: 28,
                    decoration: const InputDecoration(labelText: '默认字幕翻译模型'),
                    items: List.generate(
                      30,
                      (index) => DropdownMenuItem(
                        value: index,
                        child: Text(
                          '模型 $index · 这是很长的中文说明 very-long-unbroken-label-abcdefghijklmnopqrstuvwxyz',
                        ),
                      ),
                    ),
                    onChanged: (value) => picked = value,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(CapsuleDropdownButtonFormField<int>));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(menuKey));
        expect(rect.left, greaterThanOrEqualTo(8));
        expect(rect.right, lessThanOrEqualTo(size.width - 8));
        expect(rect.top, greaterThanOrEqualTo(8));
        expect(rect.bottom, lessThanOrEqualTo(size.height - 8));
        expect(tester.takeException(), isNull);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(picked, 29);
        expect(find.byKey(menuKey), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'nullable choices, cancellation and form validation keep their semantics',
    (tester) async {
      final form = GlobalKey<FormState>();
      final field = GlobalKey<FormFieldState<String?>>();
      final picked = <String?>[];
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: form,
              child: CapsuleDropdownButtonFormField<String?>(
                key: field,
                initialValue: 'en',
                items: const [
                  DropdownMenuItem(value: null, child: Text('不下载字幕')),
                  DropdownMenuItem(value: 'en', child: Text('英语')),
                ],
                onChanged: picked.add,
                validator: (value) => value == null ? '请选择字幕' : null,
                onSaved: (value) => saved = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(CapsuleDropdownButton<String?>));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      await tester.tap(find.byType(CapsuleDropdownButton<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不下载字幕').last);
      await tester.pumpAndSettle();
      expect(picked, [null]);
      expect(form.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('请选择字幕'), findsOneWidget);
      form.currentState!.reset();
      form.currentState!.save();
      expect(saved, 'en');
      expect(field.currentState!.value, 'en');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('action menus preserve keys, callbacks and disabled options', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CapsulePopupMenuButton<int>(
            tooltip: '服务选项',
            onSelected: (value) => events.add('selected:$value'),
            onCanceled: () => events.add('cancel'),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 0,
                enabled: false,
                child: Text('暂不可用'),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                key: const ValueKey('pick-service'),
                value: 1,
                onTap: () => events.add('tap'),
                child: const Row(
                  children: [
                    Icon(Icons.cloud),
                    SizedBox(width: 8),
                    Text('在线模型服务'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('服务选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('暂不可用'));
    expect(events, isEmpty);
    await tester.tap(find.byKey(const ValueKey('pick-service')));
    await tester.pumpAndSettle();
    expect(events, ['tap', 'selected:1']);
    expect(find.byKey(menuKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
