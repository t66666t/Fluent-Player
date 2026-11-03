import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/folder_placeholder_style.dart';
import '../services/settings_service.dart';

/// Paints a folder cover from id + name. Parent decides the box size;
/// glyph and icon sizes are fractions of that box's shortest side so 16:9
/// covers and square list thumbs keep the same visual proportion.
class FolderPlaceholderCover extends StatelessWidget {
  const FolderPlaceholderCover({
    super.key,
    required this.folderId,
    required this.folderName,
    this.coverLabel,
    this.settings,
  });

  final String folderId;
  final String folderName;

  /// Per-folder override. Null follows [folderName]; empty hides this cover.
  final String? coverLabel;

  /// When null, reads [SettingsService] or falls back to defaults.
  final FolderPlaceholderSettings? settings;

  /// Reads [SettingsService] when a provider is above this cover; tests and
  /// standalone previews can omit it and keep the default look.
  static SettingsService? _maybeSettings(BuildContext context) {
    try {
      return Provider.of<SettingsService>(context, listen: true);
    } on ProviderNotFoundException {
      return null;
    }
  }

  static Key coverKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-cover-$folderId');
  static Key glyphKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-glyph-$folderId');
  static Key folderIconKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-folder-icon-$folderId');
  static Key silhouetteKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-silhouette-$folderId');
  static Key cornerBadgeKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-corner-badge-$folderId');
  static Key letterBadgeKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-letter-badge-$folderId');
  static Key glyphBoxKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-glyph-box-$folderId');
  static Key folderIconBoxKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-folder-icon-box-$folderId');
  static Key silhouetteBoxKeyFor(String folderId) =>
      ValueKey<String>('folder-placeholder-silhouette-box-$folderId');

  static double coverBasis(BoxConstraints constraints) {
    final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
    final height = constraints.maxHeight.isFinite
        ? constraints.maxHeight
        : 0.0;
    final shortest = math.min(
      width > 0 ? width : double.infinity,
      height > 0 ? height : double.infinity,
    );
    if (shortest.isFinite && shortest > 0) return shortest;
    final fallback = math.max(width, height);
    return fallback > 0 ? fallback : 1.0;
  }

  @override
  Widget build(BuildContext context) {
    final resolved =
        settings ??
        _maybeSettings(context)?.folderPlaceholderSettings ??
        FolderPlaceholderSettings.defaults;
    final glyph = FolderPlaceholderLook.displayLabel(
      folderName: folderName,
      coverLabel: coverLabel,
      showCoverText: resolved.showCoverText,
      maxLength: resolved.maxCoverTextLength,
    );
    final swatch = FolderPlaceholderLook.swatchFor(
      folderId: folderId,
      colorStyle: resolved.colorStyle,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final basis = coverBasis(constraints);
        return KeyedSubtree(
          key: coverKeyFor(folderId),
          child: switch (resolved.paintStyle) {
            FolderPlaceholderPaintStyle.letterBlock => _LetterBlockCover(
              folderId: folderId,
              basis: basis,
              glyph: glyph,
              swatch: swatch,
              settings: resolved,
            ),
            FolderPlaceholderPaintStyle.tintedIcon => _TintedIconCover(
              folderId: folderId,
              basis: basis,
              glyph: glyph,
              swatch: swatch,
              settings: resolved,
            ),
            FolderPlaceholderPaintStyle.gradientGhost => _GradientGhostCover(
              folderId: folderId,
              basis: basis,
              glyph: glyph,
              swatch: swatch,
              settings: resolved,
            ),
          },
        );
      },
    );
  }
}

class _LetterBlockCover extends StatelessWidget {
  const _LetterBlockCover({
    required this.folderId,
    required this.basis,
    required this.glyph,
    required this.swatch,
    required this.settings,
  });

  final String folderId;
  final double basis;
  final String glyph;
  final FolderPlaceholderSwatch swatch;
  final FolderPlaceholderSettings settings;

  @override
  Widget build(BuildContext context) {
    final badgeSize = basis * settings.cornerBadgeScale;
    return ColoredBox(
      color: swatch.accent,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          if (glyph.isNotEmpty)
            _OpticallyCenteredGlyph(
              folderId: folderId,
              glyph: glyph,
              size: FolderPlaceholderLook.glyphSize(
                basis: basis,
                glyph: glyph,
                multiplier: settings.letterScale,
                paintStyle: FolderPlaceholderPaintStyle.letterBlock,
              ),
              opacity: settings.letterOpacity,
            ),
          if (settings.cornerBadgeScale > 0.01)
            Positioned(
              left: 0,
              top: 0,
              child: DecoratedBox(
                key: FolderPlaceholderCover.cornerBadgeKeyFor(folderId),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.only(
                    bottomRight: Radius.circular(badgeSize * 0.55),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.all(badgeSize * 0.32),
                  child: _OpticallyCenteredFolderIcon(
                    iconKey: ValueKey<String>(
                      'folder-placeholder-corner-icon-$folderId',
                    ),
                    size: badgeSize,
                    color: Colors.white.withValues(alpha: 0.88),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TintedIconCover extends StatelessWidget {
  const _TintedIconCover({
    required this.folderId,
    required this.basis,
    required this.glyph,
    required this.swatch,
    required this.settings,
  });

  final String folderId;
  final double basis;
  final String glyph;
  final FolderPlaceholderSwatch swatch;
  final FolderPlaceholderSettings settings;

  @override
  Widget build(BuildContext context) {
    final badgeDiameter = FolderPlaceholderLook.letterBadgeDiameter(
      basis: basis,
      badgeScale: settings.letterBadgeScale,
    );
    final glyphSize = FolderPlaceholderLook.letterBadgeGlyphSize(
      badgeDiameter: badgeDiameter,
      glyph: glyph,
      glyphScale: settings.letterBadgeGlyphScale,
    );
    return ColoredBox(
      color: const Color(0xFF16181C),
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          _OpticallyCenteredFolderIcon(
            iconKey: FolderPlaceholderCover.folderIconKeyFor(folderId),
            boxKey: FolderPlaceholderCover.folderIconBoxKeyFor(folderId),
            size: basis * settings.folderIconScale,
            color: swatch.accent.withValues(alpha: settings.iconOpacity),
          ),
          if (glyph.isNotEmpty)
            Positioned(
              right: basis * 0.06,
              bottom: basis * 0.06,
              child: DecoratedBox(
                key: FolderPlaceholderCover.letterBadgeKeyFor(folderId),
                decoration: BoxDecoration(
                  color: swatch.shadow.withValues(alpha: 0.92),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.18),
                    width: (basis * 0.012).clamp(0.6, 2.0),
                  ),
                ),
                child: ClipOval(
                  child: SizedBox.square(
                    dimension: badgeDiameter,
                    child: _OpticallyCenteredGlyph(
                      folderId: folderId,
                      glyph: glyph,
                      size: glyphSize,
                      opacity: 0.95,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GradientGhostCover extends StatelessWidget {
  const _GradientGhostCover({
    required this.folderId,
    required this.basis,
    required this.glyph,
    required this.swatch,
    required this.settings,
  });

  final String folderId;
  final double basis;
  final String glyph;
  final FolderPlaceholderSwatch swatch;
  final FolderPlaceholderSettings settings;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[swatch.accent, swatch.shadow],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          _OpticallyCenteredFolderIcon(
            iconKey: FolderPlaceholderCover.silhouetteKeyFor(folderId),
            boxKey: FolderPlaceholderCover.silhouetteBoxKeyFor(folderId),
            size: basis * settings.silhouetteScale,
            color: Colors.white.withValues(alpha: settings.silhouetteOpacity),
          ),
          if (glyph.isNotEmpty)
            Transform.translate(
              offset: FolderPlaceholderLook.gradientGhostGlyphNudge(
                basis * settings.silhouetteScale,
              ),
              child: _OpticallyCenteredGlyph(
                folderId: folderId,
                glyph: glyph,
                size: FolderPlaceholderLook.glyphSize(
                  basis: basis,
                  glyph: glyph,
                  multiplier: settings.gradientLetterScale,
                  paintStyle: FolderPlaceholderPaintStyle.gradientGhost,
                ),
                opacity: settings.gradientLetterOpacity,
              ),
            ),
        ],
      ),
    );
  }
}

/// Shifts a glyph so its ink box — not the font's ascent/descent — sits on
/// the layout center. CJK and Material Icons both sit high if you only Center.
class _OpticallyCenteredGlyph extends StatelessWidget {
  const _OpticallyCenteredGlyph({
    required this.folderId,
    required this.glyph,
    required this.size,
    required this.opacity,
  });

  final String folderId;
  final String glyph;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    if (glyph.isEmpty) return const SizedBox.shrink();
    final graphemes = glyph.characters.length;
    final fontSize = size.clamp(1.0, 2400.0);
    final cjk = FolderPlaceholderLook.glyphIsMostlyCjk(glyph);
    // CJK sits lighter at w600; Latin caps already look loud.
    final style = TextStyle(
      color: Colors.white.withValues(alpha: opacity),
      fontSize: fontSize,
      height: 1,
      fontWeight: FontWeight.w700,
      letterSpacing: graphemes <= 1
          ? 0
          : fontSize * (cjk ? -0.02 : 0.03),
      leadingDistribution: TextLeadingDistribution.even,
    );
    final widthFactor = cjk
        ? (graphemes <= 1 ? 1.08 : graphemes * 0.98)
        : (graphemes <= 1 ? 0.78 : graphemes * 0.68);
    return _OpticallyCenteredBox(
      boxKey: FolderPlaceholderCover.glyphBoxKeyFor(folderId),
      width: fontSize * widthFactor,
      height: fontSize * 1.12,
      offset: _opticalInkOffset(
        text: glyph,
        style: style,
        textScaler: MediaQuery.textScalerOf(context),
        // Ink-box center still reads low: CJK stroke mass sits in the lower
        // half of the em, Latin caps sit on the baseline.
      ) +
          Offset(0, -fontSize * 0.055),
      child: Text(
        glyph,
        key: FolderPlaceholderCover.glyphKeyFor(folderId),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.visible,
        style: style,
      ),
    );
  }
}

class _OpticallyCenteredFolderIcon extends StatelessWidget {
  const _OpticallyCenteredFolderIcon({
    required this.iconKey,
    required this.size,
    required this.color,
    this.boxKey,
  });

  final Key iconKey;
  final Key? boxKey;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    const icon = Icons.folder_rounded;
    final iconSize = size.clamp(1.0, 2400.0);
    final style = TextStyle(
      inherit: false,
      color: color,
      fontSize: iconSize,
      height: 1,
      fontFamily: icon.fontFamily,
      package: icon.fontPackage,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return _OpticallyCenteredBox(
      boxKey: boxKey,
      width: iconSize,
      height: iconSize,
      offset: _opticalInkOffset(
        text: String.fromCharCode(icon.codePoint),
        style: style,
        textScaler: MediaQuery.textScalerOf(context),
      ),
      child: Icon(icon, key: iconKey, size: iconSize, color: color),
    );
  }
}

class _OpticallyCenteredBox extends StatelessWidget {
  const _OpticallyCenteredBox({
    required this.width,
    required this.height,
    required this.offset,
    required this.child,
    this.boxKey,
  });

  final Key? boxKey;
  final double width;
  final double height;
  final Offset offset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Center loosens the expand-Stack's tight cover constraints; otherwise a
    // 16:9 parent would stretch this box to the full card. Clamp the layout
    // box to the parent, then Transform.scale when the requested size is
    // larger so silhouettes can overflow without unbounded Icon constraints.
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth.isFinite && constraints.maxWidth > 0
              ? constraints.maxWidth
              : width;
          final maxH =
              constraints.maxHeight.isFinite && constraints.maxHeight > 0
              ? constraints.maxHeight
              : height;
          final scale = math.max(
            1.0,
            math.max(width / maxW, height / maxH),
          );
          final boxW = (width / scale).clamp(1.0, 2400.0);
          final boxH = (height / scale).clamp(1.0, 2400.0);
          Widget box = SizedBox(
            key: boxKey,
            width: boxW,
            height: boxH,
            child: FittedBox(
              fit: BoxFit.contain,
              child: Transform.translate(offset: offset, child: child),
            ),
          );
          if (scale > 1.001) {
            box = Transform.scale(scale: scale, child: box);
          }
          return box;
        },
      ),
    );
  }
}

/// Layout-box center minus ink-box center. Applied as a translation so the
/// drawn mass lands on Alignment.center of the cover.
Offset _opticalInkOffset({
  required String text,
  required TextStyle style,
  required TextScaler textScaler,
}) {
  if (text.isEmpty) return Offset.zero;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  );
  painter.layout();
  try {
    if (painter.width <= 0 || painter.height <= 0) return Offset.zero;
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    if (boxes.isEmpty) return Offset.zero;
    var left = boxes.first.left;
    var top = boxes.first.top;
    var right = boxes.first.right;
    var bottom = boxes.first.bottom;
    for (final box in boxes.skip(1)) {
      left = math.min(left, box.left);
      top = math.min(top, box.top);
      right = math.max(right, box.right);
      bottom = math.max(bottom, box.bottom);
    }
    return Offset(
      painter.width / 2 - (left + right) / 2,
      painter.height / 2 - (top + bottom) / 2,
    );
  } finally {
    painter.dispose();
  }
}
