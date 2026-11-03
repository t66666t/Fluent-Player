import 'dart:math' as math;

import 'package:flutter/material.dart';

/// User-facing adjustment limits for the core danmaku presentation controls.
///
/// Keep these values shared by persistence, the settings UI, and rendering so
/// an extreme value selected by the user is not silently narrowed elsewhere.
const double kDanmakuDisplayAreaMin = 0.01;
const double kDanmakuDisplayAreaMax = 1.0;
const double kDanmakuFontScaleMin = 0.2;
const double kDanmakuFontScaleMax = 4.0;
const double kDanmakuSpeedMin = 0.05;
const double kDanmakuSpeedMax = 16.0;
const double kDanmakuDensityMin = 0.1;
const double kDanmakuDensityMax = 1.0;
const String kDanmakuDefaultFontFamily = 'Noto Sans SC';
const int kDanmakuDefaultFontWeight = 700;
const double kDanmakuPortraitDisplayArea = 0.25;
const double kDanmakuPortraitFontScale = 1.0;
const double kDanmakuPortraitSpeed = 1.0;
const double kDanmakuPortraitDensity = 0.5;

/// The playback page owns the profile, independently of device rotation or
/// the aspect ratio of the video inside that page.
enum DanmakuPresentationMode { portrait, landscape }

extension DanmakuPresentationModeX on DanmakuPresentationMode {
  String get label => switch (this) {
    DanmakuPresentationMode.portrait => '竖屏播放页',
    DanmakuPresentationMode.landscape => '横屏播放页',
  };
}

/// Logical pixels, independent of a short video band, sidebars and pixel ratio.
/// Ordinary 320–480px phones get a 14–16px base; larger devices grow gently.
double resolvePortraitDanmakuBaseFontSize(Size screenSize) {
  final shortSide = screenSize.shortestSide;
  if (!screenSize.width.isFinite ||
      !screenSize.height.isFinite ||
      shortSide <= 0) {
    return 15;
  }
  return (15 * math.pow(shortSide / 390, .35)).clamp(14.0, 20.0).toDouble();
}

/// Maps the wide speed range onto a usable slider. A logarithmic scale gives
/// slow, normal and fast multipliers comparable physical travel on the track
/// instead of squeezing every commonly used slow value against the left edge.
double danmakuSpeedToSlider(double speed) {
  final normalized = speed.clamp(kDanmakuSpeedMin, kDanmakuSpeedMax).toDouble();
  return math.log(normalized / kDanmakuSpeedMin) /
      math.log(kDanmakuSpeedMax / kDanmakuSpeedMin);
}

double danmakuSpeedFromSlider(double sliderValue) {
  final position = sliderValue.clamp(0.0, 1.0).toDouble();
  return kDanmakuSpeedMin *
      math.pow(kDanmakuSpeedMax / kDanmakuSpeedMin, position).toDouble();
}

/// Turns the user-facing danmaku speed into the media-time multiplier.
///
/// Danmaku is driven by the player position clock, which already advances at
/// the current playback rate. Dividing by a locked rate makes that locked rate
/// behave like 1x on screen, without touching the overlay animation clock.
/// Unlocked playback, or a disabled setting, must keep the slider value as-is
/// even if a leftover lock speed is still stored.
double resolveDanmakuSpeedWithLockedPlaybackBaseline({
  required double sliderSpeed,
  required bool useLockedPlaybackAsBaseline,
  required bool isPlaybackSpeedLocked,
  required double lockedPlaybackSpeed,
}) {
  if (!sliderSpeed.isFinite || sliderSpeed <= 0) {
    return 1.0;
  }
  if (!useLockedPlaybackAsBaseline || !isPlaybackSpeedLocked) {
    return sliderSpeed;
  }
  final baseline = lockedPlaybackSpeed;
  if (!baseline.isFinite || baseline <= 0) {
    return sliderSpeed;
  }
  final mediaSpeed = sliderSpeed / baseline;
  if (!mediaSpeed.isFinite || mediaSpeed <= 0) {
    return sliderSpeed;
  }
  return mediaSpeed;
}

/// Font families bundled by the application. `null` keeps Flutter's current
/// default font, which is also the historical danmaku appearance.
const List<String?> kDanmakuFontFamilies = <String?>[
  null,
  'MiSans',
  'Noto Sans SC',
  'Noto Serif CJK SC',
  'Swei Gothic CJK SC',
  'Comic Relief',
  'Roboto',
  'Inter',
  'Brawler',
];

String danmakuFontFamilyLabel(String? family) => family ?? '当前默认字体';

enum DanmakuOutlineType { standard, thin, heavy, projection, none, shadow }

extension DanmakuOutlineTypeX on DanmakuOutlineType {
  String get label => switch (this) {
    DanmakuOutlineType.none => '纯文字',
    DanmakuOutlineType.shadow => '柔和阴影',
    DanmakuOutlineType.standard => '标准描边',
    DanmakuOutlineType.thin => '细描边',
    DanmakuOutlineType.heavy => '粗描边',
    DanmakuOutlineType.projection => '45°投影',
  };

  String get description => switch (this) {
    DanmakuOutlineType.none => '无描边',
    DanmakuOutlineType.shadow => '轻投影',
    DanmakuOutlineType.standard => '经典清晰',
    DanmakuOutlineType.thin => '更轻巧',
    DanmakuOutlineType.heavy => '强对比',
    DanmakuOutlineType.projection => '立体感',
  };

  static DanmakuOutlineType fromName(String value) {
    return DanmakuOutlineType.values.firstWhere(
      (item) => item.name == value,
      orElse: () => DanmakuOutlineType.standard,
    );
  }
}

FontWeight danmakuFontWeight(int value) {
  final normalized = (value.clamp(100, 900) ~/ 100) * 100;
  return FontWeight.values[(normalized ~/ 100) - 1];
}

/// Outline thickness as a fraction of the font size.
///
/// The ASS source uses a 2px outline on a 40px font. Keeping a ratio, with no
/// logical-pixel floor, means a short portrait glyph stays the same weight as
/// that glyph on a tall stage. A floor such as 1.2px makes small text look
/// several times heavier.
double danmakuOutlineWidthRatio(DanmakuOutlineType type) {
  return switch (type) {
    DanmakuOutlineType.none || DanmakuOutlineType.shadow => 0,
    DanmakuOutlineType.standard => 0.075,
    DanmakuOutlineType.thin => 0.042,
    DanmakuOutlineType.heavy => 0.12,
    DanmakuOutlineType.projection => 0.025,
  };
}

/// Stroke width in logical pixels for [fontSize].
double resolveDanmakuOutlineWidth(DanmakuOutlineType type, double fontSize) {
  return fontSize * danmakuOutlineWidthRatio(type);
}

/// 45° shadow offset. Only the projection style draws one, at a tenth of the
/// font size, so the shadow shrinks with the glyphs instead of staying a
/// fixed pixel stub on small text.
double resolveDanmakuProjectionDistance(
  DanmakuOutlineType type,
  double fontSize,
) {
  if (type == DanmakuOutlineType.shadow) return fontSize * 0.06;
  if (type != DanmakuOutlineType.projection) return 0;
  return fontSize * 0.1;
}

/// Blur radius for the soft-shadow preset, shared by preview and atlas paint.
double resolveDanmakuShadowBlur(DanmakuOutlineType type, double fontSize) =>
    type == DanmakuOutlineType.shadow ? fontSize * 0.06 : 0;
