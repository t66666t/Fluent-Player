import 'package:flutter/material.dart';

import 'subtitle_style.dart';

/// A trial profile, separate from the shipped defaults and existing settings.
abstract final class RecommendedSubtitleDefaults {
  static const textStyle = SubtitleTextStyle(
    defaultFontFamily: 'Swei Gothic CJK SC',
    defaultFontWeight: 700,
    languageFonts: {},
    fontFamilyChinese: 'Swei Gothic CJK SC',
    fontFamilyEnglish: 'Swei Gothic CJK SC',
    fontWeightChinese: FontWeight.w700,
    fontWeightEnglish: FontWeight.w700,
    textColor: Colors.white,
    hasBorder: true,
    borderColor: Colors.black,
    borderWidth: 4.0,
    hasShadow: true,
    shadowColor: Colors.black,
    shadowBlur: 3.5,
    shadowOffset: Offset(2.5, 2.5),
    backgroundEnabled: true,
    backgroundColor: Colors.black,
    backgroundOpacity: .9,
  );

  // Both modes start with the same 30/25 size pair. Actual glyph sizes follow
  // the viewport; subsequent user changes remain multiplicative.
  static const layout = SubtitleLayoutStyle(
    balancedScreenSizing: true,
    overallScale: 1,
    fontSize: kDefaultSubtitleFontSize,
    secondaryFontSize: kDefaultSecondarySubtitleFontSize,
    lineSpacing: 2,
    letterSpacing: 0,
  );
  static const ordinaryAlignment = Alignment(0, .82);
  static const ghostAlignment = Alignment(0, .84);
  static const audioAlignment = Alignment(0, .80);
}
