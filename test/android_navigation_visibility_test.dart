import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/playback_page_route.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';

const _target = Key('target');
const _source = Color(0xFFB02020);
const _destination = Color(0xFF2040B0);

class _RestartableRoute extends AppMaterialPageRoute<void> {
  _RestartableRoute() : super(builder: (_) => _page());
  AnimationController get motion => controller!;
}

T _transition<T extends Widget>(WidgetTester tester) => tester.widget(
  find.ancestor(of: find.byKey(_target), matching: find.byType(T)).first,
);
Widget _page() => const ColoredBox(
  key: _target,
  color: _destination,
  child: Center(
    child: SizedBox(
      width: 80,
      height: 80,
      child: ColoredBox(color: Colors.white),
    ),
  ),
);
Future<Color> _pixel(WidgetTester tester, GlobalKey boundary) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = render.toImageSync(pixelRatio: 1);
  final data = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final index = (300 * image.width + 100) * 4;
  final colour = Color.fromARGB(
    data.getUint8(index + 3),
    data.getUint8(index),
    data.getUint8(index + 1),
    data.getUint8(index + 2),
  );
  image.dispose();
  return colour;
}

PageRoute<void> _route(String kind) => switch (kind) {
  'folder' => MediaLibraryFolderRoute<void>(builder: (_) => _page()),
  'page' => AppMaterialPageRoute<void>(builder: (_) => _page()),
  _ => PlaybackPageRoute<void>(builder: (_) => _page()),
};
void main() {
  testWidgets(
    'a gesture-style controller restart drops the old cold-frame offset',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
          home: const Scaffold(),
        ),
      );
      final route = _RestartableRoute();
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      route.motion.forward(from: 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(route.animation!.value, inExclusiveRange(0.0, 0.1));
      route.motion.reverse(from: 0.6);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(route.animation!.value, inExclusiveRange(0.0, 0.6));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final kind in ['video', 'folder', 'page']) {
    testWidgets('$kind cold first frame advances visibly without a forced wait', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
          home: Navigator(
            key: navigator,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => const ColoredBox(color: _source),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final route = _route(kind);
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        route.animation!.value,
        inExclusiveRange(0.0, 0.1),
        reason:
            'a cold frame must neither consume the fade nor add another zero-progress frame',
      );
      expect(
        _transition<FadeTransition>(tester).opacity.value,
        inExclusiveRange(0.0, 1.0),
      );
      expect(
        _transition<ScaleTransition>(tester).scale.value,
        inExclusiveRange(0.985, 1.0),
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(route.animation!.value, inExclusiveRange(0.9, 1.0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  for (final hz in [60, 90, 120, 144]) {
    testWidgets(
      'folder and ordinary pages exactly match video motion at $hz Hz',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        final navigator = GlobalKey<NavigatorState>();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
            builder: (_, child) => RepaintBoundary(key: boundary, child: child),
            home: Navigator(
              key: navigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => const ColoredBox(color: _source),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final step = Duration(microseconds: (1000000 / hz).round());
        List<(double, double, double)>? video;
        for (final kind in ['video', 'folder', 'page']) {
          final route = _route(kind);
          final closed = navigator.currentState!.push(route);
          await tester.pump();
          expect(route.transitionDuration, const Duration(milliseconds: 260));
          expect(_transition<FadeTransition>(tester).opacity.value, 0);
          expect(_transition<ScaleTransition>(tester).scale.value, 0.985);
          expect(await _pixel(tester, boundary), _source);
          expect(
            find.ancestor(
              of: find.byKey(_target),
              matching: find.byType(SlideTransition),
            ),
            findsNothing,
          );
          final samples = <(double, double, double)>[];
          await tester.pump(step);
          expect(
            route.animation!.value,
            greaterThan(0),
            reason: 'the next vsync must move; no forced preparation wait',
          );
          final mixed = await _pixel(tester, boundary);
          expect(mixed, isNot(_source));
          expect(mixed, isNot(_destination));
          while (!route.animation!.isCompleted) {
            samples.add((
              route.animation!.value,
              _transition<ScaleTransition>(tester).scale.value,
              _transition<FadeTransition>(tester).opacity.value,
            ));
            final center = tester.getCenter(find.byKey(_target));
            expect(center.dx, closeTo(195, 0.000001));
            expect(
              center.dy,
              closeTo(422, 0.000001),
              reason: 'scale about a fixed center; never slide the page',
            );
            await tester.pump(step);
          }
          navigator.currentState!.pop();
          await tester.pump();
          while (find.byKey(_target).evaluate().isNotEmpty) {
            samples.add((
              route.animation!.value,
              _transition<ScaleTransition>(tester).scale.value,
              _transition<FadeTransition>(tester).opacity.value,
            ));
            await tester.pump(step);
          }
          if (video == null) {
            video = samples;
          } else {
            expect(
              samples,
              video,
              reason:
                  '$kind must share video timing, scale and fade in both directions',
            );
          }
          await closed;
          expect(tester.takeException(), isNull);
        }
      },
      variant: TargetPlatformVariant.all(),
    );
  }
}
