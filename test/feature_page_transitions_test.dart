import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

const _page = Key('feature-page');
const _home = Key('feature-home');

ScaleTransition _scale(WidgetTester tester) => tester.widget<ScaleTransition>(
  find
      .ancestor(
        of: find.byKey(_page, skipOffstage: false),
        matching: find.byType(ScaleTransition, skipOffstage: false),
      )
      .first,
);

FadeTransition _fade(WidgetTester tester) => tester.widget<FadeTransition>(
  find
      .ancestor(
        of: find.byKey(_page, skipOffstage: false),
        matching: find.byType(FadeTransition, skipOffstage: false),
      )
      .first,
);

class _Probe extends SingleChildRenderObjectWidget {
  const _Probe({super.key, required super.child});

  @override
  _RenderProbe createRenderObject(BuildContext context) => _RenderProbe();
}

class _RenderProbe extends RenderProxyBox {
  int layouts = 0, paints = 0;

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

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  ValueNotifier<bool>? reduced,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
      builder: reduced == null
          ? null
          : (context, child) => ValueListenableBuilder<bool>(
              valueListenable: reduced,
              builder: (_, value, _) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: value),
                child: child!,
              ),
            ),
      home: const Scaffold(key: _home, body: Text('home')),
    ),
  );
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  for (final hz in [60, 90, 120, 144]) {
    testWidgets(
      'feature motion is continuous at $hz Hz on every platform',
      (tester) async {
        final navigator = await _host(tester);
        for (final ordinary in [false, true]) {
          Widget page(BuildContext _) => const Scaffold(key: _page);
          final route = ordinary
              ? MaterialPageRoute<bool>(builder: page)
              : AppMaterialPageRoute<bool>(builder: page);
          final closed = navigator.currentState!.push(route);
          await tester.pump();
          final step = Duration(microseconds: (1000000 / hz).round());
          var opacity = _fade(tester).opacity.value;
          var scale = _scale(tester).scale.value;
          expect(
            opacity,
            0,
            reason: 'match playback: skip full-page painting before motion',
          );
          var frames = 0;
          while (!route.animation!.isCompleted) {
            await tester.pump(step);
            final nextOpacity = _fade(tester).opacity.value;
            final nextScale = _scale(tester).scale.value;
            expect(nextOpacity, greaterThanOrEqualTo(opacity));
            expect(nextScale, inInclusiveRange(scale, 1.0));
            opacity = nextOpacity;
            scale = nextScale;
            expect(++frames, lessThan(hz));
          }
          expect(opacity, 1);
          expect(scale, 1);
          navigator.currentState!.pop(true);
          await tester.pumpAndSettle();
          expect(await closed, isTrue);
          expect(find.text('home'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
      },
      variant: TargetPlatformVariant.all(),
    );
  }

  testWidgets(
    'the previous page stays still during the same subtle playback scale',
    (tester) async {
      final navigator = await _host(tester);
      final home = tester.renderObject(find.byKey(_home));
      final transform = home.getTransformTo(null).storage.toList();
      navigator.currentState!.push(
        AppMaterialPageRoute<void>(builder: (_) => const Scaffold(key: _page)),
      );
      await tester.pump();
      await tester.pump(); // Complete preparation before measuring motion time.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 90));
      expect(home.getTransformTo(null).storage, transform);
      expect(_fade(tester).opacity.value, 1);
      expect(_scale(tester).scale.value, inExclusiveRange(0.985, 1.0));
      expect(
        find.ancestor(
          of: find.byKey(_page),
          matching: find.byType(ScaleTransition),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      expect(home.getTransformTo(null).storage, transform);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('interrupting entry reverses the displayed position and alpha', (
    tester,
  ) async {
    final navigator = await _host(tester);
    navigator.currentState!.push(
      AppMaterialPageRoute<void>(builder: (_) => const Scaffold(key: _page)),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final position = _scale(tester).scale.value;
    final opacity = _fade(tester).opacity.value;
    navigator.currentState!.pop();
    await tester.pump();
    expect(_scale(tester).scale.value, position);
    expect(_fade(tester).opacity.value, opacity);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'moving a complex page adds no layout or static child paint work',
    (tester) async {
      final navigator = await _host(tester);
      var builds = 0;
      navigator.currentState!.push(
        AppMaterialPageRoute<void>(
          builder: (_) {
            builds++;
            return const _Probe(
              key: _page,
              child: ColoredBox(color: Colors.black),
            );
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final probe = tester.renderObject<_RenderProbe>(find.byKey(_page));
      final initialBuilds = builds,
          layouts = probe.layouts,
          paints = probe.paints;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(builds, initialBuilds);
      expect(probe.layouts, layouts);
      expect(probe.paints, paints);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('late content paints during both entry and return', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final colour = ValueNotifier<Color>(Colors.black);
    addTearDown(colour.dispose);
    final route = AppMaterialPageRoute<void>(
      builder: (_) => _Probe(
        key: _page,
        child: ValueListenableBuilder<Color>(
          valueListenable: colour,
          builder: (_, value, _) => ColoredBox(color: value),
        ),
      ),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final probe = tester.renderObject<_RenderProbe>(find.byKey(_page));
    var paints = probe.paints;
    colour.value = Colors.blue;
    await tester.pump();
    expect(probe.paints, greaterThan(paints));
    expect(route.animation!.status, AnimationStatus.forward);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    paints = probe.paints;
    colour.value = Colors.green;
    await tester.pump();
    expect(probe.paints, greaterThan(paints));
    expect(route.animation!.status, AnimationStatus.reverse);
    await tester.pumpAndSettle();
  });

  testWidgets('reducing motion keeps the same mounted form and focus', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    final text = TextEditingController(text: '未提交的修改');
    final focus = FocusNode();
    addTearDown(text.dispose);
    addTearDown(focus.dispose);
    final navigator = await _host(tester, reduced: reduced);
    navigator.currentState!.push(
      AppMaterialPageRoute<void>(
        builder: (_) => Scaffold(
          key: _page,
          body: TextField(controller: text, focusNode: focus),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final element = tester.element(find.byKey(_page));
    focus.requestFocus();
    reduced.value = true;
    await tester.pump();
    expect(_scale(tester).scale.value, 1);
    expect(_fade(tester).opacity.value, 1);
    expect(tester.element(find.byKey(_page)), same(element));
    expect(text.text, '未提交的修改');
    expect(focus.hasFocus, isTrue);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
