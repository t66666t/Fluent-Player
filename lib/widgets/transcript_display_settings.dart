import 'dart:async';

import 'package:flutter/material.dart';

import '../models/transcript_typography.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';

/// Floating transcript controls. Only the active slider stays opaque while
/// dragging; keeping the same children mounted preserves its gesture session.
class TranscriptDisplaySettings extends StatefulWidget {
  const TranscriptDisplaySettings({
    super.key,
    required this.fontSizeScale,
    required this.onFontSizeChanged,
    required this.onFontSizeCommitted,
    required this.fontWeight,
    required this.onFontWeightChanged,
    required this.onFontWeightCommitted,
    required this.locatePositionEditor,
    required this.isArticleMode,
    required this.paragraphModeEnabled,
    required this.onParagraphModeChanged,
    required this.sentenceCountEditor,
    required this.showTimestamps,
    required this.onShowTimestampsChanged,
    required this.timeColumnRatio,
    required this.onTimeColumnRatioChanged,
    required this.onTimeColumnRatioCommitted,
    required this.showDividers,
    required this.onShowDividersChanged,
  });

  final double fontSizeScale;
  final ValueChanged<double> onFontSizeChanged;
  final ValueChanged<double> onFontSizeCommitted;
  final double fontWeight;
  final ValueChanged<double> onFontWeightChanged;
  final ValueChanged<double> onFontWeightCommitted;
  final Widget locatePositionEditor;
  final bool isArticleMode;
  final bool paragraphModeEnabled;
  final ValueChanged<bool> onParagraphModeChanged;
  final Widget sentenceCountEditor;
  final bool showTimestamps;
  final ValueChanged<bool> onShowTimestampsChanged;
  final double timeColumnRatio;
  final ValueChanged<double> onTimeColumnRatioChanged;
  final ValueChanged<double> onTimeColumnRatioCommitted;
  final bool showDividers;
  final ValueChanged<bool> onShowDividersChanged;

  @override
  State<TranscriptDisplaySettings> createState() =>
      _TranscriptDisplaySettingsState();
}

enum _DisplaySlider { fontSize, fontWeight, timeColumn }

class _TranscriptDisplaySettingsState extends State<TranscriptDisplaySettings> {
  _DisplaySlider? _activeSlider;

  @override
  void didUpdateWidget(TranscriptDisplaySettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_activeSlider == _DisplaySlider.timeColumn &&
        (widget.isArticleMode || !widget.showTimestamps)) {
      _activeSlider = null;
    }
  }

  Widget _fade(Widget child, {_DisplaySlider? slider, Key? key}) =>
      _PreviewFade(
        key: key,
        dimmed: _activeSlider != null && _activeSlider != slider,
        child: child,
      );

  void _setDragging(_DisplaySlider slider, bool dragging) {
    final next = dragging ? slider : null;
    if (!mounted || (!dragging && _activeSlider != slider)) return;
    if (_activeSlider != next) setState(() => _activeSlider = next);
  }

  Widget _slider({
    required _DisplaySlider id,
    required String keyName,
    required double value,
    required double min,
    required double max,
    required String label,
    required bool showValue,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onCommit,
  }) => _fade(
    _DisplaySettingSlider(
      key: ValueKey('$keyName-control'),
      sliderKey: ValueKey(keyName),
      value: value,
      min: min,
      max: max,
      label: label,
      showValue: showValue,
      dimValue: _activeSlider != null,
      onChanged: onChanged,
      onCommit: onCommit,
      onDraggingChanged: (dragging) => _setDragging(id, dragging),
    ),
    slider: id,
    key: ValueKey('$keyName-preview'),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: _fade(
            DecoratedBox(
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  Colors.white.withValues(alpha: 0.05),
                  AppTokens.bgPlayerSidebar,
                ),
                border: const Border(bottom: BorderSide(color: Colors.white10)),
              ),
            ),
            key: const ValueKey('subtitle-display-settings-background'),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 180;
            final labelWidth = narrow ? 24.0 : 52.0;
            Widget row(
              String label,
              String shortLabel,
              Widget child, {
              bool fadeChild = true,
              double height = 28,
            }) => SizedBox(
              height: height,
              child: Row(
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: _fade(
                      Text(
                        narrow ? shortLabel : label,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: fadeChild ? _fade(child) : child),
                ],
              ),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                row(
                  '字体',
                  '字',
                  _slider(
                    id: _DisplaySlider.fontSize,
                    keyName: 'subtitle-font-size-slider',
                    value: _fontScaleToSlider(widget.fontSizeScale),
                    min: 0,
                    max: 100,
                    label: '${(widget.fontSizeScale * 100).round()}%',
                    showValue: !narrow,
                    onChanged: (value) =>
                        widget.onFontSizeChanged(_sliderToFontScale(value)),
                    onCommit: (value) =>
                        widget.onFontSizeCommitted(_sliderToFontScale(value)),
                  ),
                  fadeChild: false,
                ),
                row(
                  '字重',
                  '重',
                  _slider(
                    id: _DisplaySlider.fontWeight,
                    keyName: 'subtitle-font-weight-slider',
                    value: widget.fontWeight,
                    min: TranscriptTypography.minFontWeight,
                    max: TranscriptTypography.maxFontWeight,
                    label: '${widget.fontWeight.round()}',
                    showValue: !narrow,
                    onChanged: (value) => widget.onFontWeightChanged(
                      TranscriptTypography.normalizeFontWeight(value),
                    ),
                    onCommit: (value) => widget.onFontWeightCommitted(
                      TranscriptTypography.normalizeFontWeight(value),
                    ),
                  ),
                  fadeChild: false,
                ),
                row('定位位置', '定位', widget.locatePositionEditor),
                if (widget.isArticleMode) ...[
                  row(
                    '段落模式',
                    '段',
                    Semantics(
                      toggled: widget.paragraphModeEnabled,
                      button: true,
                      label: '段落模式',
                      hint: '关闭后连续显示全部字幕',
                      onTap: () => widget.onParagraphModeChanged(
                        !widget.paragraphModeEnabled,
                      ),
                      child: GestureDetector(
                        key: const ValueKey('subtitle-paragraph-mode-control'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onParagraphModeChanged(
                          !widget.paragraphModeEnabled,
                        ),
                        child: Row(
                          children: [
                            Tooltip(
                              message: '关闭后连续显示全部字幕',
                              child: SizedBox(
                                width: 44,
                                height: 30,
                                child: FittedBox(
                                  child: Switch(
                                    key: const ValueKey(
                                      'subtitle-paragraph-mode-switch',
                                    ),
                                    value: widget.paragraphModeEnabled,
                                    onChanged: widget.onParagraphModeChanged,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                              ),
                            ),
                            if (!narrow)
                              const Expanded(
                                child: Text(
                                  '关闭后连续显示全部字幕',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white54,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    height: 32,
                  ),
                  row(
                    '每段',
                    '句',
                    IgnorePointer(
                      ignoring: !widget.paragraphModeEnabled,
                      child: Opacity(
                        opacity: widget.paragraphModeEnabled ? 1 : 0.45,
                        child: widget.sentenceCountEditor,
                      ),
                    ),
                  ),
                ] else ...[
                  row(
                    '时间',
                    '时',
                    Row(
                      children: [
                        _fade(
                          _toggle(
                            keyName: 'subtitle-show-time-switch',
                            value: widget.showTimestamps,
                            tooltip: widget.showTimestamps ? '隐藏时间' : '显示时间',
                            onChanged: widget.onShowTimestampsChanged,
                          ),
                        ),
                        if (widget.showTimestamps) ...[
                          const SizedBox(width: 4),
                          if (!narrow)
                            _fade(
                              const SizedBox(
                                width: 36,
                                child: Text(
                                  '宽度',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                            ),
                          Expanded(
                            child: _slider(
                              id: _DisplaySlider.timeColumn,
                              keyName: 'subtitle-time-column-slider',
                              value: widget.timeColumnRatio,
                              min: 0.05,
                              max: 0.30,
                              label:
                                  '${(widget.timeColumnRatio * 100).round()}%',
                              showValue: !narrow,
                              onChanged: widget.onTimeColumnRatioChanged,
                              onCommit: widget.onTimeColumnRatioCommitted,
                            ),
                          ),
                        ],
                      ],
                    ),
                    fadeChild: false,
                  ),
                  row(
                    '分割线',
                    '线',
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _toggle(
                        keyName: 'subtitle-show-dividers-switch',
                        value: widget.showDividers,
                        tooltip: widget.showDividers ? '隐藏分割线' : '显示分割线',
                        onChanged: widget.onShowDividersChanged,
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    ],
  );

  Widget _toggle({
    required String keyName,
    required bool value,
    required String tooltip,
    required ValueChanged<bool> onChanged,
  }) => Tooltip(
    message: tooltip,
    child: Semantics(
      label: tooltip,
      toggled: value,
      child: InkWell(
        key: ValueKey(keyName),
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(!value),
        child: SizedBox(
          width: 20,
          height: 20,
          child: Icon(
            value ? Icons.circle : Icons.circle_outlined,
            size: 12,
            color: value ? Colors.blueAccent : Colors.white38,
          ),
        ),
      ),
    ),
  );
}

class _PreviewFade extends StatelessWidget {
  const _PreviewFade({super.key, required this.dimmed, required this.child});
  final bool dimmed;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: dimmed,
    child: AnimatedOpacity(
      opacity: dimmed ? 0.06 : 1,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 180),
      curve: Curves.easeInOutCubic,
      child: child,
    ),
  );
}

double _fontScaleToSlider(double scale) {
  final value = scale.clamp(0.5, 3.0);
  if (value <= 0.7) return ((value - 0.5) / 0.2) * 10;
  if (value <= 1) return 10 + ((value - 0.7) / 0.3) * 60;
  return 70 + ((value - 1) / 2) * 30;
}

double _sliderToFontScale(double value) {
  if (value <= 10) return 0.5 + value / 10 * 0.2;
  if (value <= 70) return 0.7 + (value - 10) / 60 * 0.3;
  return 1 + (value - 70) / 30 * 2;
}

class _DisplaySettingSlider extends StatefulWidget {
  const _DisplaySettingSlider({
    super.key,
    required this.sliderKey,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.showValue,
    required this.dimValue,
    required this.onChanged,
    required this.onCommit,
    required this.onDraggingChanged,
  });
  final Key sliderKey;
  final double value;
  final double min;
  final double max;
  final String label;
  final bool showValue;
  final bool dimValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final ValueChanged<bool> onDraggingChanged;

  @override
  State<_DisplaySettingSlider> createState() => _DisplaySettingSliderState();
}

class _DisplaySettingSliderState extends State<_DisplaySettingSlider> {
  double? _dragValue;
  double? _hapticStartValue;
  int? _interactionPointer;
  bool _active = true;
  bool _dragging = false;
  ValueChanged<double>? _interactionCommit;

  @override
  void deactivate() {
    _active = false;
    _finishDrag(_dragValue ?? widget.value);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  void _finishPointer(PointerEvent event) {
    if (!_active || _interactionPointer != event.pointer) return;
    _interactionPointer = null;
    _finishDrag(_dragValue ?? widget.value);
  }

  void _finishDrag(double value) {
    if (!_dragging) return;
    _dragging = false;
    _interactionPointer = null;
    if (_active && _hapticStartValue != null && value != _hapticStartValue) {
      unawaited(AppHaptics.dragCommitted(SettingsService()));
    }
    _hapticStartValue = null;
    if (_active) {
      setState(() => _dragValue = null);
      widget.onDraggingChanged(false);
    } else {
      _dragValue = null;
    }
    // Deactivation need not produce Slider.onChangeEnd. Commit once even when
    // a held control is removed, after the tree unlocks, to its original setting.
    final commit = _interactionCommit ?? widget.onCommit;
    _interactionCommit = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => commit(value));
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    child: Row(
      children: [
        Expanded(
          child: Listener(
            // Slider normally ends both completed and cancelled gestures. These
            // also restore the panel if the pointer is interrupted by the OS.
            onPointerDown: (event) => _interactionPointer ??= event.pointer,
            onPointerUp: _finishPointer,
            onPointerCancel: _finishPointer,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                key: widget.sliderKey,
                value: (_dragValue ?? widget.value).clamp(
                  widget.min,
                  widget.max,
                ),
                min: widget.min,
                max: widget.max,
                activeColor: Colors.blueAccent,
                inactiveColor: Colors.white24,
                onChangeStart: (value) {
                  _dragging = true;
                  _interactionCommit = widget.onCommit;
                  _hapticStartValue = value;
                  unawaited(AppHaptics.dragStarted(SettingsService()));
                  setState(() => _dragValue = value);
                  widget.onDraggingChanged(true);
                },
                onChanged: (value) {
                  setState(() => _dragValue = value);
                  widget.onChanged(value);
                },
                onChangeEnd: _finishDrag,
              ),
            ),
          ),
        ),
        if (widget.showValue)
          _PreviewFade(
            dimmed: widget.dimValue,
            child: SizedBox(
              width: 34,
              child: Text(
                widget.label,
                style: const TextStyle(fontSize: 10, color: Colors.white60),
                textAlign: TextAlign.right,
              ),
            ),
          ),
      ],
    ),
  );
}
