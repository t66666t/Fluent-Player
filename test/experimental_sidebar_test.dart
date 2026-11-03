import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';
import 'package:video_player_app/widgets/experimental_home_frame.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget harness({
    List<ExperimentalSidebarAction> actions = const [],
    Set<MediaLibraryRootEntry>? available,
    ValueChanged<MediaLibraryRootEntry>? changed,
    Widget child = const TextField(),
    bool Function()? enabled,
    double scale = 1,
    List<MediaLibraryRootEntry>? order,
  }) {
    var selected = MediaLibraryRootEntry.folders;
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, update) => ExperimentalHomeFrame(
            selected: selected,
            available: available ?? MediaLibraryRootEntry.values.toSet(),
            onSelected: (entry) {
              update(() => selected = entry);
              changed?.call(entry);
            },
            onSettings: () {},
            shortcutsEnabled: enabled,
            entries: order ?? MediaLibraryRootEntryOrder.defaults,
            actions: actions,
            child: child,
          ),
        ),
      ),
    );
  }

  testWidgets('Tab traverses focus; visible buttons toggle and arrows select', (
    tester,
  ) async {
    size(tester, const Size(1440, 900));
    final entries = <MediaLibraryRootEntry>[];
    await tester.pumpWidget(
      harness(
        changed: entries.add,
        available: {
          MediaLibraryRootEntry.continueLearning,
          MediaLibraryRootEntry.folders,
          MediaLibraryRootEntry.bilibili,
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), '保留输入');
    final inputFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(same(inputFocus)));
    expect(find.byTooltip('收起侧栏'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起侧栏'), findsOneWidget);
    await tester.tap(find.byTooltip('收起侧栏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开侧栏'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开侧栏'), findsOneWidget);
    await tester.tap(find.byTooltip('展开侧栏'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(entries.last, MediaLibraryRootEntry.bilibili);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(entries.last, MediaLibraryRootEntry.folders);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '保留输入',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'drag width persists, clamps after window resize, and resets by double click',
    (tester) async {
      size(tester, const Size(1440, 900));
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      final sidebar = find.byKey(const ValueKey('experimental-sidebar'));
      final resizer = find.byKey(
        const ValueKey('experimental-sidebar-resizer'),
      );
      expect(tester.getSize(sidebar).width, 288);
      await tester.drag(resizer, const Offset(90, 0));
      await tester.pumpAndSettle();
      final adjusted = tester.getSize(sidebar).width;
      expect(adjusted, greaterThan(340));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(ExperimentalHomeFrame.widthPreference), isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, closeTo(adjusted, 1));
      tester.view.physicalSize = const Size(900, 600);
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, lessThanOrEqualTo(315));
      await tester.tap(resizer);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tap(resizer);
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 220);
      expect(prefs.getDouble(ExperimentalHomeFrame.widthPreference), isNull);
      await tester.tap(find.byTooltip('收起侧栏'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(find.byTooltip('展开侧栏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide and compact navigation use the same persisted entry order',
    (tester) async {
      size(tester, const Size(1440, 900));
      final selected = <MediaLibraryRootEntry>[];
      final order = MediaLibraryRootEntryOrder.normalize([
        MediaLibraryRootEntry.cloudDrive,
        MediaLibraryRootEntry.folders,
        MediaLibraryRootEntry.continueLearning,
      ]);
      await tester.pumpWidget(harness(order: order, changed: selected.add));
      await tester.pumpAndSettle();
      final cloud = find.widgetWithText(ListTile, '网盘');
      final folders = find.widgetWithText(ListTile, '文件夹');
      expect(
        tester.getTopLeft(cloud).dy,
        lessThan(tester.getTopLeft(folders).dy),
      );
      await tester.tap(folders);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(selected.last, MediaLibraryRootEntry.cloudDrive);
      tester.view.physicalSize = const Size(840, 600);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MediaLibraryEntrySwitcher>(
              find.byType(MediaLibraryEntrySwitcher),
            )
            .entries,
        order,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final viewport in [
    const Size(900, 360),
    const Size(1024, 600),
    const Size(1440, 900),
    const Size(2560, 1440),
  ]) {
    testWidgets('all tools reachable at $viewport with enlarged text', (
      tester,
    ) async {
      size(tester, viewport);
      var taps = 0;
      final app = harness(
        scale: 1.8,
        actions: List.generate(
          8,
          (i) => ExperimentalSidebarAction(
            '工具 $i',
            Icons.build_outlined,
            () => taps++,
          ),
        ),
      );
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
      final lastButton = find.byKey(const ValueKey('sidebar-tool-工具 7'));
      await tester.ensureVisible(lastButton);
      await tester.pumpAndSettle();
      await tester.tap(lastButton);
      expect(taps, 1);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('experimental-sidebar')))
            .width,
        inInclusiveRange(220, 320),
      );
    });
  }

  testWidgets('route gate prevents shortcuts in covered content', (
    tester,
  ) async {
    size(tester, const Size(1440, 900));
    await tester.pumpWidget(harness(enabled: () => false));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续学习'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('experimental-sidebar')), findsOneWidget);
  });
}
