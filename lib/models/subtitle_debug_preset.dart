import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'subtitle_style.dart';
import '../utils/subtitle_layout.dart';

/// Original, commercially usable alternatives inspired by documented practice;
/// these are not claimed to be a group's official or most popular settings.
class SubtitleDebugPreset {
  final String id, name, category, description;
  final String primaryFont, secondaryFont;
  final int primaryWeight, secondaryWeight;
  final double size, ratio, outline, gap, bottom, width, box;
  final Color color, secondaryColor;
  final bool secondaryFirst;
  final double textScale, shadowBlur, backgroundPadding;
  final bool shadowEnabled;
  final Color backgroundColor, borderColor, shadowColor;
  final Offset shadowOffset;
  const SubtitleDebugPreset({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    this.primaryFont = 'Noto Sans SC',
    this.secondaryFont = 'Inter',
    this.primaryWeight = 500,
    this.secondaryWeight = 500,
    this.size = 32,
    this.ratio = .68,
    this.outline = 2.4,
    this.gap = 3,
    this.bottom = .045,
    this.width = .9,
    this.box = 0,
    this.color = Colors.white,
    this.secondaryColor = const Color(0xFFECECEC),
    this.secondaryFirst = false,
    this.textScale = 1,
    this.shadowEnabled = true,
    this.shadowBlur = 1.1,
    this.shadowOffset = const Offset(.65, .85),
    this.shadowColor = Colors.black,
    this.borderColor = Colors.black,
    this.backgroundColor = Colors.black,
    double? backgroundPadding,
  }) : backgroundPadding = backgroundPadding ?? (box > 0 ? 4 : 0);

  SubtitleDebugPreset copyWith({
    double? textScale,
    double? outline,
    double? box,
    Color? color,
    Color? secondaryColor,
    Color? backgroundColor,
    Color? borderColor,
    Color? shadowColor,
    bool? shadowEnabled,
    double? shadowBlur,
    Offset? shadowOffset,
  }) => SubtitleDebugPreset(
    id: id,
    name: name,
    category: category,
    description: description,
    primaryFont: primaryFont,
    secondaryFont: secondaryFont,
    primaryWeight: primaryWeight,
    secondaryWeight: secondaryWeight,
    size: size,
    ratio: ratio,
    gap: gap,
    bottom: bottom,
    width: width,
    backgroundPadding: backgroundPadding,
    secondaryFirst: secondaryFirst,
    textScale: textScale ?? this.textScale,
    outline: outline ?? this.outline,
    box: box ?? this.box,
    color: color ?? this.color,
    secondaryColor: secondaryColor ?? this.secondaryColor,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    borderColor: borderColor ?? this.borderColor,
    shadowColor: shadowColor ?? this.shadowColor,
    shadowEnabled: shadowEnabled ?? this.shadowEnabled,
    shadowBlur: shadowBlur ?? this.shadowBlur,
    shadowOffset: shadowOffset ?? this.shadowOffset,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'description': description,
    'primaryFont': primaryFont,
    'secondaryFont': secondaryFont,
    'primaryWeight': primaryWeight,
    'secondaryWeight': secondaryWeight,
    'size': size,
    'ratio': ratio,
    'gap': gap,
    'bottom': bottom,
    'width': width,
    'backgroundPadding': backgroundPadding,
    'secondaryFirst': secondaryFirst,
    'textScale': textScale,
    'outline': outline,
    'box': box,
    'color': color.toARGB32(),
    'secondaryColor': secondaryColor.toARGB32(),
    'backgroundColor': backgroundColor.toARGB32(),
    'borderColor': borderColor.toARGB32(),
    'shadowColor': shadowColor.toARGB32(),
    'shadowEnabled': shadowEnabled,
    'shadowBlur': shadowBlur,
    'shadowX': shadowOffset.dx,
    'shadowY': shadowOffset.dy,
  };

  /// Full snapshots keep queued exports independent of later UI edits.
  static SubtitleDebugPreset? restore(Object? raw) {
    if (raw is! Map) return null;
    final matches = subtitleDebugPresets.where((p) => p.id == raw['id']);
    if (matches.isEmpty) return null;
    final base = matches.first;
    double number(String key, double fallback, double min, double max) {
      final value = raw[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    Color c(String key, Color fallback) =>
        raw[key] is int ? Color(raw[key] as int) : fallback;
    // Fonts and immutable shape parameters are validated against the catalog.
    final families = subtitleDebugPresets
        .expand((p) => [p.primaryFont, p.secondaryFont])
        .toSet();
    String font(String key, String fallback) =>
        families.contains(raw[key]) ? raw[key] as String : fallback;
    return SubtitleDebugPreset(
      id: base.id,
      name: base.name,
      category: base.category,
      description: base.description,
      primaryFont: font('primaryFont', base.primaryFont),
      secondaryFont: font('secondaryFont', base.secondaryFont),
      primaryWeight: number(
        'primaryWeight',
        base.primaryWeight.toDouble(),
        100,
        900,
      ).round(),
      secondaryWeight: number(
        'secondaryWeight',
        base.secondaryWeight.toDouble(),
        100,
        900,
      ).round(),
      size: number('size', base.size, 10, 100),
      ratio: number('ratio', base.ratio, .3, 1.5),
      gap: number('gap', base.gap, 0, 20),
      bottom: number('bottom', base.bottom, 0, .4),
      width: number('width', base.width, .5, 1),
      secondaryFirst: raw['secondaryFirst'] is bool
          ? raw['secondaryFirst'] as bool
          : base.secondaryFirst,
      backgroundPadding: number(
        'backgroundPadding',
        base.backgroundPadding,
        0,
        12,
      ),
      textScale: number('textScale', 1, .6, 1.8),
      outline: number('outline', base.outline, 0, 6),
      box: number('box', base.box, 0, 1),
      color: c('color', base.color),
      secondaryColor: c('secondaryColor', base.secondaryColor),
      backgroundColor: c('backgroundColor', base.backgroundColor),
      borderColor: c('borderColor', base.borderColor),
      shadowColor: c('shadowColor', base.shadowColor),
      shadowEnabled: raw['shadowEnabled'] is bool
          ? raw['shadowEnabled'] as bool
          : base.shadowEnabled,
      shadowBlur: number('shadowBlur', base.shadowBlur, 0, 10),
      shadowOffset: Offset(
        number('shadowX', base.shadowOffset.dx, -8, 8),
        number('shadowY', base.shadowOffset.dy, -8, 8),
      ),
    );
  }

  double referenceHeight(Size viewport) =>
      SubtitleLayout.videoReferenceHeight(viewport);
  double bottomInset(Size viewport) =>
      viewport.height *
      (viewport.width / viewport.height < 1 ? math.max(.1, bottom) : bottom);
  SubtitleStyle styleFor({bool secondary = false}) {
    final font = secondary ? secondaryFont : primaryFont;
    final weight = FontWeight
        .values[(secondary ? secondaryWeight : primaryWeight) ~/ 100 - 1];
    return SubtitleStyle(
      textStyle: SubtitleTextStyle(
        fontFamilyChinese: font,
        fontFamilyEnglish: font,
        fontWeightChinese: weight,
        fontWeightEnglish: weight,
        textColor: secondary ? secondaryColor : color,
        hasBorder: outline > 0,
        borderWidth: outline,
        hasShadow: shadowEnabled,
        shadowBlur: shadowBlur,
        shadowOffset: shadowOffset,
        shadowColor: shadowColor,
        borderColor: borderColor,
        backgroundColor: backgroundColor,
        backgroundOpacity: box,
      ),
      layoutStyle: SubtitleLayoutStyle(
        fontSize: (secondary ? size * ratio : size) * textScale,
        lineSpacing: 0,
        letterSpacing: 0,
      ),
    );
  }

  String get fontSummary =>
      '主：${fontLabel(primaryFont)} $primaryWeight\n副：${fontLabel(secondaryFont)} $secondaryWeight';
  String get layoutSummary =>
      '720p 主 ${size.toStringAsFixed(0)} / 副 ${(size * ratio).toStringAsFixed(1)} · ${secondaryFirst ? "副上主下" : "主上副下"}\n'
      '描边 $outline · 间隔 $gap · 底距 ${(bottom * 100).round()}% · 宽 ${(math.min(width, SubtitleLayout.maxWidthFraction) * 100).round()}%';
  static String fontLabel(String font) => switch (font) {
    'Noto Sans SC' => '清幕黑 · 思源黑体',
    'Noto Serif CJK SC' => '银幕宋 · 思源宋体',
    'Inter' => '星际 · Inter',
    'Roboto' => '窄光 · Roboto Condensed',
    'Comic Relief' => '漫语 · Comic Relief',
    'Brawler' => '书影 · Brawler',
    _ => font,
  };
}

final List<SubtitleDebugPreset> subtitleDebugPresets = List.unmodifiable([
  // name, size, secondary ratio, stroke, primary weight, secondary weight.
  for (final row in [
    ('清幕标准', 32.0, .68, 2.4, 500, 500),
    ('清幕轻映', 29.0, .68, 1.8, 400, 400),
    ('清幕加粗', 34.0, .70, 2.8, 700, 600),
    ('清幕双语', 33.0, .78, 2.4, 500, 500),
    ('清幕紧凑', 28.0, .65, 2.2, 500, 500),
    ('清幕远观', 40.0, .74, 3.0, 700, 600),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '通用黑体',
      description: '白字黑边，适合日常电影、剧集与双语内容。',
      size: row.$2,
      ratio: row.$3,
      outline: row.$4,
      primaryWeight: row.$5,
      secondaryWeight: row.$6,
    ),
  for (final row in [
    ('银幕经典', 31.0, .68, 1.8, 400, 'Brawler'),
    ('银幕厚宋', 34.0, .70, 2.3, 700, 'Brawler'),
    ('银幕素白', 30.0, .65, 1.5, 400, 'Inter'),
    ('银幕史诗', 36.0, .68, 2.5, 700, 'Inter'),
    ('银幕细读', 29.0, .80, 1.8, 400, 'Brawler'),
    ('银幕宽景', 32.0, .66, 2.0, 700, 'Roboto'),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '电影宋体',
      description: '宋体与衬线/无衬线搭配；适合文艺片、历史片。',
      primaryFont: 'Noto Serif CJK SC',
      secondaryFont: row.$6,
      primaryWeight: row.$5,
      secondaryWeight: 400,
      size: row.$2,
      ratio: row.$3,
      outline: row.$4,
      bottom: .05,
      gap: 2,
    ),
  for (final row in [
    ('漫语日常', 35.0, .68, 3.0, 500, 400),
    ('漫语热血', 38.0, .72, 3.8, 700, 700),
    ('漫语轻声', 31.0, .70, 2.4, 400, 400),
    ('漫语剧场', 34.0, .65, 2.8, 700, 700),
    ('漫语双行', 33.0, .80, 3.0, 500, 400),
    ('漫语小屏', 40.0, .72, 3.6, 700, 700),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '动漫对白',
      description: '清晰中文配轻松手写感英文，强调复杂背景可读性。',
      secondaryFont: 'Comic Relief',
      size: row.$2,
      ratio: row.$3,
      outline: row.$4,
      primaryWeight: row.$5,
      secondaryWeight: row.$6,
      gap: 2,
      bottom: .04,
    ),
  for (final row in [
    ('金译经典', 33.0, .68, 2.5, 0xFFFFE27A),
    ('金译暖白', 31.0, .70, 2.2, 0xFFFFF2CC),
    ('金译琥珀', 35.0, .72, 3.0, 0xFFFFD166),
    ('金译明黄', 34.0, .68, 3.2, 0xFFFFFF66),
    ('金译淡金', 30.0, .78, 2.0, 0xFFFFE9B0),
    ('金译远观', 40.0, .72, 3.5, 0xFFFFE27A),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '黄白双语',
      description: '暖黄色主字幕、白色副字幕，快速区分两条轨道。',
      color: Color(row.$5),
      size: row.$2,
      ratio: row.$3,
      outline: row.$4,
      primaryWeight: 700,
      secondaryWeight: 600,
    ),
  for (final row in [
    ('星际原声', 32.0, .82, false, 'Inter'),
    ('星际原文在上', 32.0, .78, true, 'Inter'),
    ('星际等大对照', 30.0, 1.0, false, 'Inter'),
    ('星际长句', 29.0, .78, false, 'Roboto'),
    ('星际译文在下', 34.0, .72, true, 'Roboto'),
    ('星际课堂', 37.0, .85, false, 'Inter'),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '双语学习',
      description: '提高副字幕占比；上下顺序按主副轨道，不自动猜测语言。',
      size: row.$2,
      ratio: row.$3,
      secondaryFirst: row.$4,
      secondaryFont: row.$5,
      gap: 5,
      bottom: .06,
    ),
  for (final row in [
    ('窄光纪实', 30.0, .68, 2.0, 500),
    ('窄光访谈', 32.0, .75, 2.2, 500),
    ('窄光长句', 28.0, .72, 1.8, 400),
    ('窄光新闻', 35.0, .70, 2.8, 700),
    ('窄光宽幕', 31.0, .66, 2.0, 500),
    ('窄光小窗', 38.0, .72, 3.0, 700),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '纪录访谈',
      description: '较窄的英文节省横向空间，适合信息密集的对白。',
      secondaryFont: 'Roboto',
      size: row.$2,
      ratio: row.$3,
      outline: row.$4,
      primaryWeight: row.$5,
      width: .88,
      bottom: .06,
    ),
  for (final row in [
    ('夜读轻底', 32.0, .72, .35, 500),
    ('夜读标准', 35.0, .74, .55, 500),
    ('夜读高对比', 38.0, .78, .78, 700),
    ('夜读大字', 44.0, .78, .70, 700),
    ('夜读柔白', 34.0, .72, .45, 400),
    ('夜读等大', 34.0, 1.0, .65, 700),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '底板易读',
      description: '半透明黑底分离画面与文字，适合明亮或复杂背景。',
      size: row.$2,
      ratio: row.$3,
      box: row.$4,
      primaryWeight: row.$5,
      outline: 1.2,
      gap: 2,
      bottom: .055,
    ),
  for (final row in [
    ('掌心标准', 40.0, .72, 3.0, .12),
    ('掌心轻巧', 35.0, .68, 2.5, .10),
    ('掌心醒目', 46.0, .72, 3.5, .14),
    ('掌心双语', 38.0, .85, 2.8, .12),
    ('掌心居高', 40.0, .72, 3.0, .22),
    ('掌心方屏', 37.0, .75, 2.7, .10),
  ])
    SubtitleDebugPreset(
      id: row.$1,
      name: row.$1,
      category: '竖屏方屏',
      description: '按画面宽度限制字号，抬高底距，为竖屏操作区域留空。',
      size: row.$2,
      ratio: row.$3,
      outline: row.$4,
      bottom: row.$5,
      primaryWeight: 700,
      secondaryWeight: 600,
      width: .86,
    ),
]);
