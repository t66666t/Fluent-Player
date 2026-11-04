import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_position.dart';
import 'package:video_player_app/utils/subtitle_position_geometry.dart';

void main() {
  test('alignment and origin round-trip inside a shifted viewport', () {
    final math.Random random = math.Random(7);
    for (int i = 0; i < 80; i++) {
      final Rect viewport = Rect.fromLTWH(
        random.nextDouble() * 40 - 10,
        random.nextDouble() * 30 - 5,
        200 + random.nextDouble() * 800,
        120 + random.nextDouble() * 500,
      );
      final Size content = Size(
        random.nextDouble() * viewport.width,
        random.nextDouble() * viewport.height,
      );
      final Alignment alignment = Alignment(
        random.nextDouble() * 2 - 1,
        random.nextDouble() * 2 - 1,
      );
      final SubtitleMoveSpace space = SubtitleMoveSpace.fromViewport(
        viewport,
        content,
      );
      final Offset origin = space.alignmentToOrigin(alignment);
      final Alignment back = space.originToAlignment(
        origin,
        preserved: alignment,
      );
      if (space.x.movable) {
        expect(back.x, closeTo(alignment.x, 1e-9));
      } else {
        expect(back.x, alignment.x);
      }
      if (space.y.movable) {
        expect(back.y, closeTo(alignment.y, 1e-9));
      } else {
        expect(back.y, alignment.y);
      }
      expect(origin.dx.isFinite, isTrue);
      expect(origin.dy.isFinite, isTrue);
    }
  });

  test('a fixed axis keeps its semantic value and rejects a zero divisor', () {
    const Rect viewport = Rect.fromLTWH(10, 20, 100, 80);
    final SubtitleMoveSpace space = SubtitleMoveSpace.fromViewport(
      viewport,
      const Size(100, 20),
    );
    expect(space.x.movable, isFalse);
    expect(space.y.movable, isTrue);
    const Alignment preserved = Alignment(-0.4, 0.2);
    final Offset origin = space.alignmentToOrigin(preserved);
    expect(origin.dx, viewport.left);
    final Alignment back = space.originToAlignment(origin, preserved: preserved);
    expect(back.x, -0.4);
    expect(back.y, closeTo(0.2, 1e-9));
  });

  test('non-finite input does not throw and stays finite', () {
    final SubtitleMoveSpace space = SubtitleMoveSpace.fromViewport(
      const Rect.fromLTWH(0, 0, 200, 100),
      const Size(40, 20),
    );
    final Offset origin = space.alignmentToOrigin(Alignment(double.nan, 0));
    expect(origin.dx.isFinite, isTrue);
    expect(origin.dy.isFinite, isTrue);
  });

  test('preset default inset is not applied again after it becomes custom', () {
    const Size viewport = Size(1280, 720);
    const Size content = Size(400, 80);
    final double inset = subtitleDebugPresets.first.bottomInset(viewport);
    final PresetLayoutDecision preset = resolvePresetSubtitleLayout(
      hasPreset: true,
      ghost: false,
      hasPositionOverride: false,
      requestedAlignment: Alignment.topCenter,
      presetBottomInset: inset,
    );
    final Offset presetOrigin = resolveSubtitleOverlayOffset(
      viewportSize: viewport,
      subtitleSize: content,
      alignment: preset.alignment,
      bottomInset: preset.bottomInset,
    );
    final SubtitleMoveSpace space = SubtitleMoveSpace.fromViewport(
      Offset.zero & viewport,
      content,
    );
    final Alignment custom = space.originToAlignment(presetOrigin);
    final Offset customOrigin = resolveSubtitleOverlayOffset(
      viewportSize: viewport,
      subtitleSize: content,
      alignment: custom,
      bottomInset: 0,
    );
    expect(customOrigin.dx, closeTo(presetOrigin.dx, 0.01));
    expect(customOrigin.dy, closeTo(presetOrigin.dy, 0.01));
  });

  test('every catalog preset keeps its default inset until an override exists', () {
    expect(subtitleDebugPresets, isNotEmpty);
    const Size viewport = Size(1280, 720);
    for (final SubtitleDebugPreset preset in subtitleDebugPresets) {
      final double inset = preset.bottomInset(viewport);
      expect(inset, greaterThan(0));
      final PresetLayoutDecision plain = resolvePresetSubtitleLayout(
        hasPreset: true,
        ghost: false,
        hasPositionOverride: false,
        requestedAlignment: Alignment.topLeft,
        presetBottomInset: inset,
      );
      expect(plain.alignment, Alignment.bottomCenter);
      expect(plain.bottomInset, inset);
      expect(plain.custom, isFalse);
      final PresetLayoutDecision custom = resolvePresetSubtitleLayout(
        hasPreset: true,
        ghost: false,
        hasPositionOverride: true,
        requestedAlignment: const Alignment(-0.2, 0.4),
        presetBottomInset: inset,
      );
      expect(custom.bottomInset, 0);
      expect(custom.alignment, const Alignment(-0.2, 0.4));
      final PresetLayoutDecision ghost = resolvePresetSubtitleLayout(
        hasPreset: true,
        ghost: true,
        hasPositionOverride: true,
        requestedAlignment: Alignment.topCenter,
        presetBottomInset: inset,
      );
      expect(ghost.bottomInset, 0);
      expect(ghost.custom, isFalse);
    }
  });
}
