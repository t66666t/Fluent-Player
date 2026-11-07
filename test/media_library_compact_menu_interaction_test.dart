import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';
import 'package:video_player_app/widgets/capsule_option.dart';
import 'package:video_player_app/widgets/media_library_compact_app_bar.dart';

void main() {
  const preview = bool.fromEnvironment('COMPACT_MORE_MENU_PREVIEW');
  const frame = ValueKey('compact-menu-frame');
  const labels = ['定时关闭', '搜索媒体库', '回收站', '媒体库设置'];
  const icons = [
    Icons.schedule_rounded,
    Icons.search_rounded,
    Icons.delete_outline,
    Icons.settings_outlined,
  ];

  setUpAll(() async {
    if (!preview) return;
    await (FontLoader(
      'Noto Sans SC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  setUp(() {
    final strategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTouch;
    addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
  });

  Future<void> open(
    WidgetTester tester,
    List<String> events, {
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: frame,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appInteractionTheme(
            ThemeData(brightness: Brightness.dark, fontFamily: 'Noto Sans SC'),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(
              title: const MediaLibraryCompactTitle(text: '媒体库'),
              actions: [
                SizedBox(
                  width: 40,
                  height: 48,
                  child: MediaLibraryCompactMoreButton(
                    itemBuilder: (_) => [
                      for (var i = 0; i < labels.length; i++)
                        mediaLibraryCompactMenuItem(
                          icon: icons[i],
                          label: labels[i],
                          onSelected: () => events.add(labels[i]),
                          onLongPress: i < 2
                              ? null
                              : () => events.add('long:${labels[i]}'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
  }

  Finder row(String label) => find
      .ancestor(of: find.text(label), matching: find.byType(CapsuleOption))
      .first;

  double focusAlpha(WidgetTester tester, String label) {
    final paint = find
        .ancestor(
          of: find.text(label),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.position == DecorationPosition.foreground &&
                (widget.decoration as BoxDecoration).color != null,
          ),
        )
        .first;
    return (tester.widget<DecoratedBox>(paint).decoration as BoxDecoration)
        .color!
        .a;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (!preview) return;
    await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(frame))
          .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('.artifacts/compact-more-menu/$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final (size, scale) in [
    (const Size(320, 640), 1.0),
    (const Size(390, 844), 1.8),
    (const Size(768, 1024), 1.0),
  ]) {
    testWidgets('tap and long-press menu entries align at $size / $scale', (
      tester,
    ) async {
      final events = <String>[];
      await open(tester, events, size: size, scale: scale);
      final textLeft = tester.getTopLeft(find.text(labels.first)).dx;
      final iconBounds = tester.getRect(find.byIcon(icons.first));
      final rowBounds = tester.getRect(row(labels.first));
      for (var i = 0; i < labels.length; i++) {
        final bounds = tester.getRect(row(labels[i]));
        expect(
          tester.getTopLeft(find.text(labels[i])).dx,
          closeTo(textLeft, .01),
        );
        expect(tester.getRect(find.byIcon(icons[i])).left, iconBounds.left);
        expect(tester.getSize(find.byIcon(icons[i])), iconBounds.size);
        expect(bounds.left, rowBounds.left);
        expect(bounds.right, rowBounds.right);
        expect(
          tester.widget<CapsuleOption>(row(labels[i])).color,
          Colors.transparent,
        );
      }
      await capture(tester, 'more-${size.width.toInt()}-$scale');
      await tester.longPress(find.text('媒体库设置'));
      await tester.pumpAndSettle();
      expect(events, ['long:媒体库设置']);
      expect(find.byType(CapsuleOption), findsNothing);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回收站'));
      await tester.pumpAndSettle();
      expect(events, ['long:媒体库设置', '回收站']);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'touch opening stays neutral while keyboard focus remains visible',
    (tester) async {
      final events = <String>[];
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
      await open(tester, events);
      expect(
        tester.widget<CapsuleOption>(row('定时关闭')).color,
        Colors.transparent,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(focusAlpha(tester, '定时关闭'), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusAlpha(tester, '定时关闭'), 0);
      expect(focusAlpha(tester, '搜索媒体库'), greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(events, ['搜索媒体库']);
      expect(find.byType(CapsuleOption), findsNothing);
    },
  );

  testWidgets(
    'held menu presses follow the row corners and clear on cancellation',
    (tester) async {
      final events = <String>[];
      await open(tester, events);
      final bounds = tester.getRect(row('搜索媒体库'));
      Future<({int width, Uint8List bytes})> pixels() async =>
          (await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(frame))
                .toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final width = image.width;
            image.dispose();
            return (width: width, bytes: bytes);
          }))!;
      List<int> color(({int width, Uint8List bytes}) data, double x, double y) {
        final offset = (y.floor() * data.width + x.floor()) * 4;
        return data.bytes.sublist(offset, offset + 4);
      }

      final before = await pixels();
      final corner = color(before, bounds.left + 1, bounds.top + 1);
      final interior = color(before, bounds.center.dx, bounds.top + 3);
      final gesture = await tester.startGesture(bounds.center);
      await tester.pump();
      final held = await pixels();
      expect(color(held, bounds.left + 1, bounds.top + 1), corner);
      expect(color(held, bounds.center.dx, bounds.top + 3), isNot(interior));
      await capture(tester, 'more-phone-held');
      await gesture.cancel();
      await tester.pumpAndSettle();
      final released = await pixels();
      expect(color(released, bounds.center.dx, bounds.top + 3), interior);
      expect(events, isEmpty);
      expect(find.text('搜索媒体库'), findsOneWidget);
    },
  );
}
