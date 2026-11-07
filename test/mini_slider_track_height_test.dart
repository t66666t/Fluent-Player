import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/widgets/mini_playback_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mini progress slider builds above the navigator overlay', (
    tester,
  ) async {
    final playback = MediaPlaybackService();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 330000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 196),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorScheme: const ColorScheme.dark(primary: Colors.blue),
          ),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlaybackCard(isVisible: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byType(ErrorWidget), findsNothing);

    final theme = tester.widget<SliderTheme>(
      find
          .ancestor(of: find.byType(Slider), matching: find.byType(SliderTheme))
          .first,
    );
    expect(theme.data.trackHeight, 2);
    expect(theme.data.trackShape, isA<RoundedRectSliderTrackShape>());

    final slider = tester.renderObject<RenderBox>(find.byType(Slider));
    expect(slider.size.height, lessThanOrEqualTo(27));
    final inset = tester.widget<Padding>(
      find
          .ancestor(of: find.byType(Slider), matching: find.byType(Padding))
          .first,
    );
    expect(inset.padding, const EdgeInsets.symmetric(horizontal: 8));
  });

  testWidgets('mini card tap does not start a splash that can resume later', (
    tester,
  ) async {
    final playback = MediaPlaybackService();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 330000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 196),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlaybackCard(isVisible: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final inkWell = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('mini-playback-title')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(inkWell.splashFactory, NoSplash.splashFactory);
    expect(inkWell.highlightColor, Colors.transparent);
    expect(inkWell.splashColor, Colors.transparent);
    expect(inkWell.hoverColor, Colors.transparent);
    expect(inkWell.overlayColor?.resolve(<WidgetState>{}), Colors.transparent);
  });

  testWidgets('mini playback cover and title are one entry target', (
    tester,
  ) async {
    final playback = MediaPlaybackService();
    playback.publishRestoredSessionPreview(
      VideoItem(
        id: 'clip',
        path: 'clip.mp4',
        title: 'clip',
        durationMs: 330000,
        lastUpdated: 0,
      ),
      const Duration(seconds: 196),
    );
    var opened = 0;

    await tester.pumpWidget(
      ChangeNotifierProvider<MediaPlaybackService>.value(
        value: playback,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: MiniPlaybackCard(
                isVisible: true,
                onTap: () => opened++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final target = find.byKey(const ValueKey('mini-playback-title'));
    final cover = find.byIcon(Icons.video_library);
    final title = find.text('clip');
    final targetRect = tester.getRect(target);
    final coverRect = tester.getRect(cover);
    final titleRect = tester.getRect(title);
    expect(targetRect.contains(coverRect.center), isTrue);
    expect(targetRect.contains(titleRect.center), isTrue);
    expect(coverRect.top, greaterThanOrEqualTo(targetRect.top - 0.1));
    expect(coverRect.bottom, lessThanOrEqualTo(targetRect.bottom + 0.1));

    bool isHoverWash(Widget widget) {
      if (widget is! DecoratedBox) return false;
      final decoration = widget.decoration;
      if (decoration is! BoxDecoration) return false;
      return decoration.color == Theme.of(tester.element(target)).hoverColor;
    }

    expect(
      find.descendant(of: target, matching: find.byWidgetPredicate(isHoverWash)),
      findsNothing,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(coverRect.center);
    await tester.pumpAndSettle();

    final washRects = tester
        .renderObjectList(
          find.descendant(
            of: target,
            matching: find.byWidgetPredicate(isHoverWash),
          ),
        )
        .whereType<RenderBox>()
        .map((box) => box.localToGlobal(Offset.zero) & box.size)
        .toList();
    expect(
      washRects
          .where(
            (rect) =>
                rect.contains(coverRect.center) &&
                rect.contains(titleRect.center),
          )
          .length,
      1,
    );
    expect(
      washRects
          .where(
            (rect) =>
                rect.contains(coverRect.center) &&
                !rect.contains(titleRect.center),
          )
          .length,
      1,
    );

    await mouse.removePointer();
    await tester.tap(cover);
    await tester.pump();
    expect(opened, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    Focus.of(tester.element(title)).requestFocus();
    await tester.pumpAndSettle();
    Finder blueOutline(Finder child) => find.ancestor(
      of: child,
      matching: find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.border?.top.color == Colors.lightBlueAccent;
      }),
    );
    expect(blueOutline(title), findsOneWidget);
    expect(
      tester.widget(blueOutline(title)),
      same(tester.widget(blueOutline(cover))),
    );
  });
}
