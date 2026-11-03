import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/bilibili_browse_models.dart';
import '../theme/app_tokens.dart';
import 'capsule_option.dart';
import 'dialog_keyboard_viewport.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<BilibiliVideoDurationRange?> showBilibiliDurationPicker({
  required BuildContext context,
  required BilibiliVideoDurationRange selected,
}) => showDialog<BilibiliVideoDurationRange>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.28),
  builder: (_) => BilibiliDurationPicker(selected: selected),
);

class BilibiliDurationPicker extends StatefulWidget {
  const BilibiliDurationPicker({super.key, required this.selected});

  final BilibiliVideoDurationRange selected;

  @override
  State<BilibiliDurationPicker> createState() => _BilibiliDurationPickerState();
}

class _BilibiliDurationPickerState extends State<BilibiliDurationPicker> {
  static const _presets = <(String, BilibiliVideoDurationRange)>[
    ('全部', BilibiliVideoDurationRange()),
    ('5 分钟内', BilibiliVideoDurationRange(maximumSeconds: 300)),
    ('10 分钟内', BilibiliVideoDurationRange(maximumSeconds: 600)),
    (
      '10～30 分钟',
      BilibiliVideoDurationRange(minimumSeconds: 600, maximumSeconds: 1800),
    ),
    (
      '30～60 分钟',
      BilibiliVideoDurationRange(minimumSeconds: 1800, maximumSeconds: 3600),
    ),
    ('1 小时以上', BilibiliVideoDurationRange(minimumSeconds: 3600)),
  ];

  final _minimumMinutes = TextEditingController();
  final _minimumSeconds = TextEditingController();
  final _maximumMinutes = TextEditingController();
  final _maximumSeconds = TextEditingController();
  late BilibiliVideoDurationRange _range;
  double _sliderMaximum = 7200;
  String? _error;

  @override
  void initState() {
    super.initState();
    _setRange(widget.selected);
  }

  @override
  void dispose() {
    for (final controller in [
      _minimumMinutes,
      _minimumSeconds,
      _maximumMinutes,
      _maximumSeconds,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _setRange(BilibiliVideoDurationRange range, {bool resizeSlider = true}) {
    _range = range;
    _error = null;
    _minimumMinutes.text = '${range.minimumSeconds ~/ 60}';
    _minimumSeconds.text = '${range.minimumSeconds % 60}';
    final maximum = range.maximumSeconds;
    _maximumMinutes.text = maximum == null ? '' : '${maximum ~/ 60}';
    _maximumSeconds.text = maximum == null ? '' : '${maximum % 60}';
    if (resizeSlider) {
      final extent = math.max(range.minimumSeconds, maximum ?? 7200);
      _sliderMaximum = math.max(1800, (extent / 60).ceil() * 60).toDouble();
    }
  }

  ({BilibiliVideoDurationRange? range, String? error}) _readRange() {
    int? read(TextEditingController minutes, TextEditingController seconds) {
      final m = int.tryParse(minutes.text.isEmpty ? '0' : minutes.text);
      final s = int.tryParse(seconds.text.isEmpty ? '0' : seconds.text);
      if (m == null ||
          s == null ||
          m < 0 ||
          s < 0 ||
          s > 59 ||
          m > (0x7FFFFFFFFFFFFFFF - 59) ~/ 60) {
        return null;
      }
      return m * 60 + s;
    }

    final minimum = read(_minimumMinutes, _minimumSeconds);
    final unbounded =
        _maximumMinutes.text.isEmpty && _maximumSeconds.text.isEmpty;
    final maximum = unbounded ? null : read(_maximumMinutes, _maximumSeconds);
    if (minimum == null || !unbounded && maximum == null) {
      return (range: null, error: '请输入有效分钟数，秒数为 0～59');
    }
    if (maximum != null && maximum < minimum) {
      return (range: null, error: '最长时长不能小于最短时长');
    }
    return (
      range: BilibiliVideoDurationRange(
        minimumSeconds: minimum,
        maximumSeconds: maximum,
      ),
      error: null,
    );
  }

  void _edited(String _) {
    final draft = _readRange();
    setState(() {
      _error = draft.error;
      if (draft.range case final range?) {
        _range = range;
        final extent = math.max(
          range.minimumSeconds,
          range.maximumSeconds ?? 0,
        );
        _sliderMaximum = math
            .max(_sliderMaximum, (extent / 60).ceil() * 60)
            .toDouble();
      }
    });
  }

  void _nudge(bool minimum, int delta) {
    final draft = _readRange().range;
    if (draft == null) return;
    final before = minimum
        ? draft.minimumSeconds
        : draft.maximumSeconds ?? math.max(draft.minimumSeconds, 7200);
    final after = math.max(0, before + delta);
    setState(
      () => _setRange(
        BilibiliVideoDurationRange(
          minimumSeconds: minimum
              ? math.min(after, draft.maximumSeconds ?? after)
              : draft.minimumSeconds,
          maximumSeconds: minimum
              ? draft.maximumSeconds
              : math.max(after, draft.minimumSeconds),
        ),
      ),
    );
  }

  void _slide(RangeValues values) {
    final minimumMoved = (values.start - _range.minimumSeconds).abs() >= 0.5;
    var minimum = !minimumMoved
        ? _range.minimumSeconds
        : (values.start / 60).round() * 60;
    var maximum = _range.maximumSeconds == null && values.end == _sliderMaximum
        ? null
        : _range.maximumSeconds != null &&
              (values.end - _range.maximumSeconds!).abs() < 0.5
        ? _range.maximumSeconds
        : (values.end / 60).round() * 60;
    if (maximum != null && minimum > maximum) {
      if (minimumMoved) {
        minimum = maximum;
      } else {
        maximum = minimum;
      }
    }
    setState(
      () => _setRange(
        BilibiliVideoDurationRange(
          minimumSeconds: minimum,
          maximumSeconds: maximum,
        ),
        resizeSlider: false,
      ),
    );
  }

  Widget _bound({required bool minimum}) {
    final minutes = minimum ? _minimumMinutes : _maximumMinutes;
    final seconds = minimum ? _minimumSeconds : _maximumSeconds;
    final prefix = minimum ? 'minimum' : 'maximum';
    Widget field(TextEditingController controller, String unit, String part) =>
        TextField(
          key: ValueKey('duration-$prefix-$part'),
          controller: controller,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: _edited,
          style: const TextStyle(
            color: AppTokens.text1,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            labelText: unit,
            hintText: minimum ? '0' : '不限',
            labelStyle: const TextStyle(color: AppTokens.text2),
            hintStyle: const TextStyle(color: AppTokens.text3, fontSize: 14),
            filled: true,
            fillColor: AppTokens.bgRaised,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppTokens.lineSubtle),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppTokens.brandBilibili),
            ),
          ),
        );
    final bound = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              minimum ? '最短时长' : '最长时长',
              style: const TextStyle(
                color: AppTokens.text1,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            DesktopButtonClickRegion(child: TextButton(
              onPressed: () => setState(() {
                minutes.text = minimum ? '0' : '';
                seconds.text = minimum ? '0' : '';
                final draft = _readRange();
                _error = draft.error;
                if (draft.range case final range?) _setRange(range);
              }),
              style: TextButton.styleFrom(
                foregroundColor: AppTokens.brandBilibili,
                shape: const StadiumBorder(),
              ),
              child: Text(minimum ? '从 0 开始' : '不限'),
            )),
          ],
        ),
        Row(
          children: [
            Expanded(child: field(minutes, '分钟', 'minutes')),
            const SizedBox(width: 10),
            Expanded(child: field(seconds, '秒', 'seconds')),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final delta in [-60, -1, 1, 60]) ...[
              Expanded(
                child: CapsuleOption(
                  key: ValueKey('duration-$prefix-nudge-$delta'),
                  onTap: () => _nudge(minimum, delta),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '${delta > 0 ? '+' : '−'}${delta.abs() == 60 ? '1 分' : '1 秒'}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTokens.text2,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              if (delta != 60) const SizedBox(width: 4),
            ],
          ],
        ),
      ],
    );
    return TextFieldTapRegion(child: bound);
  }

  @override
  Widget build(BuildContext context) {
    return DialogKeyboardViewport(
      child: Dialog(
        insetAnimationDuration: Duration.zero,
        backgroundColor: AppTokens.bgOverlay,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '视频时长',
                        style: TextStyle(
                          color: AppTokens.text1,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    DesktopButtonClickRegion(child: IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTokens.text2,
                      ),
                    )),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 8,
                        children: [
                          for (final preset in _presets)
                            CapsuleOption(
                              key: ValueKey('duration-preset-${preset.$1}'),
                              color: _error == null && _range == preset.$2
                                  ? AppTokens.brandBilibili.withValues(
                                      alpha: 0.16,
                                    )
                                  : AppTokens.bgCard,
                              onTap: () => setState(() => _setRange(preset.$2)),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              child: Text(
                                preset.$1,
                                style: TextStyle(
                                  color: _error == null && _range == preset.$2
                                      ? AppTokens.brandBilibili
                                      : AppTokens.text2,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _range.label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppTokens.brandBilibili,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: AppTokens.brandBilibili,
                          thumbColor: AppTokens.brandBilibili,
                          overlayColor: AppTokens.brandBilibili.withValues(
                            alpha: 0.12,
                          ),
                          inactiveTrackColor: AppTokens.bgCard,
                        ),
                        child: RangeSlider(
                          key: const ValueKey('duration-range-slider'),
                          min: 0,
                          max: _sliderMaximum,
                          values: RangeValues(
                            _range.minimumSeconds.toDouble().clamp(
                              0,
                              _sliderMaximum,
                            ),
                            (_range.maximumSeconds?.toDouble() ??
                                    _sliderMaximum)
                                .clamp(0, _sliderMaximum),
                          ),
                          semanticFormatterCallback: (value) =>
                              BilibiliVideoDurationRange.formatSeconds(
                                value.round(),
                              ),
                          onChanged: _slide,
                        ),
                      ),
                      const Text(
                        '滑动粗调，输入精确到秒',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTokens.text3, fontSize: 12),
                      ),
                      const SizedBox(height: 12),
                      _bound(minimum: true),
                      const SizedBox(height: 12),
                      _bound(minimum: false),
                      const SizedBox(height: 8),
                      Text(
                        _error ?? '最长时长留空表示不限；范围包含起止时长。',
                        key: const ValueKey('duration-validation'),
                        style: TextStyle(
                          color: _error == null
                              ? AppTokens.text3
                              : AppTokens.danger,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: DesktopButtonClickRegion(child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTokens.text2,
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('取消'),
                      )),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DesktopButtonClickRegion(child: FilledButton(
                        key: const ValueKey('duration-apply'),
                        onPressed: _error == null
                            ? () =>
                                  Navigator.of(context).pop(_readRange().range)
                            : null,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTokens.brandBilibili,
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('应用'),
                      )),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
