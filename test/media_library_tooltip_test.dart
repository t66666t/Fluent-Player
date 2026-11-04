import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_tooltip.dart';

const _hintColor = Color(0xFFFF00FF);
const _miniPlayer = ValueKey('mini-player');

class _SelectingPage extends StatelessWidget {
  const _SelectingPage({required this.onRename});

  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: const Center(child: Text('library page')),
    bottomNavigationBar: SizedBox(
      height: 56 + MediaQuery.paddingOf(context).bottom,
      child: SafeArea(
        top: false,
        child: Center(
          child: MediaLibraryTooltip(
            message: '重命名',
            child: TextButton(
              onPressed: onRename,
              child: const Text('rename action'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final (platform, size, inset) in [
    (TargetPlatform.android, const Size(390, 844), 24.0),
    (TargetPlatform.windows, const Size(1200, 800), 0.0),
  ]) {
    for (final folder in [false, true]) {
      for (final mouseInput in [false, true]) {
        testWidgets('selection hint paints over mini player on $platform, '
            'folder=$folder, hover=$mouseInput', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.view.padding = FakeViewPadding(bottom: inset);
          tester.view.viewPadding = FakeViewPadding(bottom: inset);
          addTearDown(tester.view.reset);
          final boundary = GlobalKey();
          final root = GlobalKey<NavigatorState>();
          var renamed = 0;
          final page = _SelectingPage(onRename: () => renamed++);
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                navigatorKey: root,
                theme: ThemeData.dark().copyWith(
                  tooltipTheme: const TooltipThemeData(
                    waitDuration: Duration(milliseconds: 700),
                    decoration: BoxDecoration(color: _hintColor),
                  ),
                ),
                home: Builder(
                  builder: (context) => MediaLibraryTooltipScope(
                    isCurrent: ModalRoute.isCurrentOf(context) ?? true,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Navigator(
                          onGenerateRoute: (_) => MaterialPageRoute<void>(
                            allowSnapshotting: false,
                            builder: (_) => folder
                                ? const Scaffold(body: Text('home'))
                                : page,
                          ),
                        ),
                        Positioned(
                          key: _miniPlayer,
                          left: 0,
                          right: 0,
                          bottom: 56 + inset + 6,
                          height: 160,
                          child: const ColoredBox(color: Colors.blue),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (folder) {
            unawaited(
              Navigator.of(tester.element(find.text('home'))).push(
                MaterialPageRoute<void>(
                  allowSnapshotting: false,
                  builder: (_) => page,
                ),
              ),
            );
            await tester.pumpAndSettle();
          }
          final card = find.byKey(_miniPlayer);
          final cardRect = tester.getRect(card);
          final target = find.byTooltip(RegExp('重命名'));
          expect(target, findsOneWidget);
          final buttonState = tester.state(find.byType(TextButton));
          final message = tester.widget<RawTooltip>(target).semanticsTooltip!;
          final labelCount = find.text(message).evaluate().length;
          if (mouseInput) {
            final mouse = await tester.createGesture(
              kind: PointerDeviceKind.mouse,
            );
            await mouse.addPointer(location: Offset.zero);
            addTearDown(mouse.removePointer);
            await mouse.moveTo(tester.getCenter(target));
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.text(message), findsNWidgets(labelCount));
            await tester.pump(const Duration(milliseconds: 700));
          } else {
            await tester.longPress(target);
          }
          await tester.pump(const Duration(milliseconds: 200));
          expect(renamed, 0);
          final hint = find.text(message).last;
          expect(find.text(message), findsNWidgets(labelCount + 1));
          final decoration = find.ancestor(
            of: hint,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is DecoratedBox &&
                  widget.decoration == const BoxDecoration(color: _hintColor),
            ),
          );
          final hintRect = tester.getRect(decoration);
          expect(hintRect.overlaps(cardRect), isTrue);
          // Check actual pixels, not just the presence of tooltip text: the
          // old nested overlay built the hint but painted the player over it.
          final sample = Offset(
            hintRect.left + 2,
            hintRect.intersect(cardRect).center.dy,
          );
          final hintBox = tester.renderObject(hint);
          expect(
            tester
                .hitTestOnBinding(sample)
                .path
                .any((entry) => identical(entry.target, hintBox)),
            isFalse,
          );
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage();
            try {
              final pixels = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              final index =
                  (sample.dy.floor() * image.width + sample.dx.floor()) * 4;
              expect(pixels.buffer.asUint8List(index, 4), [255, 0, 255, 255]);
            } finally {
              image.dispose();
            }
          });
          expect(tester.getRect(card), cardRect);

          // A covering root route must remove this promoted hint too.
          unawaited(
            showDialog<void>(
              context: tester.element(target),
              builder: (_) => const AlertDialog(content: Text('cover')),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(message), findsNWidgets(labelCount));
          expect(tester.state(find.byType(TextButton)), same(buttonState));
          root.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.text(message), findsNWidgets(labelCount));
          await tester.tap(find.byTooltip(RegExp('重命名')));
          await tester.pump();
          expect(renamed, 1);
          tester
              .state<TooltipState>(find.byType(MediaLibraryTooltip))
              .ensureTooltipVisible();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.text(message), findsNWidgets(labelCount + 1));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }, variant: TargetPlatformVariant({platform}));
      }
    }
  }

  testWidgets('outside the library, ordinary Tooltip behavior is retained', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: MediaLibraryTooltip(
              message: 'ordinary hint',
              child: Icon(Icons.info),
            ),
          ),
        ),
      ),
    );
    tester
        .state<TooltipState>(find.byType(MediaLibraryTooltip))
        .ensureTooltipVisible();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('ordinary hint'), findsOneWidget);
    Tooltip.dismissAllToolTips();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('ordinary hint'), findsNothing);
  });
}
