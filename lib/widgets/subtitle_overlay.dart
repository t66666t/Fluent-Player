import '../models/subtitle_font.dart';
import '../services/subtitle_font_service.dart';
import '../utils/subtitle_font_resolver.dart';
import '../models/subtitle_debug_preset.dart';
import '../services/subtitle_debug_session.dart';
import '../services/subtitle_position_controller.dart';
import '../utils/subtitle_position_geometry.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/subtitle_style.dart';
import '../utils/subtitle_layout.dart';
import '../utils/subtitle_optical_alignment.dart';
import 'subtitle_position_surface.dart';

export '../utils/subtitle_position_geometry.dart'
    show resolveSubtitleOverlayOffset;

class SubtitleOverlayEntry {
  final String? language;
  final String? secondaryLanguage;
  final String? sourcePath;
  final String? secondarySourcePath;
  final int? index;
  final String text;
  final String? secondaryText;
  final Uint8List? image;

  const SubtitleOverlayEntry({
    this.language,
    this.secondaryLanguage,
    this.sourcePath,
    this.secondarySourcePath,
    this.index,
    required this.text,
    this.secondaryText,
    this.image,
  });

  bool get hasContent {
    if (image != null) return true;
    if (text.isNotEmpty) return true;
    if (secondaryText != null && secondaryText!.isNotEmpty) return true;
    return false;
  }
}

/// Small visual gap between the subtitle background and playback controls.
/// It scales with the current player viewport instead of using a device-
/// independent fixed offset that can look excessive on short screens.
double subtitlePlaybackControlsClearance(double viewportHeight) {
  if (!viewportHeight.isFinite || viewportHeight <= 0) return 0;
  return viewportHeight * 0.008;
}

/// Shown only while position editing has no real caption. Never written back
/// to a subtitle file or the playback timeline.
const SubtitleOverlayEntry kSubtitlePositionPreviewEntry = SubtitleOverlayEntry(
  text: '字幕位置预览',
  secondaryText: 'Subtitle Preview',
);

class SubtitleOverlayGroup extends StatelessWidget {
  final List<SubtitleOverlayEntry> entries;
  final bool enableDebugPreview;
  final SubtitleDebugPreset? presetOverride;
  final SubtitleStyle style;
  final double? referenceHeight;

  /// Sizing reference for ghost captions, independent of the position viewport.
  /// If omitted, use the window's MediaQuery size, never the video dimensions.
  final Size? fullPageSize;
  final Alignment alignment;
  final bool isGhostMode;
  final bool isDragging;
  final bool isGestureOnly;
  final bool isVisualOnly;
  final double itemGap;
  final bool animateAlignment;
  final Duration alignmentDuration;
  final Curve alignmentCurve;
  final ValueListenable<bool>? playbackControlsVisibility;
  final double? playbackControlsTop;
  final List<Rect> Function()? playbackControlRects;
  final bool avoidPlaybackControls;
  final SubtitlePositionController? positionController;

  /// Only explicit position editing accepts input; playback captions pass it on.
  final bool positionInteractive;
  final bool showPositionFrame;
  final bool presetPositionOverride;
  final void Function(int pointer)? onPositionPointerClaimed;

  const SubtitleOverlayGroup({
    super.key,
    required this.entries,
    this.enableDebugPreview = true,
    this.presetOverride,
    required this.style,
    this.referenceHeight,
    this.fullPageSize,
    required this.alignment,
    this.isGhostMode = false,
    this.isDragging = false,
    this.isGestureOnly = false,
    this.isVisualOnly = false,
    this.itemGap = 6.0,
    this.animateAlignment = false,
    this.alignmentDuration = const Duration(milliseconds: 300),
    this.alignmentCurve = Curves.easeOutCubic,
    this.playbackControlsVisibility,
    this.playbackControlsTop,
    this.playbackControlRects,
    this.avoidPlaybackControls = false,
    this.positionController,
    this.positionInteractive = false,
    this.showPositionFrame = false,
    this.presetPositionOverride = false,
    this.onPositionPointerClaimed,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      SubtitleFontService.instance,
      if (enableDebugPreview) SubtitleDebugSession.instance,
    ]),
    builder: (context, _) {
      final families = <String>{};
      final usingPreset =
          !entries.any((e) => e.image != null) &&
          (presetOverride != null ||
              (enableDebugPreview &&
                  SubtitleDebugSession.instance.presetForMode(
                        ghost: isGhostMode,
                      ) !=
                      null));
      if (!usingPreset) {
        for (final entry in entries) {
          families.addAll(
            SubtitleFontService.instance.familiesForText(
              entry.text,
              style.textStyle,
              language:
                  SubtitleFontService.instance.languageForSource(
                    entry.sourcePath,
                  ) ??
                  entry.language,
            ),
          );
          families.addAll(
            SubtitleFontService.instance.familiesForText(
              entry.secondaryText ?? '',
              style.textStyle,
              language:
                  SubtitleFontService.instance.languageForSource(
                    entry.secondarySourcePath,
                  ) ??
                  entry.secondaryLanguage,
            ),
          );
        }
      }
      if (families.any((f) => !SubtitleFontService.instance.isLoaded(f))) {
        return FutureBuilder<void>(
          future: SubtitleFontService.instance.prepareFamilies(families),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(
                child: Text(
                  '字幕字体加载失败，请重新选择字体',
                  style: TextStyle(fontSize: 12, color: Colors.orangeAccent),
                ),
              );
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox.shrink();
            }
            return _build(context);
          },
        );
      }
      return _build(context);
    },
  );

  Widget _build(BuildContext context) {
    final preset = entries.any((e) => e.image != null)
        ? null
        : presetOverride ??
              (enableDebugPreview
                  ? SubtitleDebugSession.instance.presetForMode(
                      ghost: isGhostMode,
                    )
                  : null);
    final bool editingFrame = showPositionFrame || isDragging;
    final List<SubtitleOverlayEntry> visibleEntries = entries
        .where((e) => e.hasContent)
        .toList();
    if (visibleEntries.isEmpty && !editingFrame) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        final debugInset = isGhostMode
            ? 0.0
            : preset?.bottomInset(viewport) ?? 0.0;
        final pageSize = fullPageSize ?? MediaQuery.maybeSizeOf(context);
        final double resolvedReferenceHeight =
            preset == null && style.layoutStyle.balancedScreenSizing
            ? (isGhostMode
                  ? SubtitleLayout.balancedScreenReferenceHeight(
                      pageSize ?? viewport,
                      viewportWidth: viewport.width,
                    )
                  : SubtitleLayout.balancedVideoReferenceHeight(
                      viewport,
                      pageSize: pageSize ?? viewport,
                      referenceHeight: referenceHeight,
                    ))
            : isGhostMode
            ? SubtitleLayout.ghostReferenceHeight(pageSize ?? viewport)
            : SubtitleLayout.videoReferenceHeight(
                viewport,
                referenceHeight: referenceHeight,
              );
        final double scale = SubtitleResolvedStyleMetrics.fromStyle(
          style,
          referenceHeight: resolvedReferenceHeight,
        ).scale;
        // Height belongs to the position viewport so a custom placement and a
        // preset default share one constraint source. Width stays here because
        // it is part of the preset's own layout, not its position.
        final captionStyle = preset?.styleFor() ?? style;
        final captionMetrics = SubtitleResolvedStyleMetrics.fromStyle(
          captionStyle,
          referenceHeight: resolvedReferenceHeight,
        );
        final childConstraints = BoxConstraints(
          maxWidth: SubtitleLayout.contentWidth(
            viewportWidth: viewport.width,
            fontSize: captionMetrics.fontSize,
            presetWidth: preset?.width ?? 1,
          ),
          maxHeight: preset == null
              ? double.infinity
              : (constraints.maxHeight - debugInset).clamp(
                      0.0,
                      constraints.maxHeight,
                    ) /
                    (visibleEntries.isEmpty ? 1 : visibleEntries.length),
        );
        Widget blockFor(List<SubtitleOverlayEntry> rendered) {
          return RepaintBoundary(
            child: SingleChildScrollView(
              reverse: alignment.y >= 0,
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < rendered.length; i++) ...[
                    ConstrainedBox(
                      constraints: rendered[i].image == null
                          ? childConstraints
                          : childConstraints.copyWith(maxWidth: viewport.width),
                      child: preset != null
                          ? FittedBox(
                              fit: BoxFit.scaleDown,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: childConstraints.maxWidth,
                                ),
                                child: SubtitlePresetContent(
                                  entry: rendered[i],
                                  preset: preset,
                                  referenceHeight: resolvedReferenceHeight,
                                  isGestureOnly: isGestureOnly,
                                ),
                              ),
                            )
                          : SubtitleOverlay(
                              language:
                                  SubtitleFontService.instance
                                      .languageForSource(
                                        rendered[i].sourcePath,
                                      ) ??
                                  rendered[i].language,
                              secondaryLanguage:
                                  SubtitleFontService.instance
                                      .languageForSource(
                                        rendered[i].secondarySourcePath,
                                      ) ??
                                  rendered[i].secondaryLanguage,
                              text: rendered[i].text,
                              secondaryText: rendered[i].secondaryText,
                              image: rendered[i].image,
                              style: style,
                              referenceHeight: resolvedReferenceHeight,
                              isDragging: false,
                              isGestureOnly: isGestureOnly,
                              isVisualOnly:
                                  isVisualOnly || positionController != null,
                            ),
                    ),
                    if (i != rendered.length - 1)
                      SizedBox(height: itemGap * scale),
                  ],
                ],
              ),
            ),
          );
        }

        final Widget content = _SubtitleEntryFreeze(
          controller: positionController,
          entries: visibleEntries,
          preview: editingFrame,
          builder: blockFor,
        );

        Widget buildPositionedContent(bool controlsVisible) {
          final bool dragging = positionController?.dragging ?? false;
          final double? effectiveControlsTop =
              avoidPlaybackControls && controlsVisible && !dragging
              ? playbackControlsTop
              : null;
          final List<Rect> effectiveControlRects =
              avoidPlaybackControls && controlsVisible && !dragging
              ? playbackControlRects?.call() ?? const <Rect>[]
              : const <Rect>[];
          final bool animate =
              animateAlignment &&
              !dragging &&
              !(positionController?.hasCustomDraft ?? false) &&
              (preset == null || isGhostMode);
          return _AnimatedSubtitlePosition(
            alignment: alignment,
            duration: animate ? alignmentDuration : Duration.zero,
            curve: alignmentCurve,
            bottomInset: debugInset,
            hasPreset: preset != null,
            ghost: isGhostMode,
            hasPositionOverride: presetPositionOverride,
            controller: positionController,
            showFrame: editingFrame && !isGestureOnly && !isVisualOnly,
            acceptContentHits:
                positionInteractive && !isVisualOnly && !isGestureOnly,
            interactive: positionInteractive && !isVisualOnly && !isGestureOnly,
            paintOutset: _positionPaintOutset(
              style: style,
              preset: preset,
              referenceHeight: resolvedReferenceHeight,
            ),
            playbackControlsTop: effectiveControlsTop,
            playbackControlRects: effectiveControlRects,
            onPointerClaimed: onPositionPointerClaimed,
            child: content,
          );
        }

        final Widget alignedChild = playbackControlsVisibility == null
            ? buildPositionedContent(false)
            : ValueListenableBuilder<bool>(
                valueListenable: playbackControlsVisibility!,
                builder: (context, controlsVisible, _) =>
                    buildPositionedContent(controlsVisible),
              );

        return SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          // Captions can paint above controls, but playback input must pass
          // through the entire subtree (including its scroll view and presets).
          // Only the explicit position editor owns subtitle gestures.
          child: IgnorePointer(
            ignoring: !positionInteractive || isVisualOnly || isGestureOnly,
            child: ClipRect(child: alignedChild),
          ),
        );
      },
    );
  }
}

EdgeInsets _positionPaintOutset({
  required SubtitleStyle style,
  required SubtitleDebugPreset? preset,
  required double referenceHeight,
}) {
  EdgeInsets fromStyle(SubtitleStyle source, {double optical = 0}) {
    final SubtitleStyle scaled = SubtitleResolvedStyleMetrics.fromStyle(
      source,
      referenceHeight: referenceHeight,
    ).applyToStyle(source);
    return subtitlePaintOutset(
      hasBorder: scaled.hasBorder,
      borderWidth: scaled.effectiveBorderWidth,
      hasShadow: scaled.hasShadow,
      shadowBlur: scaled.effectiveShadowBlur,
      shadowOffset: scaled.effectiveShadowOffset,
      opticalShift: optical * scaled.fontSize,
    );
  }

  if (preset == null) return fromStyle(style);
  return inflateEdgeInsets(
    fromStyle(
      preset.styleFor(),
      optical: subtitlePresetOpticalOffsetEm(preset.primaryFont, ''),
    ),
    fromStyle(
      preset.styleFor(secondary: true),
      optical: subtitlePresetOpticalOffsetEm(preset.secondaryFont, ''),
    ),
  );
}

class _SubtitleEntryFreeze extends StatefulWidget {
  final SubtitlePositionController? controller;
  final List<SubtitleOverlayEntry> entries;
  final bool preview;
  final Widget Function(List<SubtitleOverlayEntry> entries) builder;

  const _SubtitleEntryFreeze({
    required this.controller,
    required this.entries,
    required this.preview,
    required this.builder,
  });

  @override
  State<_SubtitleEntryFreeze> createState() => _SubtitleEntryFreezeState();
}

class _SubtitleEntryFreezeState extends State<_SubtitleEntryFreeze> {
  List<SubtitleOverlayEntry>? _frozen;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onController);
  }

  @override
  void didUpdateWidget(_SubtitleEntryFreeze oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onController);
      widget.controller?.addListener(_onController);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onController);
    super.dispose();
  }

  void _onController() {
    final bool freeze = widget.controller?.dragging ?? false;
    if (freeze && _frozen == null) {
      final List<SubtitleOverlayEntry> source = widget.entries.isEmpty
          ? const <SubtitleOverlayEntry>[kSubtitlePositionPreviewEntry]
          : widget.entries;
      setState(() => _frozen = List<SubtitleOverlayEntry>.of(source));
    } else if (!freeze && _frozen != null) {
      setState(() => _frozen = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<SubtitleOverlayEntry> live =
        widget.entries.isEmpty && widget.preview
        ? const <SubtitleOverlayEntry>[kSubtitlePositionPreviewEntry]
        : widget.entries;
    return widget.builder(_frozen ?? live);
  }
}

class _AnimatedSubtitlePosition extends ImplicitlyAnimatedWidget {
  final Alignment alignment;
  final double bottomInset;
  final bool hasPreset;
  final bool ghost;
  final bool hasPositionOverride;
  final SubtitlePositionController? controller;
  final bool showFrame;
  final bool acceptContentHits;
  final bool interactive;
  final EdgeInsets paintOutset;
  final double? playbackControlsTop;
  final List<Rect> playbackControlRects;
  final void Function(int pointer)? onPointerClaimed;
  final Widget child;

  const _AnimatedSubtitlePosition({
    required this.alignment,
    required super.duration,
    required super.curve,
    required this.bottomInset,
    required this.hasPreset,
    required this.ghost,
    required this.hasPositionOverride,
    required this.controller,
    required this.showFrame,
    required this.acceptContentHits,
    required this.interactive,
    required this.paintOutset,
    required this.playbackControlsTop,
    required this.playbackControlRects,
    required this.onPointerClaimed,
    required this.child,
  });

  @override
  AnimatedWidgetBaseState<_AnimatedSubtitlePosition> createState() =>
      _AnimatedSubtitlePositionState();
}

class _AnimatedSubtitlePositionState
    extends AnimatedWidgetBaseState<_AnimatedSubtitlePosition> {
  AlignmentTween? _alignmentTween;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _alignmentTween =
        visitor(
              _alignmentTween,
              widget.alignment,
              (dynamic value) => AlignmentTween(begin: value as Alignment),
            )
            as AlignmentTween?;
  }

  @override
  Widget build(BuildContext context) {
    final Widget viewport = SubtitlePositionViewport(
      alignment: _alignmentTween?.evaluate(animation) ?? widget.alignment,
      bottomInset: widget.bottomInset,
      hasPreset: widget.hasPreset,
      ghost: widget.ghost,
      hasPositionOverride: widget.hasPositionOverride,
      controller: widget.controller,
      showFrame: widget.showFrame,
      acceptContentHits: widget.acceptContentHits,
      interactive: widget.interactive,
      paintOutset: widget.paintOutset,
      // Controls avoidance is not tweened: it has to move with the controls
      // in the same frame.
      playbackControlsTop: widget.playbackControlsTop,
      playbackControlRects: widget.playbackControlRects,
      geometryHandle: widget.controller?.geometry,
      child: widget.child,
    );
    if (widget.controller == null) {
      return viewport;
    }
    return SubtitlePositionGestures(
      controller: widget.controller,
      interactive: widget.interactive,
      onPointerClaimed: widget.onPointerClaimed,
      child: viewport,
    );
  }
}

/// Calibrated against visible glyph bounds in the bundled font files, in em.
/// A stable script/font correction avoids baseline jitter between sentences;
/// measuring each subtitle's ink would jump on punctuation and descenders.
/// CJK in Latin-only families uses the explicitly bundled Noto Sans fallback.
/// Keep these values independent of background opacity and export resolution.
///
/// Latin must not be calibrated to the full ink box of a sample with
/// descenders (`g`/`y`/`p`). That pulls the x-height and cap-height band
/// too high, and on wrapped lines the whole block sits against the top of
/// the plate. English values therefore center the cap/x-height body; CJK
/// ideographs still use the fuller glyph-box correction.
double subtitlePresetOpticalOffsetEm(String font, String text) {
  final downloaded = SubtitleFontService.instance.find(font);
  final isSerif = font == 'Noto Serif CJK SC' ||
      downloaded?.name == 'Noto Serif SC' ||
      downloaded?.internalFamily == 'Noto Serif SC' ||
      downloaded?.internalFamily == 'Noto Serif CJK SC';
  final hasCjk = RegExp(
    r'[\u2E80-\u9FFF\uAC00-\uD7AF\uF900-\uFAFF]',
  ).hasMatch(text);
  if (hasCjk) return isSerif ? -.104 : -.068;
  if (isSerif) return -.050;
  return switch (font) {
    'Noto Sans SC' => -.058,
    'Noto Serif CJK SC' => -.050,
    'Inter' => -.012,
    'Roboto' => 0,
    'Comic Relief' => 0,
    'Brawler' => -.008,
    _ => 0,
  };
}

/// Shared by playback, lyric rows, preset previews and precise export.
class SubtitlePresetContent extends StatelessWidget {
  final SubtitleOverlayEntry entry;
  final SubtitleDebugPreset preset;
  final double referenceHeight;
  final bool isGestureOnly;
  const SubtitlePresetContent({
    super.key,
    required this.entry,
    required this.preset,
    required this.referenceHeight,
    this.isGestureOnly = false,
  });
  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[
      if (entry.text.isNotEmpty)
        SubtitleOverlay(
          text: entry.text,
          style: preset.styleFor(),
          referenceHeight: referenceHeight,
          fontFamilyFallback: const ['Noto Sans SC', 'Noto Sans CJK Fallback'],
          opticalOffsetEm: subtitlePresetOpticalOffsetEm(
            preset.primaryFont,
            entry.text,
          ),
          alignLatinBody: false,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: preset.backgroundPadding,
          ),
          isGestureOnly: isGestureOnly,
          isVisualOnly: true,
        ),
      if (entry.secondaryText?.isNotEmpty ?? false)
        SubtitleOverlay(
          text: entry.secondaryText!,
          style: preset.styleFor(secondary: true),
          referenceHeight: referenceHeight,
          fontFamilyFallback: const ['Noto Sans SC', 'Noto Sans CJK Fallback'],
          opticalOffsetEm: subtitlePresetOpticalOffsetEm(
            preset.secondaryFont,
            entry.secondaryText!,
          ),
          alignLatinBody: false,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: preset.backgroundPadding,
          ),
          isGestureOnly: isGestureOnly,
          isVisualOnly: true,
        ),
    ];
    final ordered = preset.secondaryFirst ? blocks.reversed.toList() : blocks;
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < ordered.length; i++) ...[
            if (i > 0)
              SizedBox(
                height: preset.gap * referenceHeight / kSubtitleReferenceHeight,
              ),
            ordered[i],
          ],
        ],
      ),
    );
  }
}

class SubtitleOverlay extends StatelessWidget {
  final String? language;
  final String? secondaryLanguage;
  final String text; // Primary text (or all text if single file + no split)
  final String? secondaryText; // Explicit secondary text
  final Uint8List? image; // New: Support for bitmap subtitles
  final SubtitleStyle style;
  final List<String>? fontFamilyFallback;
  final EdgeInsets contentPadding;

  /// Optical correction moves fill, outline and shadow together within the
  /// unchanged line box. It must scale with the resolved font size.
  final double opticalOffsetEm;
  final bool alignLatinBody;
  final double? referenceHeight;
  final bool isDragging;
  final bool isGestureOnly; // Transparent content for a position surface.
  final bool isVisualOnly;

  const SubtitleOverlay({
    this.language,
    this.secondaryLanguage,
    super.key,
    required this.text,
    this.secondaryText,
    this.image,
    this.style = const SubtitleStyle(),
    this.fontFamilyFallback,
    this.opticalOffsetEm = 0,
    this.alignLatinBody = true,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 12,
      vertical: 6,
    ),
    this.referenceHeight,
    this.isDragging = false,
    this.isGestureOnly = false,
    this.isVisualOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty &&
        (secondaryText == null || secondaryText!.isEmpty) &&
        image == null &&
        !isDragging) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final double resolvedReferenceHeight =
            referenceHeight ??
            ((constraints.maxHeight != double.infinity &&
                    constraints.maxHeight > 0)
                ? constraints.maxHeight
                : kSubtitleReferenceHeight);
        final SubtitleResolvedStyleMetrics resolvedMetrics =
            SubtitleResolvedStyleMetrics.fromStyle(
              style,
              referenceHeight: resolvedReferenceHeight,
            );
        final double scale = resolvedMetrics.scale;
        final SubtitleStyle scaledStyle = resolvedMetrics.applyToStyle(style);

        // In drag mode, show placeholder if text is empty and no image
        final displayText = (text.isEmpty && image == null && isDragging)
            ? "字幕位置预览\nSubtitle Preview"
            : text;

        // If Gesture Only, use transparent colors
        final effectiveStyle = isGestureOnly
            ? scaledStyle.copyWith(
                textColor: Colors.transparent,
                backgroundColor: Colors.transparent,
                borderColor: Colors.transparent,
                shadowColor: Colors.transparent,
                backgroundOpacity: 0,
              )
            : scaledStyle;

        final trackLeading = image == null && alignLatinBody
            ? _outerTrackLeading(
                displayText,
                effectiveStyle,
                (constraints.maxWidth - contentPadding.horizontal * scale)
                    .clamp(0.0, double.infinity),
                direction: Directionality.of(context),
                locale: Localizations.maybeLocaleOf(context),
              )
            : EdgeInsets.zero;

        Widget content = RepaintBoundary(
          child: image != null
              ? _ContainedSubtitleImage(
                  bytes: image!,
                  maxWidth: constraints.maxWidth,
                  maxHeight: constraints.maxHeight,
                )
              : Container(
                  padding: contentPadding * scale + trackLeading,
                  decoration: BoxDecoration(
                    color: effectiveStyle.backgroundColor.withValues(
                      alpha: effectiveStyle.backgroundEnabled
                          ? effectiveStyle.backgroundOpacity
                          : 0,
                    ),
                    borderRadius: BorderRadius.circular(8 * scale),
                  ),
                  child: Transform.translate(
                    offset: Offset(
                      0,
                      opticalOffsetEm * effectiveStyle.fontSize,
                    ),
                    child: effectiveStyle.hasBorder
                        ? Stack(
                            children: [
                              _buildContent(
                                displayText,
                                effectiveStyle,
                                isStroke: true,
                              ),
                              _buildContent(
                                displayText,
                                effectiveStyle,
                                isStroke: false,
                              ),
                            ],
                          )
                        : _buildContent(
                            displayText,
                            effectiveStyle,
                            isStroke: false,
                          ),
                  ),
                ),
        );

        return IgnorePointer(child: content);
      },
    );
  }

  Widget _buildContent(
    String text,
    SubtitleStyle style, {
    required bool isStroke,
  }) {
    // Each track retains its own baseline/line height and optical correction.
    // A Latin secondary track must not translate the primary Chinese track.
    if (secondaryText != null && secondaryText!.isNotEmpty) {
      final secFontSize = style.secondaryFontSize ?? style.fontSize;
      final secStyle = style.copyWith(fontSize: secFontSize);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (text.isNotEmpty)
            _paragraph(text, style, isStroke: isStroke, language: language),
          _paragraph(
            secondaryText!,
            secStyle,
            isStroke: isStroke,
            language: secondaryLanguage,
            height: SubtitleResolvedStyleMetrics.resolveLineHeight(
              lineSpacing: style.lineSpacing,
              fontSize: secFontSize,
            ),
          ),
        ],
      );
    }
    if (_hasMixedSourceLines(text)) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final line in text.split('\n'))
            _paragraph(line, style, isStroke: isStroke, language: language),
        ],
      );
    }
    return _paragraph(text, style, isStroke: isStroke, language: language);
  }

  bool _hasMixedSourceLines(String text) {
    final lines = text.split('\n');
    return lines.length > 1 &&
        lines.every((line) => line.trim().isNotEmpty) &&
        lines.any(isLatinSubtitleText) &&
        lines.any((line) => !isLatinSubtitleText(line));
  }

  Widget _paragraph(
    String text,
    SubtitleStyle style, {
    required bool isStroke,
    String? language,
    double? height,
  }) {
    return _WrappedSubtitleRichText(
      textAlign: TextAlign.center,
      text: _paragraphSpan(
        text,
        style,
        isStroke: isStroke,
        language: language,
        height: height,
      ),
      alignLatinBody: alignLatinBody,
    );
  }

  TextSpan _paragraphSpan(
    String text,
    SubtitleStyle style, {
    required bool isStroke,
    String? language,
    double? height,
  }) {
    final lines = text.split('\n');
    final spans = <InlineSpan>[];
    for (int i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: "\n"));
      spans.add(
        TextSpan(
          children: _buildSpans(
            lines[i],
            style,
            isStroke: isStroke,
            language: language,
          ),
        ),
      );
    }

    return TextSpan(
      style: height == null ? null : TextStyle(height: height),
      children: spans,
    );
  }

  EdgeInsets _outerTrackLeading(
    String text,
    SubtitleStyle style,
    double maxWidth, {
    required TextDirection direction,
    Locale? locale,
  }) {
    var secondary = secondaryText;
    final splitSource =
        (secondary == null || secondary.isEmpty) && _hasMixedSourceLines(text);
    if (splitSource) {
      final lines = text.split('\n');
      text = lines.first;
      secondary = lines.last;
    }
    if (text.trim().isEmpty ||
        secondary == null ||
        secondary.trim().isEmpty ||
        !(isLatinSubtitleText(text) || isLatinSubtitleText(secondary)) ||
        maxWidth <= 0) {
      return EdgeInsets.zero;
    }
    final secondarySize = splitSource
        ? style.fontSize
        : style.secondaryFontSize ?? style.fontSize;
    final painters = [
      TextPainter(
        text: _paragraphSpan(text, style, isStroke: false, language: language),
        textDirection: direction,
        locale: locale,
      ),
      TextPainter(
        text: _paragraphSpan(
          secondary,
          style.copyWith(fontSize: secondarySize),
          isStroke: false,
          language: splitSource ? language : secondaryLanguage,
          height: splitSource
              ? null
              : SubtitleResolvedStyleMetrics.resolveLineHeight(
                  lineSpacing: style.lineSpacing,
                  fontSize: secondarySize,
                ),
        ),
        textDirection: direction,
        locale: locale,
      ),
    ];
    try {
      for (final painter in painters) {
        painter.text = layoutSubtitleText(
          painter.text!,
          maxWidth: maxWidth,
        ).text;
        painter.layout(maxWidth: maxWidth);
      }
      final first = painters.first.computeLineMetrics().first.height;
      final last = painters.last.computeLineMetrics().last.height;
      // Only the outside leading is equalized. Internal line spacing, glyph
      // size and the primary/secondary baseline separation remain intact.
      return first >= last
          ? EdgeInsets.only(bottom: (first - last) / 2)
          : EdgeInsets.only(top: (last - first) / 2);
    } finally {
      for (final painter in painters) {
        painter.dispose();
      }
    }
  }

  List<TextSpan> _buildSpans(
    String text,
    SubtitleStyle style, {
    required bool isStroke,
    String? language,
  }) => [
    for (final run in resolveSubtitleFontRuns(
      text,
      style.textStyle,
      language: language,
    ))
      _createSpan(run.text, run.font, style, isStroke),
  ];

  TextSpan _createSpan(
    String text,
    SubtitleFontChoice font,
    SubtitleStyle style,
    bool isStroke,
  ) {
    TextStyle ts = style.getTextStyle(
      overrideFontFamily: font.family,
      overrideFontWeight: font.fontWeight,
    );

    ts = ts.copyWith(
      fontFamilyFallback: fontFamilyFallback,
      fontVariations: font.fontVariations,
    );

    if (isStroke) {
      final double effectiveBorderWidth = style.effectiveBorderWidth;
      ts = ts.copyWith(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..strokeWidth = effectiveBorderWidth
          ..color = style.borderColor,
      );
    } else {
      final Offset effectiveShadowOffset = style.effectiveShadowOffset;
      final double effectiveShadowBlur = style.effectiveShadowBlur;
      if (style.hasShadow) {
        ts = ts.copyWith(
          shadows: [
            Shadow(
              offset: effectiveShadowOffset,
              blurRadius: effectiveShadowBlur,
              color: style.shadowColor,
            ),
          ],
        );
      }
    }
    return TextSpan(text: text, style: ts);
  }
}

class _WrappedSubtitleRichText extends StatelessWidget {
  final InlineSpan text;
  final TextAlign textAlign;
  final bool alignLatinBody;

  const _WrappedSubtitleRichText({
    required this.text,
    required this.textAlign,
    this.alignLatinBody = false,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final direction = Directionality.of(context);
      final locale = Localizations.maybeLocaleOf(context);
      final layout = layoutSubtitleText(
        text,
        maxWidth: constraints.maxWidth,
        textDirection: direction,
        locale: locale,
      );
      final child = RichText(
        text: layout.text,
        textAlign: textAlign,
        textDirection: direction,
        locale: locale,
      );
      if (!alignLatinBody) return child;
      final painter = TextPainter(
        text: layout.text,
        textDirection: direction,
        textAlign: textAlign,
        locale: locale,
      );
      try {
        painter.layout(maxWidth: constraints.maxWidth);
        final offset = subtitleLatinOpticalShift(
          layout.text,
          painter,
          bodyCenter: SubtitleFontService.instance.latinBodyCenter,
        );
        return offset == 0
            ? child
            : Transform.translate(offset: Offset(0, offset), child: child);
      } finally {
        painter.dispose();
      }
    },
  );
}

/// Sizes a bitmap subtitle to the contained image instead of the full viewport,
/// so the edit frame and the drag travel match the visible picture.
class _ContainedSubtitleImage extends StatefulWidget {
  final Uint8List bytes;
  final double maxWidth;
  final double maxHeight;

  const _ContainedSubtitleImage({
    required this.bytes,
    required this.maxWidth,
    required this.maxHeight,
  });

  @override
  State<_ContainedSubtitleImage> createState() =>
      _ContainedSubtitleImageState();
}

class _ContainedSubtitleImageState extends State<_ContainedSubtitleImage> {
  Size? _intrinsic;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(_ContainedSubtitleImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) _decode();
  }

  Future<void> _decode() async {
    final int request = ++_request;
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(widget.bytes);
      final ui.FrameInfo frame = await codec.getNextFrame();
      final Size size = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      codec.dispose();
      if (!mounted || request != _request) return;
      setState(() => _intrinsic = size);
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() => _intrinsic = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size? intrinsic = _intrinsic;
    final double maxWidth = widget.maxWidth.isFinite ? widget.maxWidth : 0;
    final double maxHeight = widget.maxHeight.isFinite ? widget.maxHeight : 0;
    if (intrinsic == null ||
        intrinsic.width <= 0 ||
        intrinsic.height <= 0 ||
        maxWidth <= 0 ||
        maxHeight <= 0) {
      return const SizedBox.shrink();
    }
    final Size fitted = applyBoxFit(
      BoxFit.contain,
      intrinsic,
      Size(maxWidth, maxHeight),
    ).destination;
    return SizedBox(
      width: fitted.width,
      height: fitted.height,
      child: Image.memory(
        widget.bytes,
        gaplessPlayback: true,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.medium,
      ),
    );
  }
}
