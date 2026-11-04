import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

DanmakuItem _item(int index, int startSeconds) {
  return DanmakuItem(
    index: index,
    startTime: Duration(seconds: startSeconds),
    duration: const Duration(seconds: 6),
    text: '弹幕 $index',
    type: DanmakuType.scroll,
    colorValue: 0xFFFFFFFF,
    sourceY: 40,
  );
}

void main() {
  test('active range is found with binary-search boundaries', () {
    final items = <DanmakuItem>[for (var i = 0; i < 40; i++) _item(i, i)];

    final normal = resolveDanmakuActiveRange(
      items,
      positionUs: const Duration(seconds: 20).inMicroseconds,
      speed: 1,
    );
    expect(normal.start, 0);
    expect(normal.endExclusive, 21);

    final fast = resolveDanmakuActiveRange(
      items,
      positionUs: const Duration(seconds: 20).inMicroseconds,
      speed: 2,
    );
    expect(fast.start, 0);
    expect(fast.endExclusive, 21);
  });

  test('prefetch keeps a 640-item active burst available for the atlas', () {
    final items = <DanmakuItem>[for (var i = 0; i < 1000; i++) _item(i, 10)];

    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: const Duration(seconds: 10).inMicroseconds,
      speed: 1,
    );

    expect(indices, hasLength(640));
    expect(indices.first, 999);
    expect(indices.last, 360);
  });

  test('prefetch includes a ten-second upcoming window', () {
    final items = <DanmakuItem>[for (var i = 0; i < 30; i++) _item(i, i)];

    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: const Duration(seconds: 10).inMicroseconds,
      speed: 1,
    );

    expect(indices, containsAll(<int>[11, 12, 13, 14, 15, 16, 17, 18, 19, 20]));
    expect(indices, isNot(contains(21)));
  });

  test('lower source tracks remain eligible for compact-area repacking', () {
    final items = <DanmakuItem>[
      for (var i = 0; i < 30; i++)
        DanmakuItem(
          index: i,
          startTime: Duration(seconds: i < 20 ? 10 : 11),
          duration: const Duration(seconds: 6),
          text: 'comment $i',
          type: DanmakuType.scroll,
          colorValue: 0xFFFFFFFF,
          sourceY: i.isEven ? 0 : 1000,
        ),
    ];
    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: 10000000,
      speed: 1,
      maximumActiveItems: 3,
      maximumUpcomingItems: 2,
      includeItem: (item) => danmakuLaneIntersectsViewport(
        item,
        viewportHeight: 600,
        displayArea: .25,
        fontSize: 30,
      ),
    );
    expect(indices, [19, 18, 17, 20, 21]);
  });

  test('prefetch work stays bounded for a pathological hidden burst', () {
    final items = <DanmakuItem>[for (var i = 0; i < 50000; i++) _item(i, 10)];
    var examined = 0;
    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: 10000000,
      speed: 1,
      includeItem: (_) {
        examined++;
        return false;
      },
    );
    expect(indices, isEmpty);
    expect(examined, lessThan(20000));
  });

  for (final type in DanmakuType.values) {
    test('source $type lanes are repacked into both small and large areas', () {
      final item = DanmakuItem(
        index: 0,
        startTime: Duration.zero,
        duration: const Duration(seconds: 6),
        text: 'comment',
        type: type,
        colorValue: 0xFFFFFFFF,
        sourceY: type == DanmakuType.bottom ? 880 : 200,
      );
      bool intersects(double area) => danmakuLaneIntersectsViewport(
        item,
        viewportHeight: 600,
        displayArea: area,
        fontSize: 30,
      );
      expect(intersects(.25), isTrue);
      expect(intersects(1), isTrue);
      expect(intersects(.01), isFalse);
    });
  }

  test('prefetch rounds future work to a stable five-second atlas segment', () {
    final items = <DanmakuItem>[for (var i = 0; i < 40; i++) _item(i, i)];

    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: const Duration(seconds: 11).inMicroseconds,
      speed: 1,
    );

    // 11s + 10s look-ahead is rounded to the end of the 20-25s segment,
    // so the entire segment is rasterized as a page instead of one tiny page
    // per subsequent maintenance tick.
    expect(indices, contains(25));
    expect(indices, isNot(contains(26)));
  });

  test('scroll duration scales with viewport width and speed multiplier', () {
    final item = _item(0, 0);

    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 1,
        viewportWidth: 1920,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 32).inMicroseconds,
    );
    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 1,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 64).inMicroseconds,
    );
    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 2,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 32).inMicroseconds,
    );
  });

  test('narrow stage keeps pixel velocity and exits sooner', () {
    final scroll = _item(0, 0);

    expect(resolveDanmakuScreenMotionAnchor(const Size(390, 844)), 844);
    expect(resolveDanmakuScreenMotionAnchor(const Size(844, 390)), 844);
    expect(
      resolveDanmakuMotionWidth(
        viewportWidth: 390,
        referenceWidth: 1920,
        motionAnchorWidth: 844,
      ),
      844,
    );
    // A half-width track takes half the time at the same pixel velocity,
    // which is what a sidebar or a portrait band does to the live width.
    expect(
      resolveDanmakuDurationUs(
        scroll,
        speed: 1,
        viewportWidth: 960,
        referenceWidth: 1920,
        motionAnchorWidth: 1920,
      ),
      const Duration(seconds: 16).inMicroseconds,
    );
    expect(
      resolveDanmakuDurationUs(
        scroll,
        speed: 1,
        viewportWidth: 1920,
        referenceWidth: 1920,
        motionAnchorWidth: 1920,
      ),
      const Duration(seconds: 32).inMicroseconds,
    );

    final top = DanmakuItem(
      index: scroll.index,
      startTime: scroll.startTime,
      duration: scroll.duration,
      text: scroll.text,
      type: DanmakuType.top,
      colorValue: scroll.colorValue,
      sourceY: scroll.sourceY,
    );
    expect(
      resolveDanmakuDurationUs(
        top,
        speed: 1,
        viewportWidth: 960,
        referenceWidth: 1920,
        motionAnchorWidth: 3840,
      ),
      const Duration(seconds: 6).inMicroseconds,
    );

    final activeSet = DanmakuActiveSet(<DanmakuItem>[scroll]);
    expect(
      activeSet.update(
        positionUs: const Duration(seconds: 4).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
        viewportWidth: 960,
        referenceWidth: 1920,
        motionAnchorWidth: 1920,
      ),
      <int>[0],
    );
  });

  test('fixed danmaku dwell time does not scale with viewport width', () {
    final source = _item(0, 0);
    final item = DanmakuItem(
      index: source.index,
      startTime: source.startTime,
      duration: source.duration,
      text: source.text,
      type: DanmakuType.top,
      colorValue: source.colorValue,
      sourceY: source.sourceY,
    );

    expect(
      resolveDanmakuDurationUs(
        item,
        speed: 1,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      const Duration(seconds: 6).inMicroseconds,
    );

    final activeSet = DanmakuActiveSet(<DanmakuItem>[item]);
    expect(
      activeSet.update(
        positionUs: const Duration(seconds: 5).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
        viewportWidth: 320,
        referenceWidth: 1920,
      ),
      <int>[0],
    );
  });

  test('wide viewport keeps scrolling items active for the longer travel', () {
    final activeSet = DanmakuActiveSet(<DanmakuItem>[_item(0, 10)]);

    expect(
      activeSet.update(
        positionUs: const Duration(seconds: 17).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
        viewportWidth: 3840,
        referenceWidth: 1920,
      ),
      <int>[0],
    );
  });

  test('atlas keeps horizontal motion continuous and aligns static lanes', () {
    final first = resolveDanmakuAtlasDestination(10.30, 10.3, 1.25);
    final second = resolveDanmakuAtlasDestination(10.34, 10.3, 1.25);

    expect(first.dx, closeTo(10.30, 0.0001));
    expect(second.dx, closeTo(10.34, 0.0001));
    expect(first.dy, closeTo(10.4, 0.0001));
    expect(
      resolveDanmakuAtlasDestination(
        10.3,
        10.3,
        1.25,
        continuousHorizontal: false,
      ).dx,
      closeTo(10.4, 0.0001),
    );
    expect(resolveDanmakuAtlasDestination(10.3, 10.3, double.nan).dy, 10);
  });

  test('prefetch rasterizes comments already on screen before the runway', () {
    final items = <DanmakuItem>[for (var i = 0; i < 30; i++) _item(i, i)];

    final indices = resolveDanmakuPrefetchIndices(
      items,
      positionUs: const Duration(seconds: 10).inMicroseconds,
      speed: 1,
      maximumActiveItems: 2,
      maximumUpcomingItems: 3,
      lookAheadUs: const Duration(seconds: 5).inMicroseconds,
      atlasSegmentUs: const Duration(seconds: 1).inMicroseconds,
    );

    expect(indices, <int>[10, 9, 11, 12, 13]);
  });

  test('an asset which misses entry is suppressed instead of popping in', () {
    final gate = DanmakuAssetAdmissionGate();
    gate.beginFrame(const Duration(seconds: 10).inMicroseconds);
    expect(
      gate.shouldPaint(itemIndex: 7, assetReady: false, atEntry: true),
      isFalse,
    );

    gate.beginFrame(
      const Duration(seconds: 10, milliseconds: 16).inMicroseconds,
    );
    expect(
      gate.shouldPaint(itemIndex: 7, assetReady: true, atEntry: true),
      isFalse,
    );

    // A large forward step can be a dropped frame at a high playback rate. It
    // must not revive a sprite in the middle of the same trajectory.
    gate.beginFrame(const Duration(seconds: 13).inMicroseconds);
    expect(
      gate.shouldPaint(itemIndex: 7, assetReady: true, atEntry: true),
      isFalse,
    );

    gate.beginFrame(const Duration(seconds: 3).inMicroseconds);
    expect(
      gate.shouldPaint(itemIndex: 7, assetReady: true, atEntry: true),
      isTrue,
    );
  });

  test('a comment already in flight is shown once its glyph arrives', () {
    final gate = DanmakuAssetAdmissionGate();
    gate.beginFrame(const Duration(seconds: 10).inMicroseconds);
    expect(
      gate.shouldPaint(itemIndex: 7, assetReady: false, atEntry: false),
      isFalse,
    );

    gate.beginFrame(
      const Duration(seconds: 10, milliseconds: 16).inMicroseconds,
    );
    expect(
      gate.shouldPaint(itemIndex: 7, assetReady: true, atEntry: false),
      isTrue,
    );
  });

  test(
    'a cold atlas does not blacklist comments that are waiting for glyphs',
    () {
      final gate = DanmakuAssetAdmissionGate();
      gate.reset();
      gate.beginFrame(const Duration(seconds: 10).inMicroseconds);
      expect(
        gate.shouldPaint(itemIndex: 7, assetReady: false, atEntry: true),
        isFalse,
      );
      expect(
        gate.shouldPaint(itemIndex: 7, assetReady: true, atEntry: true),
        isTrue,
      );

      gate.resumeEntrySuppression();
      expect(
        gate.shouldPaint(itemIndex: 8, assetReady: false, atEntry: true),
        isFalse,
      );
      expect(
        gate.shouldPaint(itemIndex: 8, assetReady: true, atEntry: true),
        isFalse,
      );
    },
  );

  test('entry grace stays on the leading edge of the track', () {
    expect(danmakuAssetMissIsEntry(0, 8000000), isTrue);
    expect(danmakuAssetMissIsEntry(200000, 8000000), isTrue);
    expect(danmakuAssetMissIsEntry(500000, 8000000), isFalse);
  });

  test('lowering the overload cap immediately trims an active burst', () {
    final items = <DanmakuItem>[for (var i = 0; i < 1000; i++) _item(i, 10)];
    final activeSet = DanmakuActiveSet(items);

    expect(
      activeSet.update(
        positionUs: const Duration(seconds: 11).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
      ),
      hasLength(1000),
    );

    final trimmed = activeSet.update(
      positionUs: const Duration(seconds: 11, milliseconds: 16).inMicroseconds,
      speed: 1,
      admissionCap: 200,
    );
    expect(trimmed, hasLength(200));
    expect(trimmed, orderedEquals(List<int>.of(trimmed)..sort()));
  });

  test('overload trimming prefers unique text and remains deterministic', () {
    final items = <DanmakuItem>[
      for (var i = 0; i < 20; i++)
        DanmakuItem(
          index: i,
          startTime: const Duration(seconds: 10),
          duration: const Duration(seconds: 6),
          text: i < 10 ? '重复' : '弹幕 $i',
          type: DanmakuType.scroll,
          colorValue: 0xFFFFFFFF,
          sourceY: 40,
        ),
    ];

    List<int> resolve() {
      final activeSet = DanmakuActiveSet(items);
      activeSet.update(
        positionUs: const Duration(seconds: 11).inMicroseconds,
        speed: 1,
        admissionCap: 0x3fffffff,
      );
      return List<int>.of(
        activeSet.update(
          positionUs: const Duration(
            seconds: 11,
            milliseconds: 16,
          ).inMicroseconds,
          speed: 1,
          admissionCap: 8,
        ),
      );
    }

    final first = resolve();
    final second = resolve();
    expect(first, second);
    expect(first.map((index) => items[index].text).toSet(), hasLength(8));
  });
}
