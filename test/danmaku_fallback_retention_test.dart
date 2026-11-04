import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

DanmakuItem _item(int index, {String? text}) => DanmakuItem(
  index: index,
  startTime: Duration(seconds: index),
  duration: const Duration(seconds: 60),
  text: text ?? 'comment $index',
  type: DanmakuType.top,
  colorValue: 0xffffffff,
  sourceY: 40,
);

DanmakuFallbackRetentionProbe _fallback() => DanmakuFallbackRetentionProbe(
  rasterize: (_, _, _) async =>
      throw StateError('injected atlas upload failure'),
);

Future<List<int>> _pixels(
  WidgetTester tester,
  DanmakuFallbackRetentionProbe probe,
  Map<int, Offset> items,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (final entry in items.entries) {
    probe.paint(canvas, entry.key, entry.value);
  }
  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(640, 240));
  try {
    final data = await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    return data!.buffer.asUint8List().toList();
  } finally {
    image!.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('advancing fallback windows release inactive native layouts', (
    tester,
  ) async {
    final probe = _fallback();
    addTearDown(probe.dispose);
    final active = _item(0);
    await tester.runAsync(() => probe.prepare([active]));
    expect(probe.usesFallback, isTrue);
    final activePainters = probe.paintersFor(0);
    List<TextPainter> previous = [];
    for (var window = 0; window < 80; window++) {
      final current = _item(window * 2 + 1);
      final upcoming = _item(window * 2 + 2);
      probe.retain(
        [current.index, upcoming.index],
        activeItems: [active.index],
      );
      await tester.runAsync(() => probe.prepare([current, upcoming]));
      expect(
        probe.itemCount,
        3,
        reason: 'window $window retains expired items',
      );
      expect(
        probe.layoutCount,
        3,
        reason: 'window $window retains expired layouts',
      );
      expect(activePainters.every((painter) => !painter.debugDisposed), isTrue);
      expect(previous.every((painter) => painter.debugDisposed), isTrue);
      previous = probe.paintersFor(current.index);
    }
    probe.dispose();
    expect(activePainters.every((painter) => painter.debugDisposed), isTrue);
    expect(previous.every((painter) => painter.debugDisposed), isTrue);
    expect(probe.itemCount, 0);
    expect(probe.layoutCount, 0);
  });

  testWidgets(
    'retained active and full runway paint identically after pruning',
    (tester) async {
      final probe = _fallback();
      addTearDown(probe.dispose);
      final expired = _item(1);
      final active = _item(2);
      final current = _item(3);
      final runway = [for (var i = 4; i < 48; i++) _item(i)];
      await tester.runAsync(
        () => probe.prepare([expired, active, current, ...runway]),
      );
      final removed = probe.paintersFor(expired.index);
      final kept = probe.paintersFor(active.index);
      final placements = <int, Offset>{
        active.index: const Offset(20, 20),
        current.index: const Offset(20, 65),
        runway.last.index: const Offset(20, 110),
      };
      final before = await _pixels(tester, probe, placements);
      expect(before.any((channel) => channel != 0), isTrue);
      final revision = probe.revision;
      probe.retain(
        [current.index, ...runway.map((item) => item.index)],
        activeItems: [active.index],
      );
      expect(probe.revision, greaterThan(revision));
      expect(probe.itemCount, 2 + runway.length);
      expect(removed.every((painter) => painter.debugDisposed), isTrue);
      expect(kept.every((painter) => !painter.debugDisposed), isTrue);
      for (final item in runway) {
        expect(probe.paintersFor(item.index), isNotEmpty);
      }
      expect(await _pixels(tester, probe, placements), equals(before));
    },
  );

  testWidgets('shared aliases release only their final retained reference', (
    tester,
  ) async {
    final probe = _fallback();
    addTearDown(probe.dispose);
    final first = _item(1, text: 'same\ntext');
    final alias = _item(2, text: 'same text');
    await tester.runAsync(() => probe.prepare([first, alias]));
    expect(probe.itemCount, 2);
    expect(probe.layoutCount, 1);
    final original = probe.paintersFor(first.index);
    expect(
      identical(original.first, probe.paintersFor(alias.index).first),
      isTrue,
    );
    probe.retain([alias.index]);
    expect(probe.itemCount, 1);
    expect(probe.layoutCount, 1);
    expect(original.every((painter) => !painter.debugDisposed), isTrue);
    probe.retain([]);
    expect(probe.itemCount, 0);
    expect(probe.layoutCount, 0);
    expect(original.every((painter) => painter.debugDisposed), isTrue);

    await tester.runAsync(() => probe.prepare([first, alias]));
    expect(probe.layoutCount, 1);
    final rebuilt = probe.paintersFor(first.index);
    expect(identical(original.first, rebuilt.first), isFalse);
    expect(
      identical(rebuilt.first, probe.paintersFor(alias.index).first),
      isTrue,
    );
    expect(rebuilt.every((painter) => !painter.debugDisposed), isTrue);
  });

  testWidgets('backward seek reconstructs released fallback at equal quality', (
    tester,
  ) async {
    final probe = _fallback();
    addTearDown(probe.dispose);
    final old = _item(1);
    final next = _item(20);
    await tester.runAsync(() => probe.prepare([old]));
    final before = await _pixels(tester, probe, {
      old.index: const Offset(20, 20),
    });
    final original = probe.paintersFor(old.index);
    probe.retain([next.index]);
    await tester.runAsync(() => probe.prepare([next]));
    expect(original.every((painter) => painter.debugDisposed), isTrue);
    probe.retain([old.index]);
    await tester.runAsync(() => probe.prepare([old]));
    expect(probe.itemCount, 1);
    expect(probe.layoutCount, 1);
    expect(
      identical(original.first, probe.paintersFor(old.index).first),
      isFalse,
    );
    expect(
      await _pixels(tester, probe, {old.index: const Offset(20, 20)}),
      equals(before),
    );
  });
}
