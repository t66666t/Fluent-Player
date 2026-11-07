import 'dart:math' as math;

import '../../models/subtitle_font.dart';
import '../../utils/subtitle_font_resolver.dart';
import '../../utils/subtitle_layout.dart';
import 'package:flutter/material.dart';

import '../../models/subtitle_model.dart';
import '../../models/subtitle_style.dart';
import '../subtitle_font_service.dart';
import 'video_compose_font_service.dart';
import 'video_compose_types.dart';

class VideoComposeAssRenderer {
  final VideoComposeFontService _fontService;

  const VideoComposeAssRenderer(this._fontService);

  String buildAssContent({
    required int width,
    required int height,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    required SubtitleStyle style,
    required Alignment alignment,
    String? primaryLanguage,
    String? secondaryLanguage,
  }) {
    final exportStyle = SubtitleLayout.forVideoExport(style);
    final SubtitleResolvedStyleMetrics resolvedMetrics =
        SubtitleResolvedStyleMetrics.fromStyle(
          exportStyle,
          referenceHeight: SubtitleLayout.videoReferenceHeight(
            Size(width.toDouble(), height.toDouble()),
          ),
        );
    final SubtitleStyle resolvedStyle = resolvedMetrics.applyToStyle(
      exportStyle,
    );
    final double scale = resolvedMetrics.scale;
    final SubtitleTextStyle textStyle = resolvedStyle.textStyle;
    final SubtitleLayoutStyle layoutStyle = resolvedStyle.layoutStyle;
    final double fontSize = layoutStyle.fontSize;
    final double secondaryFontSize =
        layoutStyle.secondaryFontSize ?? layoutStyle.fontSize;
    final double letterSpacing = layoutStyle.letterSpacing;
    final int boldValue = _toAssBoldFlag(textStyle.fontWeightChinese);
    final int italicValue = textStyle.isItalic ? 1 : 0;
    final int underlineValue = textStyle.isUnderline ? 1 : 0;

    final String primaryColor = _toAssColor(
      textStyle.textColor,
      textStyle.textColor.a,
    );
    final String outlineColor = textStyle.hasBorder
        ? _toAssColor(textStyle.borderColor, textStyle.borderColor.a)
        : '&HFF000000';
    final String shadowColor = textStyle.hasShadow
        ? _toAssColor(textStyle.shadowColor, textStyle.shadowColor.a)
        : '&HFF000000';
    final String backColor = _toAssColor(
      textStyle.backgroundColor,
      textStyle.backgroundEnabled ? textStyle.backgroundOpacity : 0,
    );

    final double outline = textStyle.hasBorder
        ? textStyle.resolveBorderWidthForFontSize(fontSize)
        : 0;
    final String defaultFont = _fontService.resolveSystemFont(
      textStyle.fontFamilyChinese,
    );

    final double baseX = (((alignment.x + 1) / 2.0) * width).clamp(
      0.0,
      width.toDouble(),
    );
    final double baseY = (((alignment.y + 1) / 2.0) * height).clamp(
      0.0,
      height.toDouble(),
    );
    final List<ComposeCue> cues = _buildComposeCues(primary, secondary);
    final StringBuffer sb = StringBuffer();
    sb.writeln('[Script Info]');
    sb.writeln('ScriptType: v4.00+');
    sb.writeln('PlayResX: $width');
    sb.writeln('PlayResY: $height');
    sb.writeln('ScaledBorderAndShadow: yes');
    // Breaks are chosen by the same layout as playback, not by libass balancing.
    sb.writeln('WrapStyle: 2');
    final double bgPaddingX = 12.0 * scale;
    final double bgPaddingY = 6.0 * scale;
    final double contentWidth = SubtitleLayout.contentWidth(
      viewportWidth: width.toDouble(),
      fontSize: fontSize,
    );
    final int horizontalMargin = ((width - contentWidth) / 2 + bgPaddingX)
        .ceil();
    sb.writeln('[V4+ Styles]');
    sb.writeln(
      'Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,Alignment,MarginL,MarginR,MarginV,Encoding',
    );
    sb.writeln(
      'Style: Default,$defaultFont,${fontSize.toStringAsFixed(2)},$primaryColor,$primaryColor,$outlineColor,$shadowColor,$boldValue,$italicValue,$underlineValue,0,100,100,${letterSpacing.toStringAsFixed(2)},0,1,${outline.toStringAsFixed(2)},0,5,$horizontalMargin,$horizontalMargin,0,1',
    );
    sb.writeln(
      'Style: Background,$defaultFont,${fontSize.toStringAsFixed(2)},$backColor,$backColor,$backColor,$backColor,0,0,0,0,100,100,0,0,3,0,0,5,$horizontalMargin,$horizontalMargin,0,1',
    );
    sb.writeln('[Events]');
    sb.writeln(
      'Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text',
    );
    for (final ComposeCue cue in cues) {
      final caption = _layoutOverlayContent(
        primaryText: cue.primaryText,
        primaryLanguage: primaryLanguage,
        secondaryLanguage: secondaryLanguage,
        secondaryText: cue.secondaryText,
        style: resolvedStyle,
        primaryFontSize: fontSize,
        secondaryFontSize: secondaryFontSize,
        maxWidth: math.max(1, contentWidth - bgPaddingX * 2),
      );
      final double effectiveContentWidth = _toAssBackgroundContentWidth(
        caption.size.width,
      );
      final double wChild = effectiveContentWidth + bgPaddingX * 2;
      final double hChild = caption.size.height + bgPaddingY * 2;

      double itemX = baseX - alignment.x * (wChild / 2.0);
      double itemY = baseY - alignment.y * (hChild / 2.0);
      itemX = itemX.clamp(0.0, width.toDouble());
      itemY = itemY.clamp(0.0, height.toDouble());

      final String posTag =
          r'{\an5\pos('
          '${itemX.toStringAsFixed(1)},${itemY.toStringAsFixed(1)}'
          r')}';
      if (textStyle.backgroundEnabled && textStyle.backgroundOpacity > 0.01) {
        final String bgAss =
            _buildCombinedAssText(
              primaryText: caption.primaryText,
              primaryLanguage: primaryLanguage,
              secondaryLanguage: secondaryLanguage,
              secondaryText: caption.secondaryText,
              style: resolvedStyle,
              primaryFontSize: fontSize,
              secondaryFontSize: secondaryFontSize,
              applyBorder: false,
              applyShadow: false,
              fillAlpha: 255,
            ).replaceAll(
              r'\bord0.00',
              '\\bord0\\xbord${bgPaddingX.toStringAsFixed(2)}'
                  '\\ybord${bgPaddingY.toStringAsFixed(2)}',
            );
        sb.writeln(
          'Dialogue: 0,${_toAssTime(cue.startTime)},${_toAssTime(cue.endTime)},Background,,0,0,0,,$posTag$bgAss',
        );
      }
      if (textStyle.hasShadow) {
        final String shadowAss = _buildCombinedAssText(
          primaryText: caption.primaryText,
          primaryLanguage: primaryLanguage,
          secondaryLanguage: secondaryLanguage,
          secondaryText: caption.secondaryText,
          style: resolvedStyle,
          primaryFontSize: fontSize,
          secondaryFontSize: secondaryFontSize,
          applyBorder: false,
          applyShadow: true,
          fillAlpha: 255,
        );
        if (shadowAss.trim().isNotEmpty) {
          sb.writeln(
            'Dialogue: 1,${_toAssTime(cue.startTime)},${_toAssTime(cue.endTime)},Default,,0,0,0,,$posTag$shadowAss',
          );
        }
      }
      if (textStyle.hasBorder && outline > 0.0) {
        final String strokeAss = _buildCombinedAssText(
          primaryText: caption.primaryText,
          primaryLanguage: primaryLanguage,
          secondaryLanguage: secondaryLanguage,
          secondaryText: caption.secondaryText,
          style: resolvedStyle,
          primaryFontSize: fontSize,
          secondaryFontSize: secondaryFontSize,
          applyBorder: true,
          applyShadow: false,
          fillAlpha: 255,
        );
        if (strokeAss.trim().isNotEmpty) {
          sb.writeln(
            'Dialogue: 2,${_toAssTime(cue.startTime)},${_toAssTime(cue.endTime)},Default,,0,0,0,,$posTag$strokeAss',
          );
        }
      }
      final String fillAss = _buildCombinedAssText(
        primaryText: caption.primaryText,
        primaryLanguage: primaryLanguage,
        secondaryLanguage: secondaryLanguage,
        secondaryText: caption.secondaryText,
        style: resolvedStyle,
        primaryFontSize: fontSize,
        secondaryFontSize: secondaryFontSize,
        applyBorder: false,
        applyShadow: false,
      );
      if (fillAss.trim().isEmpty) continue;
      sb.writeln(
        'Dialogue: 3,${_toAssTime(cue.startTime)},${_toAssTime(cue.endTime)},Default,,0,0,0,,$posTag$fillAss',
      );
    }
    return sb.toString();
  }

  ({Size size, String primaryText, String? secondaryText})
  _layoutOverlayContent({
    required String primaryText,
    String? primaryLanguage,
    String? secondaryLanguage,
    required String? secondaryText,
    required SubtitleStyle style,
    required double primaryFontSize,
    required double secondaryFontSize,
    required double maxWidth,
  }) {
    final List<InlineSpan> spans = _buildOverlayContentSpans(
      primaryText: primaryText,
      primaryLanguage: primaryLanguage,
      secondaryLanguage: secondaryLanguage,
      secondaryText: secondaryText,
      style: style,
      primaryFontSize: primaryFontSize,
      secondaryFontSize: secondaryFontSize,
    );
    if (spans.isEmpty) {
      return (
        size: Size.zero,
        primaryText: primaryText,
        secondaryText: secondaryText,
      );
    }
    final TextPainter tp = TextPainter(
      text: TextSpan(children: spans),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    try {
      final layout = layoutSubtitleText(tp.text!, maxWidth: maxWidth);
      tp.text = layout.text;
      tp.layout(minWidth: 0, maxWidth: maxWidth);
      final secondaryStart = primaryText.isEmpty ? 0 : primaryText.length + 1;
      return (
        size: tp.size,
        primaryText: layout.wrapText(primaryText),
        secondaryText: secondaryText == null
            ? null
            : layout.wrapText(secondaryText, sourceOffset: secondaryStart),
      );
    } finally {
      tp.dispose();
    }
  }

  List<InlineSpan> _buildOverlayContentSpans({
    required String primaryText,
    String? primaryLanguage,
    String? secondaryLanguage,
    required String? secondaryText,
    required SubtitleStyle style,
    required double primaryFontSize,
    required double secondaryFontSize,
  }) {
    final List<InlineSpan> spans = <InlineSpan>[];
    final SubtitleStyle primaryStyle = style.copyWith(
      fontSize: primaryFontSize,
    );
    final SubtitleStyle secondaryStyle = style.copyWith(
      fontSize: secondaryFontSize,
      secondaryFontSize: secondaryFontSize,
    );
    final List<String> primaryLines = primaryText.split('\n');
    for (int i = 0; i < primaryLines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      spans.add(
        TextSpan(
          children: _buildOverlayLineSpans(
            primaryLines[i],
            primaryStyle,
            primaryLanguage,
          ),
        ),
      );
    }
    if (secondaryText == null || secondaryText.trim().isEmpty) {
      return spans;
    }
    if (primaryText.isNotEmpty) {
      spans.add(const TextSpan(text: '\n'));
    }
    final List<String> secLines = secondaryText.split('\n');
    final double secHeight = SubtitleResolvedStyleMetrics.resolveLineHeight(
      lineSpacing: style.layoutStyle.lineSpacing,
      fontSize: secondaryFontSize,
    ).clamp(0.0, 100.0);
    for (int i = 0; i < secLines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      spans.add(
        TextSpan(
          style: TextStyle(height: secHeight),
          children: _buildOverlayLineSpans(
            secLines[i],
            secondaryStyle,
            secondaryLanguage,
          ),
        ),
      );
    }
    return spans;
  }

  List<TextSpan> _buildOverlayLineSpans(
    String line,
    SubtitleStyle style,
    String? language,
  ) => [
    for (final run in resolveSubtitleFontRuns(
      line,
      style.textStyle,
      language: language,
    ))
      TextSpan(
        text: run.text,
        style: style
            .getTextStyle(
              overrideFontFamily: run.font.family,
              overrideFontWeight: run.font.fontWeight,
            )
            .copyWith(fontVariations: run.font.fontVariations),
      ),
  ];

  int _toAssBoldFlag(FontWeight weight) {
    return weight.value >= FontWeight.w600.value ? 1 : 0;
  }

  double _toAssBackgroundContentWidth(double measuredWidth) {
    return measuredWidth;
  }

  String _buildCombinedAssText({
    required String primaryText,
    String? primaryLanguage,
    String? secondaryLanguage,
    required String? secondaryText,
    required SubtitleStyle style,
    required double primaryFontSize,
    required double secondaryFontSize,
    required bool applyBorder,
    required bool applyShadow,
    int fillAlpha = 0,
  }) {
    final String primaryRaw = _cleanAssText(
      primaryText,
    ).replaceAll('\n', r'\N');
    final String secondaryRaw = _cleanAssText(
      secondaryText ?? '',
    ).replaceAll('\n', r'\N');
    final StringBuffer content = StringBuffer();
    if (primaryRaw.trim().isNotEmpty) {
      content.write(
        _applyAssStyles(
          primaryRaw,
          style,
          primaryFontSize,
          language: primaryLanguage,
          applyBorder: applyBorder,
          applyShadow: applyShadow,
          fillAlpha: fillAlpha,
        ),
      );
    }
    if (secondaryRaw.trim().isNotEmpty) {
      if (content.isNotEmpty) {
        content.write(r'\N');
      }
      content.write(
        _applyAssStyles(
          secondaryRaw,
          style,
          secondaryFontSize,
          language: secondaryLanguage,
          applyBorder: applyBorder,
          applyShadow: applyShadow,
          fillAlpha: fillAlpha,
        ),
      );
    }
    return content.toString();
  }

  String _applyAssStyles(
    String text,
    SubtitleStyle style,
    double fontSize, {
    String? language,
    required bool applyBorder,
    required bool applyShadow,
    int fillAlpha = 0,
  }) {
    if (text.isEmpty) return '';
    final List<String> lines = text.split(r'\N');
    final List<String> formattedLines = <String>[];

    for (final line in lines) {
      final lineBuffer = StringBuffer();
      for (final run in resolveSubtitleFontRuns(
        line,
        style.textStyle,
        language: language,
      )) {
        lineBuffer.write(
          _formatAssSegment(
            run.text,
            run.font,
            style,
            fontSize,
            applyBorder: applyBorder,
            applyShadow: applyShadow,
            fillAlpha: fillAlpha,
          ),
        );
      }
      formattedLines.add(lineBuffer.toString());
    }
    return formattedLines.join(r'\N');
  }

  String _formatAssSegment(
    String text,
    SubtitleFontChoice font,
    SubtitleStyle style,
    double fontSize, {
    required bool applyBorder,
    required bool applyShadow,
    required int fillAlpha,
  }) {
    final SubtitleTextStyle textStyle = style.textStyle;
    final String fontName = _fontService.resolveSystemFont(font.family);
    final FontWeight weight = font.fontWeight;
    final int boldFlag =
        SubtitleFontService.instance.find(font.family)?.hasVariableWeight ==
            true
        ? font.weight.clamp(2, 1000)
        : _toAssBoldFlag(weight);

    final int italic = textStyle.isItalic ? 1 : 0;
    final int underline = textStyle.isUnderline ? 1 : 0;
    final double letterSpacing = style.layoutStyle.letterSpacing;
    final double outline = textStyle.hasBorder
        ? textStyle.resolveBorderWidthForFontSize(fontSize)
        : 0;
    final double shadowOffsetX = textStyle.hasShadow
        ? textStyle.resolveShadowOffsetForFontSize(fontSize).dx
        : 0;
    final double shadowOffsetY = textStyle.hasShadow
        ? textStyle.resolveShadowOffsetForFontSize(fontSize).dy
        : 0;
    final double shadowBlur = textStyle.hasShadow
        ? textStyle.resolveShadowBlurForFontSize(fontSize)
        : 0;

    final StringBuffer tags = StringBuffer()
      ..write('\\fn$fontName')
      ..write('\\b$boldFlag')
      ..write('\\i$italic')
      ..write('\\u$underline')
      ..write('\\fsp${letterSpacing.toStringAsFixed(2)}')
      ..write('\\fs${fontSize.toStringAsFixed(2)}');
    final double strokeBlur = applyBorder && outline > 0
        ? outline.clamp(0.6, 1.2)
        : 0.0;
    final double blurValue = applyShadow
        ? shadowBlur
        : (applyBorder ? strokeBlur : 0.0);
    tags
      ..write('\\bord${(applyBorder ? outline : 0).toStringAsFixed(2)}')
      ..write('\\xshad${(applyShadow ? shadowOffsetX : 0).toStringAsFixed(2)}')
      ..write('\\yshad${(applyShadow ? shadowOffsetY : 0).toStringAsFixed(2)}')
      ..write('\\blur${blurValue.toStringAsFixed(2)}');
    if (fillAlpha > 0) {
      final int safeAlpha = fillAlpha.clamp(0, 255);
      tags.write(
        '\\1a&H${safeAlpha.toRadixString(16).padLeft(2, '0').toUpperCase()}&',
      );
    }
    return '{${tags.toString()}}$text';
  }

  List<ComposeCue> _buildComposeCues(
    List<SubtitleItem> primary,
    List<SubtitleItem> secondary,
  ) {
    final Set<int> boundaries = <int>{};
    for (final SubtitleItem item in primary) {
      final int startMs = item.startTime.inMilliseconds;
      final int endMs = item.endTime.inMilliseconds;
      if (endMs > startMs) {
        boundaries.add(startMs);
        boundaries.add(endMs);
      }
    }
    for (final SubtitleItem item in secondary) {
      final int startMs = item.startTime.inMilliseconds;
      final int endMs = item.endTime.inMilliseconds;
      if (endMs > startMs) {
        boundaries.add(startMs);
        boundaries.add(endMs);
      }
    }
    if (boundaries.length < 2) return const <ComposeCue>[];

    final List<int> sorted = boundaries.toList()..sort();
    final List<ComposeCue> cues = <ComposeCue>[];
    int primaryIndex = 0;
    int secondaryIndex = 0;

    for (int i = 0; i < sorted.length - 1; i++) {
      final int startMs = sorted[i];
      final int endMs = sorted[i + 1];
      if (endMs <= startMs) continue;

      while (primaryIndex < primary.length &&
          primary[primaryIndex].endTime.inMilliseconds <= startMs) {
        primaryIndex++;
      }
      while (secondaryIndex < secondary.length &&
          secondary[secondaryIndex].endTime.inMilliseconds <= startMs) {
        secondaryIndex++;
      }

      String primaryText = '';
      String? secondaryText;
      if (primaryIndex < primary.length) {
        final SubtitleItem item = primary[primaryIndex];
        if (item.startTime.inMilliseconds <= startMs &&
            item.endTime.inMilliseconds > startMs) {
          primaryText = item.text;
        }
      }
      if (secondaryIndex < secondary.length) {
        final SubtitleItem item = secondary[secondaryIndex];
        if (item.startTime.inMilliseconds <= startMs &&
            item.endTime.inMilliseconds > startMs) {
          secondaryText = item.text;
        }
      }

      if (primaryText.trim().isEmpty && (secondaryText ?? '').trim().isEmpty) {
        continue;
      }

      if (cues.isNotEmpty &&
          cues.last.endTime.inMilliseconds == startMs &&
          cues.last.primaryText == primaryText &&
          cues.last.secondaryText == secondaryText) {
        final ComposeCue last = cues.removeLast();
        cues.add(
          ComposeCue(
            startTime: last.startTime,
            endTime: Duration(milliseconds: endMs),
            primaryText: primaryText,
            secondaryText: secondaryText,
          ),
        );
      } else {
        cues.add(
          ComposeCue(
            startTime: Duration(milliseconds: startMs),
            endTime: Duration(milliseconds: endMs),
            primaryText: primaryText,
            secondaryText: secondaryText,
          ),
        );
      }
    }
    return cues;
  }

  String _toAssTime(Duration duration) {
    final int totalCs = (duration.inMilliseconds / 10).floor();
    final int cs = totalCs % 100;
    final int totalSec = totalCs ~/ 100;
    final int s = totalSec % 60;
    final int totalMin = totalSec ~/ 60;
    final int m = totalMin % 60;
    final int h = totalMin ~/ 60;
    return '${h.toString()}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }

  String _toAssColor(Color color, double alphaMultiplier) {
    final int alpha = ((1 - alphaMultiplier.clamp(0.0, 1.0)) * 255).round();
    final int r = (color.r * 255).round();
    final int g = (color.g * 255).round();
    final int b = (color.b * 255).round();
    return '&H${alpha.toRadixString(16).padLeft(2, '0').toUpperCase()}${b.toRadixString(16).padLeft(2, '0').toUpperCase()}${g.toRadixString(16).padLeft(2, '0').toUpperCase()}${r.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }

  String _cleanAssText(String text) {
    return text
        .replaceAll(r'\', r'\\')
        .replaceAll('{', r'\{')
        .replaceAll('}', r'\}')
        .replaceAll('\r', '');
  }
}
