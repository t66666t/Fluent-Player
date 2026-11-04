import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/subtitle_position_geometry.dart';

void main() {
  const Rect viewport = Rect.fromLTWH(0, 0, 400, 300);
  const Size content = Size(80, 40);

  SubtitleDragSample drag(Offset pointer, Offset grab, SubtitleSnapMemory memory) {
    return sampleSubtitleDrag(
      pointerLocal: pointer,
      grab: grab,
      memory: memory,
      viewport: viewport,
      content: content,
    );
  }

  test('free movement matches the pointer on both axes', () {
    const Offset origin = Offset(40, 40);
    const Offset pointer = Offset(70, 60);
    final Offset grab = pointer - origin;
    const Offset steps = Offset(10, 6);
    SubtitleSnapMemory memory = const SubtitleSnapMemory();
    Offset cursor = pointer;
    Offset expected = origin;
    for (int i = 0; i < 6; i++) {
      cursor += steps;
      expected += steps;
      final SubtitleDragSample sample = drag(cursor, grab, memory);
      memory = sample.memory;
      expect(sample.displayOrigin.dx, closeTo(expected.dx, 0.01));
      expect(sample.displayOrigin.dy, closeTo(expected.dy, 0.01));
    }
  });

  test('slow 1px steps leave the center after the release distance', () {
    final Offset centered = Offset(
      (viewport.width - content.width) / 2,
      (viewport.height - content.height) / 2,
    );
    Offset pointer = centered + Offset(content.width / 2, content.height / 2);
    final Offset grab = pointer - centered;
    SubtitleSnapMemory memory = const SubtitleSnapMemory();
    bool left = false;
    for (int i = 0; i < 20; i++) {
      pointer += const Offset(1, 0);
      final SubtitleDragSample sample = drag(pointer, grab, memory);
      memory = sample.memory;
      if (!sample.snappedX) {
        left = true;
        expect(sample.displayOrigin.dx, greaterThan(centered.dx));
        break;
      }
    }
    expect(left, isTrue);
    expect(memory.capturedX, isFalse);
  });

  test('a fast jump across the center is not pulled back', () {
    const Offset origin = Offset(10, 130);
    const Offset pointer = Offset(40, 150);
    final Offset grab = pointer - origin;
    final SubtitleDragSample sample = drag(
      pointer + const Offset(300, 0),
      grab,
      const SubtitleSnapMemory(),
    );
    expect(sample.snappedX, isFalse);
    expect(sample.displayOrigin.dx, closeTo(origin.dx + 300, 0.01));
  });

  test('crossing the edge by 200px then reversing 1px moves at once', () {
    const Offset origin = Offset(10, 20);
    Offset pointer = const Offset(30, 40);
    Offset grab = pointer - origin;
    SubtitleSnapMemory memory = const SubtitleSnapMemory();
    final SubtitleDragSample out = drag(pointer + const Offset(800, 0), grab, memory);
    expect(out.displayOrigin.dx, closeTo(viewport.width - content.width, 0.01));
    pointer += const Offset(800, 0);
    grab = out.grab;
    memory = out.memory;
    final SubtitleDragSample back = drag(pointer + const Offset(-1, 0), grab, memory);
    expect(back.displayOrigin.dx, closeTo(out.displayOrigin.dx - 1, 0.01));

    final SubtitleDragSample down = drag(
      pointer + const Offset(0, 800),
      out.grab,
      out.memory,
    );
    expect(down.displayOrigin.dy, closeTo(viewport.height - content.height, 0.01));
    final SubtitleDragSample up = drag(
      pointer + const Offset(0, 799),
      down.grab,
      down.memory,
    );
    expect(up.displayOrigin.dy, closeTo(down.displayOrigin.dy - 1, 0.01));
  });
}
