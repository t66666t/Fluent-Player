import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/media_library_folder_route.dart';

class _GridProbe extends SingleChildRenderObjectWidget {
  const _GridProbe({required super.child, required super.key});

  @override
  _RenderGridProbe createRenderObject(BuildContext context) =>
      _RenderGridProbe();
}

class _RenderGridProbe extends RenderProxyBox {
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

Widget _page(String name) => _GridProbe(
  key: ValueKey(name),
  child: Scaffold(
    body: GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
      ),
      itemCount: 1000,
      itemBuilder: (_, i) => ColoredBox(
        color: Colors.primaries[i % Colors.primaries.length],
        child: Text('$name-$i'),
      ),
    ),
  ),
);

ScaleTransition _scale(WidgetTester tester, String name) => tester.widget(
  find
      .ancestor(
        of: find.byKey(ValueKey(name), skipOffstage: false),
        matching: find.byType(ScaleTransition, skipOffstage: false),
      )
      .first,
);

FadeTransition _fade(WidgetTester tester, String name) => tester.widget(
  find
      .ancestor(
        of: find.byKey(ValueKey(name), skipOffstage: false),
        matching: find.byType(FadeTransition, skipOffstage: false),
      )
      .first,
);

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester, {
  ValueNotifier<bool>? reduced,
  TextDirection direction = TextDirection.ltr,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('folder-host-surface'),
      child: MaterialApp(
        theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
        builder: (context, child) => Directionality(
          textDirection: direction,
          child: reduced == null
              ? child!
              : ValueListenableBuilder<bool>(
                  valueListenable: reduced,
                  builder: (context, value, _) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(disableAnimations: value),
                    child: child!,
                  ),
                ),
        ),
        home: Navigator(
          key: navigator,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => _page('root')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  testWidgets(
    'folder scale uses the platform filter policy and artwork stays live',
    (tester) async {
      final navigator = await _host(tester);
      final colour = ValueNotifier<Color>(Colors.blue);
      addTearDown(colour.dispose);
      final boundary = GlobalKey();
      final route = MediaLibraryFolderRoute<void>(
        builder: (_) => RepaintBoundary(
          key: boundary,
          child: ValueListenableBuilder<Color>(
            valueListenable: colour,
            builder: (_, value, _) =>
                ColoredBox(color: value, child: const SizedBox.expand()),
          ),
        ),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final scale = find
          .ancestor(
            of: find.byKey(boundary),
            matching: find.byType(ScaleTransition),
          )
          .first;
      final transform = find
          .descendant(of: scale, matching: find.byType(Transform))
          .first;
      expect(
        tester.widget<Transform>(transform).filterQuality,
        defaultTargetPlatform == TargetPlatform.android
            ? isNull
            : FilterQuality.low,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      colour.value = Colors.green;
      await tester.pump();
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('folder-host-surface')),
      );
      final image = render.toImageSync();
      final pixels = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final at = ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
      expect(
        Color.fromARGB(
          pixels.getUint8(at + 3),
          pixels.getUint8(at),
          pixels.getUint8(at + 1),
          pixels.getUint8(at + 2),
        ).toARGB32(),
        Colors.green.toARGB32(),
        reason: 'the painted scale must reflect late artwork',
      );
      image.dispose();
      await tester.pumpAndSettle();
      expect(
        tester.widget<Transform>(transform).filterQuality,
        isNull,
        reason: 'ordinary idle rendering must retain no bitmap transform',
      );
      expect(
        tester
            .widget<ColoredBox>(
              find.descendant(
                of: find.byKey(boundary),
                matching: find.byType(ColoredBox),
              ),
            )
            .color,
        Colors.green,
      );
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
  for (final hz in [60, 90, 120, 144]) {
    testWidgets(
      'root and nested folder motion is continuous at $hz Hz',
      (tester) async {
        final navigator = await _host(tester);
        final step = Duration(microseconds: (1000000 / hz).round());
        for (final name in ['A', 'B']) {
          final parent = tester.renderObject(
            find.byKey(ValueKey(name == 'A' ? 'root' : 'A')),
          );
          final transform = parent.getTransformTo(null).storage.toList();
          final route = MediaLibraryFolderRoute<void>(
            builder: (_) => _page(name),
          );
          navigator.currentState!.push(route);
          await tester.pump();
          expect(route.animation!.value, 0);
          expect(route.animation!.status, AnimationStatus.forward);
          var previous = _scale(tester, name).scale.value;
          expect(previous, greaterThan(0));
          var frames = 0;
          while (!route.animation!.isCompleted) {
            await tester.pump(step);
            final offset = _scale(tester, name).scale.value;
            expect(offset, inInclusiveRange(previous, 1.0));
            expect(parent.getTransformTo(null).storage, transform);
            previous = offset;
            expect(++frames, lessThan(hz));
          }
          expect(previous, 1);
        }
        for (final name in ['B', 'A']) {
          navigator.currentState!.pop();
          await tester.pump();
          var previous = _scale(tester, name).scale.value;
          var frames = 0;
          while (find.byKey(ValueKey(name)).evaluate().isNotEmpty) {
            final offset = _scale(tester, name).scale.value;
            expect(offset, lessThanOrEqualTo(previous));
            previous = offset;
            await tester.pump(step);
            expect(++frames, lessThan(hz));
          }
        }
        expect(find.text('root-0'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.all(),
    );
  }

  testWidgets(
    'grid skips prepainting and is retained once playback motion starts',
    (tester) async {
      final navigator = await _host(tester);
      final route = MediaLibraryFolderRoute<void>(builder: (_) => _page('A'));
      navigator.currentState!.push(route);
      await tester.pump();
      final probe = tester.renderObject<_RenderGridProbe>(
        find.byKey(const ValueKey('A')),
      );
      expect(probe.paints, 0);
      await tester.pump(const Duration(milliseconds: 16));
      expect(probe.paints, greaterThan(0));
      final layouts = probe.layouts;
      final paints = probe.paints;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(probe.layouts, layouts);
      expect(probe.paints, paints);
      expect(_fade(tester, 'A').opacity.value, 1);
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Back interrupts entry without changing the displayed offset or opacity',
    (tester) async {
      final navigator = await _host(tester);
      navigator.currentState!.push(
        MediaLibraryFolderRoute<void>(builder: (_) => _page('A')),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      final offset = _scale(tester, 'A').scale.value;
      final alpha = _fade(tester, 'A').opacity.value;
      navigator.currentState!.pop();
      await tester.pump();
      expect(_scale(tester, 'A').scale.value, offset);
      expect(_fade(tester, 'A').opacity.value, alpha);
      await tester.pumpAndSettle();
      expect(find.text('root-0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opaque child culls only covered parent paint and restores it on Back',
    (tester) async {
      final navigator = await _host(tester);
      final route = MediaLibraryFolderRoute<void>(builder: (_) => _page('A'));
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 90));
      final rootOpacity = find
          .ancestor(
            of: find.byKey(const ValueKey('root'), skipOffstage: false),
            matching: find.byType(Opacity, skipOffstage: false),
          )
          .first;
      expect(_fade(tester, 'A').opacity.value, 1);
      expect(tester.widget<Opacity>(rootOpacity).opacity, 0);
      final background = find
          .ancestor(
            of: find.byKey(const ValueKey('A')),
            matching: find.byType(ColoredBox),
          )
          .first;
      expect(tester.getRect(background), const Rect.fromLTWH(0, 0, 800, 600));
      await tester.pumpAndSettle();

      navigator.currentState!.push(
        MediaLibraryFolderRoute<void>(builder: (_) => _page('B')),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 90));
      final nestedOpacity = find
          .ancestor(
            of: find.byKey(const ValueKey('A'), skipOffstage: false),
            matching: find.byType(Opacity, skipOffstage: false),
          )
          .first;
      expect(_fade(tester, 'B').opacity.value, 1);
      expect(tester.widget<Opacity>(nestedOpacity).opacity, 0);
      navigator.currentState!.pop();
      await tester.pump();
      expect(tester.widget<Opacity>(nestedOpacity).opacity, 1);
      await tester.pumpAndSettle();

      navigator.currentState!.pop();
      await tester.pump();
      expect(tester.widget<Opacity>(rootOpacity).opacity, 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(route.animation!.status, AnimationStatus.reverse);
      expect(_fade(tester, 'A').opacity.value, greaterThan(0));
      expect(find.text('root-0'), findsOneWidget);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('late artwork still paints while the folder is entering', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final colour = ValueNotifier<Color>(Colors.black);
    addTearDown(colour.dispose);
    final route = MediaLibraryFolderRoute<void>(
      builder: (_) => _GridProbe(
        key: const ValueKey('A'),
        child: ValueListenableBuilder<Color>(
          valueListenable: colour,
          builder: (_, value, _) =>
              ColoredBox(color: value, child: const SizedBox.expand()),
        ),
      ),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    final probe = tester.renderObject<_RenderGridProbe>(
      find.byKey(const ValueKey('A')),
    );
    final paints = probe.paints;
    colour.value = Colors.green;
    await tester.pump();
    expect(probe.paints, greaterThan(paints));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(_fade(tester, 'A').opacity.value, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('leaving folder keeps live paint until the fade finishes', (
    tester,
  ) async {
    final navigator = await _host(tester);
    final colour = ValueNotifier<Color>(Colors.black);
    addTearDown(colour.dispose);
    final route = MediaLibraryFolderRoute<void>(
      builder: (_) => _GridProbe(
        key: const ValueKey('A'),
        child: ValueListenableBuilder<Color>(
          valueListenable: colour,
          builder: (_, value, _) =>
              ColoredBox(color: value, child: const SizedBox.expand()),
        ),
      ),
    );
    navigator.currentState!.push(route);
    await tester.pumpAndSettle();
    expect(route.allowSnapshotting, isTrue);
    final probe = tester.renderObject<_RenderGridProbe>(
      find.byKey(const ValueKey('A')),
    );
    navigator.currentState!.pop();
    await tester.pump();
    final paints = probe.paints;
    colour.value = Colors.blue;
    await tester.pump(const Duration(milliseconds: 16));
    expect(probe.paints, greaterThan(paints));
    expect(route.animation!.status, AnimationStatus.reverse);
    expect(_fade(tester, 'A').opacity.value, greaterThan(0));
    await tester.pumpAndSettle();
    expect(find.text('root-0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion and RTL retain the same mounted folder', (
    tester,
  ) async {
    final reduced = ValueNotifier(false);
    addTearDown(reduced.dispose);
    final navigator = await _host(
      tester,
      reduced: reduced,
      direction: TextDirection.rtl,
    );
    navigator.currentState!.push(
      MediaLibraryFolderRoute<void>(builder: (_) => _page('A')),
    );
    await tester.pump();
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('A')),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
    final element = tester.element(find.byKey(const ValueKey('A')));
    reduced.value = true;
    await tester.pump();
    final transform = find
        .descendant(
          of: find
              .ancestor(
                of: find.byKey(const ValueKey('A')),
                matching: find.byType(ScaleTransition),
              )
              .first,
          matching: find.byType(Transform),
        )
        .first;
    expect(tester.widget<Transform>(transform).filterQuality, isNull);
    expect(_scale(tester, 'A').scale.value, 1);
    expect(_fade(tester, 'A').opacity.value, 1);
    expect(tester.element(find.byKey(const ValueKey('A'))), same(element));
    await tester.pumpAndSettle();
  });

  test(
    'folder restore writes stay immediate and persistent without broadcasting',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      var notifications = 0;
      void changed() => notifications++;
      settings.addListener(changed);
      addTearDown(() {
        settings.removeListener(changed);
        settings.resetForTest();
      });
      final first = settings.saveMediaLibraryLastFolder('A');
      expect(settings.mediaLibraryLastFolderId, 'A');
      final second = settings.saveMediaLibraryLastFolder('B');
      expect(settings.mediaLibraryLastFolderId, 'B');
      await Future.wait([first, second]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mediaLibraryLastFolderId'), 'B');
      await settings.saveMediaLibraryLastFolder('');
      expect(settings.mediaLibraryLastFolderId, '');
      expect(prefs.getString('mediaLibraryLastFolderId'), '');
      expect(notifications, 0);
      await settings.updateSetting('mediaLibraryViewMode', 1);
      expect(notifications, 1);
    },
  );
}
