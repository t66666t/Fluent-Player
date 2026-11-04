import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/music_backdrop_surface.dart';

const _snapshotKey = ValueKey('music-backdrop-snapshot');

class _Backdrop extends CustomPainter {
  _Backdrop(this.color);
  final Color color;
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, bounds.bottomRight, [
          color,
          const Color(0xFF121217),
        ]),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.radial(size.center(Offset.zero), size.width, [
          const Color(0x00000000),
          const Color(0x59000000),
        ]),
    );
  }

  @override
  bool shouldRepaint(_Backdrop oldDelegate) => oldDelegate.color != color;
}

Widget _host(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

Future<void> _finishCapture(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pump();
}

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async =>
    (await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;

void main() {
  testWidgets('waits for decoded artwork and its complete fade', (
    tester,
  ) async {
    final ready = ValueNotifier<Object?>(null);
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      _host(
        MusicBackdropSurface(
          contentKey: 'artwork',
          ready: ready,
          child: const ColoredBox(color: Color(0xFF342121)),
        ),
      ),
    );
    await _finishCapture(tester);
    expect(find.byKey(_snapshotKey), findsNothing);
    ready.value = 'artwork';
    await tester.pump(const Duration(milliseconds: 699));
    expect(find.byKey(_snapshotKey), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(find.byKey(_snapshotKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'keeps cached pixels through foreground frames and preserves color',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(384, 240));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey();
      final backdrop = _Backdrop(const Color(0xFF543038));
      final foreground = ValueNotifier(0);
      addTearDown(foreground.dispose);
      await tester.pumpWidget(
        _host(
          RepaintBoundary(
            key: key,
            child: Stack(
              fit: StackFit.expand,
              children: [
                MusicBackdropSurface(
                  contentKey: 'one',
                  child: CustomPaint(painter: backdrop),
                ),
                ValueListenableBuilder<int>(
                  valueListenable: foreground,
                  builder: (context, value, child) => Positioned(
                    left: value.toDouble(),
                    top: 0,
                    width: 2,
                    height: 2,
                    child: const ColoredBox(color: Color(0xFFFFFFFF)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      final before = await _pixels(tester, key);
      await _finishCapture(tester);
      final after = await _pixels(tester, key);
      expect(after.length, before.length);
      var maxDelta = 0;
      var sum = 0;
      for (var i = 0; i < before.length; i++) {
        final delta = (before[i] - after[i]).abs();
        if (delta > maxDelta) maxDelta = delta;
        sum += delta;
      }
      expect(maxDelta, lessThanOrEqualTo(3));
      expect(sum / before.length, lessThan(0.5));
      final paints = backdrop.paints;
      for (var i = 1; i <= 144; i++) {
        foreground.value = i;
        await tester.pump(const Duration(microseconds: 6944));
      }
      expect(backdrop.paints, paints);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('track and viewport changes discard old snapshots', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(384, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late StateSetter update;
    var content = 'red';
    var pixelRatio = 2.5;
    final ready = ValueNotifier<Object?>('red');
    addTearDown(ready.dispose);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MediaQuery(
              data: MediaQueryData(devicePixelRatio: pixelRatio),
              child: MusicBackdropSurface(
                contentKey: content,
                ready: ready,
                child: ColoredBox(
                  color: content == 'red'
                      ? const Color(0xFF441111)
                      : const Color(0xFF114411),
                ),
              ),
            );
          },
        ),
      ),
    );
    await _finishCapture(tester);
    final old = tester.widget<RawImage>(find.byKey(_snapshotKey)).image;
    update(() => content = 'green');
    await tester.pump();
    expect(find.byKey(_snapshotKey), findsNothing);
    await _finishCapture(tester);
    expect(find.byKey(_snapshotKey), findsNothing);
    ready.value = 'green';
    await _finishCapture(tester);
    expect(
      tester.widget<RawImage>(find.byKey(_snapshotKey)).image,
      isNot(same(old)),
    );
    await tester.binding.setSurfaceSize(const Size(240, 384));
    await tester.pump();
    expect(find.byKey(_snapshotKey), findsNothing);
    await _finishCapture(tester);
    final portrait = tester.widget<RawImage>(find.byKey(_snapshotKey)).image!;
    expect(portrait.width, 600);
    expect(portrait.height, 960);
    update(() => pixelRatio = 1.5);
    await tester.pump();
    expect(find.byKey(_snapshotKey), findsNothing);
    await _finishCapture(tester);
    final scaled = tester.widget<RawImage>(find.byKey(_snapshotKey)).image!;
    expect(scaled.width, 360);
    expect(scaled.height, 576);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('large backdrops keep the texture memory bounded', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(4096, 2160));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _host(
        const MusicBackdropSurface(
          contentKey: 'large',
          child: ColoredBox(color: Color(0xFF222222)),
        ),
      ),
    );
    await _finishCapture(tester);
    final image = tester.widget<RawImage>(find.byKey(_snapshotKey)).image!;
    expect(image.width, lessThanOrEqualTo(4096));
    expect(image.width * image.height, lessThanOrEqualTo(8410000));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden and disposed pages schedule no new captures', (
    tester,
  ) async {
    late StateSetter update;
    var visible = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return TickerMode(
              enabled: visible,
              child: const MusicBackdropSurface(
                contentKey: 'hidden',
                child: ColoredBox(color: Color(0xFF222222)),
              ),
            );
          },
        ),
      ),
    );
    await _finishCapture(tester);
    expect(find.byKey(_snapshotKey), findsNothing);
    update(() => visible = true);
    await tester.pump();
    await _finishCapture(tester);
    expect(find.byKey(_snapshotKey), findsOneWidget);
    await tester.pumpWidget(
      _host(
        const MusicBackdropSurface(
          contentKey: 'pending',
          child: ColoredBox(color: Color(0xFF333333)),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
