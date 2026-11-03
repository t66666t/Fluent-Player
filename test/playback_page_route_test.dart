import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/playback_page_route.dart';

const _sourceKey = Key('source');
const _playerKey = Key('player');

class _SurfaceProbe extends SingleChildRenderObjectWidget {
  const _SurfaceProbe({required super.child, super.key});

  @override
  _RenderSurfaceProbe createRenderObject(BuildContext context) =>
      _RenderSurfaceProbe();
}

class _RenderSurfaceProbe extends RenderProxyBox {
  int layouts = 0;
  int paints = 0;

  @override
  void performLayout() {
    layouts++;
    super.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    paints++;
    super.paint(context, offset);
  }
}

ScaleTransition _scale(WidgetTester tester) => tester.widget<ScaleTransition>(
  find
      .ancestor(
        of: find.byKey(_playerKey, skipOffstage: false),
        matching: find.byType(ScaleTransition, skipOffstage: false),
      )
      .first,
);

FadeTransition _fade(WidgetTester tester) => tester.widget<FadeTransition>(
  find
      .ancestor(
        of: find.byKey(_playerKey, skipOffstage: false),
        matching: find.byType(FadeTransition, skipOffstage: false),
      )
      .first,
);

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  ValueNotifier<bool>? reduceMotion,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
      builder: reduceMotion == null
          ? null
          : (context, child) => ValueListenableBuilder<bool>(
              valueListenable: reduceMotion,
              builder: (context, reduced, _) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(disableAnimations: reduced),
                child: child!,
              ),
            ),
      home: const Scaffold(key: _sourceKey, body: Text('library')),
    ),
  );
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  for (final hz in [60, 90, 120, 144]) {
    testWidgets(
      'live entry and exit are monotonic at $hz Hz on every platform',
      (tester) async {
        final navigator = await _host(tester);
        final route = PlaybackPageRoute<void>(
          builder: (_) => const Scaffold(key: _playerKey, body: Text('player')),
        );
        navigator.currentState!.push(route);
        await tester.pump();
        expect(route.animation!.status, AnimationStatus.forward);
        final step = Duration(microseconds: (1000000 / hz).round());
        var previousOpacity = _fade(tester).opacity.value;
        var previousScale = _scale(tester).scale.value;
        var frames = 0;
        while (!route.animation!.isCompleted) {
          await tester.pump(step);
          final opacity = _fade(tester).opacity.value;
          final scale = _scale(tester).scale.value;
          expect(opacity, greaterThanOrEqualTo(previousOpacity));
          expect(scale, inInclusiveRange(previousScale, 1.0));
          previousOpacity = opacity;
          previousScale = scale;
          expect(++frames, lessThan(hz));
        }
        expect(previousOpacity, 1);
        expect(previousScale, 1);

        navigator.currentState!.pop();
        await tester.pump();
        expect(route.animation!.status, AnimationStatus.reverse);
        while (find.byKey(_playerKey).evaluate().isNotEmpty) {
          final opacity = _fade(tester).opacity.value;
          final scale = _scale(tester).scale.value;
          expect(opacity, lessThanOrEqualTo(previousOpacity));
          expect(scale, inInclusiveRange(0.985, previousScale));
          previousOpacity = opacity;
          previousScale = scale;
          await tester.pump(step);
          expect(++frames, lessThan(hz));
        }
        expect(find.text('library'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.all(),
    );
  }

  testWidgets('the browsing page stays still during entry and return', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final source = tester.renderObject(find.byKey(_sourceKey));
    final originalTransform = source.getTransformTo(null).storage.toList();
    final route = PlaybackPageRoute<void>(
      builder: (_) => const Scaffold(key: _playerKey),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(source.getTransformTo(null).storage, originalTransform);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(source.getTransformTo(null).storage, originalTransform);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the player becomes opaque before the scale animation finishes', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final route = PlaybackPageRoute<void>(
      builder: (_) => const Scaffold(key: _playerKey),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 90));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(_fade(tester).opacity.value, 1);
    expect(_scale(tester).scale.value, lessThan(1));
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Back reverses the displayed entry without a scale or alpha jump',
    (tester) async {
      final navigator = await _host(tester);
      final route = PlaybackPageRoute<void>(
        builder: (_) => const Scaffold(key: _playerKey),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 70));
      final scale = _scale(tester).scale.value;
      final opacity = _fade(tester).opacity.value;
      navigator.currentState!.pop();
      await tester.pump();
      expect(_scale(tester).scale.value, closeTo(scale, 0.000001));
      expect(_fade(tester).opacity.value, closeTo(opacity, 0.000001));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(_scale(tester).scale.value, lessThan(scale));
      expect(_fade(tester).opacity.value, lessThan(opacity));
      await tester.pumpAndSettle();
      expect(find.text('library'), findsOneWidget);
    },
  );

  testWidgets(
    'animation composites the surface without laying it out or repainting it',
    (tester) async {
      final navigator = await _host(tester);
      var builds = 0;
      final route = PlaybackPageRoute<void>(
        builder: (_) {
          builds++;
          return const _SurfaceProbe(
            key: _playerKey,
            child: ColoredBox(color: Colors.black, child: SizedBox.expand()),
          );
        },
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final probe = tester.renderObject<_RenderSurfaceProbe>(
        find.byKey(_playerKey),
      );
      final layouts = probe.layouts;
      final paints = probe.paints;
      final initialBuilds = builds;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(builds, initialBuilds);
      expect(probe.layouts, layouts);
      expect(probe.paints, paints);
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late surface updates stay live during entry and exit', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final colour = ValueNotifier(Colors.black);
    addTearDown(colour.dispose);
    final route = PlaybackPageRoute<void>(
      builder: (_) => ValueListenableBuilder<Color>(
        valueListenable: colour,
        builder: (_, value, _) => ColoredBox(
          key: _playerKey,
          color: value,
          child: const SizedBox.expand(),
        ),
      ),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    colour.value = Colors.blue;
    await tester.pump();
    expect(
      tester.widget<ColoredBox>(find.byKey(_playerKey)).color,
      Colors.blue,
    );
    expect(route.animation!.status, AnimationStatus.forward);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    colour.value = Colors.green;
    await tester.pump();
    expect(
      tester.widget<ColoredBox>(find.byKey(_playerKey)).color,
      Colors.green,
    );
    expect(route.animation!.status, AnimationStatus.reverse);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'reduced motion keeps the same mounted surface at full size and alpha',
    (tester) async {
      final reduced = ValueNotifier(true);
      addTearDown(reduced.dispose);
      final navigator = await _host(tester, reduceMotion: reduced);
      final route = PlaybackPageRoute<void>(
        builder: (_) => const Scaffold(key: _playerKey),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      expect(_scale(tester).scale.value, 1);
      expect(_fade(tester).opacity.value, 1);
      final surface = tester.element(
        find.byKey(_playerKey, skipOffstage: false),
      );
      reduced.value = false;
      await tester.pump();
      expect(tester.element(find.byKey(_playerKey)), same(surface));
      await tester.pumpAndSettle();
      reduced.value = true;
      navigator.currentState!.pop();
      await tester.pump();
      expect(_scale(tester).scale.value, 1);
      expect(_fade(tester).opacity.value, 1);
      expect(tester.element(find.byKey(_playerKey)), same(surface));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
