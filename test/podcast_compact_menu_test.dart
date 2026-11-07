import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';
import 'package:video_player_app/utils/keyboard_focus_visibility.dart';
import 'package:video_player_app/widgets/media_library_anchor_menu.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_menu.dart';

void main() {
  testWidgets('compact card menu uses an inset rounded keyboard focus', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: KeyboardFocusTheme(
          child: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                autofocus: true,
                onPressed: () async {
                  selected = await showPodcastMenu(
                    context,
                    title: '节目操作',
                    compact: true,
                    cardLayout: true,
                    actions: const [
                      PodcastMenuAction('one', '第一项', Icons.play_arrow),
                      PodcastMenuAction('two', '第二项', Icons.download),
                      PodcastMenuAction('three', '第三项', Icons.favorite),
                    ],
                  );
                },
                child: const Text('打开菜单'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('第一项'))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('podcast-compact-menu'));
    final focusedRow = find.descendant(
      of: menu,
      matching: find.byWidgetPredicate(
        (widget) => widget is MediaLibraryMenuItemFocus && widget.focused,
      ),
    );
    expect(
      focusedRow,
      findsOneWidget,
      reason:
          'primary focus: ${FocusManager.instance.primaryFocus}; '
          'tooltip: ${FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<Tooltip>()?.message}; '
          'rows: ${tester.widgetList<MediaLibraryMenuItemFocus>(find.byType(MediaLibraryMenuItemFocus)).map((row) => row.focused).toList()}',
    );
    final focus = find.descendant(
      of: focusedRow,
      matching: find.byType(KeyboardFocusHighlight),
    );
    final decoration = tester.widget<KeyboardFocusHighlight>(focus).decoration;
    expect(decoration.borderRadius, isNot(BorderRadius.zero));
    final rowRect = tester.getRect(focusedRow);
    final focusRect = tester.getRect(focus);
    expect(focusRect.left, greaterThan(rowRect.left));
    expect(focusRect.right, lessThan(rowRect.right));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'two');
    expect(menu, findsNothing);
  });

  for (final size in [
    const Size(320, 568),
    const Size(375, 667),
    const Size(844, 390),
    const Size(1024, 768),
    const Size(1440, 900),
  ]) {
    testWidgets('all compact menu actions fit and remain clickable at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? selected;
      final labels = [
        '下载完整节目',
        '重命名',
        '节目链接',
        '收藏节目',
        '标记为已听',
        '标记为未听',
        '隐藏节目',
        '加入播放队列',
        '从队列移除',
        '下载视频版',
        '下载音频版',
        '取消下载任务',
        '始终保留文件',
        '导出媒体文件',
        '删除下载',
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: PodcastMenuButton(
                title: '节目操作',
                subtitle: '很长的节目标题用于检查小屏幕中的布局与省略显示',
                compact: true,
                actions: [
                  for (var i = 0; i < labels.length; i++)
                    PodcastMenuAction(
                      '$i',
                      labels[i],
                      Icons.download,
                      destructive: i == labels.length - 1,
                    ),
                ],
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(PodcastIconButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final menuSize = tester.getSize(
        find.byKey(const ValueKey('podcast-compact-menu')),
      );
      expect(menuSize.width, lessThanOrEqualTo(size.height < 500 ? 420 : 280));
      expect(menuSize.height, lessThan(420));
      final trigger = tester.getRect(find.byType(PodcastIconButton));
      final menu = tester.getRect(
        find.byKey(const ValueKey('podcast-compact-menu')),
      );
      expect(menu.top, closeTo(trigger.bottom + 6, .01));
      expect(menu.right, closeTo(size.width - 8, .01));
      for (final label in labels) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(scroll.position.maxScrollExtent, closeTo(0, .01));
      await tester.tap(find.text(labels.last));
      await tester.pumpAndSettle();
      expect(selected, '${labels.length - 1}');
    });
  }
}
