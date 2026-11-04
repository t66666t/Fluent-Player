import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_library_continue_policy.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';

/// Bottom sheet for tuning continue-watching gates. Changes apply live.
class MediaLibraryContinuePolicySheet {
  const MediaLibraryContinuePolicySheet._();

  static const Color groupedBackground = AppTokens.bgRaised;
  static const Color groupedCard = AppTokens.bgOverlay;
  static const Color iosBlue = AppTokens.accent;
  static const Color secondaryLabel = Color(0x99EBEBF5);
  static const Color tertiaryLabel = Color(0x4DEBEBF5);

  static Future<void> show(BuildContext context) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => const _ContinuePolicySheetBody(),
    );
  }
}

class _ContinuePolicySheetBody extends StatelessWidget {
  const _ContinuePolicySheetBody();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final policy = settings.continueWatchPolicy;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    // UI only has two stories: easier-of-two vs both. Stored `either` is the
    // same math as `shorter` once both numbers are set.
    final combineForUi = policy.combineMode == ContinueWatchCombineMode.both
        ? ContinueWatchCombineMode.both
        : ContinueWatchCombineMode.shorter;

    return CupertinoTheme(
      data: const CupertinoThemeData(brightness: Brightness.dark),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                color: MediaLibraryContinuePolicySheet.groupedBackground,
                borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 36,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '继续观看门槛',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.4,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            '完成',
                            style: TextStyle(
                              color: MediaLibraryContinuePolicySheet.iosBlue,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                      children: [
                        const Text(
                          '只影响「只看未完成」列表：点开预览不会出现，实际看够一段时间才会进来。暂停、拖进度、缓冲不累计；倍速按真实经过的时间算。',
                          style: TextStyle(
                            color: MediaLibraryContinuePolicySheet.secondaryLabel,
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '当前：${policy.compactLabel}',
                          style: const TextStyle(
                            color: MediaLibraryContinuePolicySheet.tertiaryLabel,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                        const _SectionLabel('认真看过多久才算数'),
                        _GroupedCard(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                CupertinoSlidingSegmentedControl<
                                  ContinueWatchCombineMode
                                >(
                                  groupValue: combineForUi,
                                  thumbColor: const Color(0xFF636366),
                                  backgroundColor: const Color(0xFF1C1C1E),
                                  children: const {
                                    ContinueWatchCombineMode.shorter: Text(
                                      '取更容易的',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                    ContinueWatchCombineMode.both: Text(
                                      '两项都要',
                                      style: TextStyle(fontSize: 13),
                                    ),
                                  },
                                  onValueChanged: (mode) {
                                    if (mode == null) return;
                                    _save(
                                      settings,
                                      policy.copyWith(combineMode: mode),
                                    );
                                  },
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  combineForUi == ContinueWatchCombineMode.both
                                      ? '秒数和比例都达到，才算认真看过。'
                                      : '短片按「占片长」、长片按「最少看满」，用更容易达到的那个。',
                                  style: const TextStyle(
                                    color: MediaLibraryContinuePolicySheet
                                        .tertiaryLabel,
                                    fontSize: 12,
                                    height: 1.35,
                                  ),
                                ),
                                _SteppedDurationSlider(
                                  title: '最少看满',
                                  hint: '真实经过的观看时间，不是进度条位置。点按数字可直接填写。',
                                  stepsMs: ContinueWatchSliderSteps.minWatchMs,
                                  valueMs: policy.minWatchMs,
                                  maxMs: ContinueWatchPolicy.minWatchMsMax,
                                  onChanged: (ms) => _save(
                                    settings,
                                    policy.copyWith(minWatchMs: ms),
                                  ),
                                ),
                                _PercentSlider(
                                  title: '占片长',
                                  hint: '实际观看 ÷ 片子总时长。10 分钟片子的 20% 是 2 分钟。点按数字可直接填写。',
                                  fraction: policy.minDurationFraction,
                                  maxFraction: ContinueWatchPolicy
                                      .minDurationFractionMax,
                                  onChanged: (fraction) => _save(
                                    settings,
                                    policy.copyWith(
                                      minDurationFraction: fraction,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  _examples(policy),
                                  key: const ValueKey('continuePolicyExamples'),
                                  style: const TextStyle(
                                    color: MediaLibraryContinuePolicySheet
                                        .secondaryLabel,
                                    fontSize: 12,
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const _SectionLabel('不想看到的'),
                        _GroupedCard(
                          child: Column(
                            children: [
                              _IosSwitchRow(
                                title: '排除已看完',
                                subtitle: '播到结尾的片子不再出现在未完成里。',
                                value: policy.excludeCompleted,
                                onChanged: (value) => _save(
                                  settings,
                                  policy.copyWith(excludeCompleted: value),
                                ),
                              ),
                              const _Hairline(),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  4,
                                  12,
                                  10,
                                ),
                                child: Column(
                                  children: [
                                    _PercentSlider(
                                      title: '播放进度不到就不列',
                                      hint: '看进度条走到哪里，和上面「实际看了多久」不是一回事。点按数字可直接填写。',
                                      fraction: policy.minProgressFraction,
                                      maxFraction: ContinueWatchPolicy
                                          .minProgressFractionMax,
                                      onChanged: (fraction) => _save(
                                        settings,
                                        policy.copyWith(
                                          minProgressFraction: fraction,
                                        ),
                                      ),
                                    ),
                                    _SteppedDurationSlider(
                                      title: '还剩这么短就隐藏',
                                      hint: '快看完的片子从列表里拿掉。点按数字可直接填写。',
                                      stepsMs: ContinueWatchSliderSteps
                                          .remainingOrItemMs,
                                      valueMs: policy.hideRemainingBelowMs,
                                      maxMs: ContinueWatchPolicy
                                          .hideRemainingBelowMsMax,
                                      onChanged: (ms) => _save(
                                        settings,
                                        policy.copyWith(
                                          hideRemainingBelowMs: ms,
                                        ),
                                      ),
                                    ),
                                    _SteppedDurationSlider(
                                      title: '片子太短不列入',
                                      hint: '总时长短于这个数的不进未完成。点按数字可直接填写。',
                                      stepsMs: ContinueWatchSliderSteps
                                          .remainingOrItemMs,
                                      valueMs: policy.minItemDurationMs,
                                      maxMs: ContinueWatchPolicy
                                          .minItemDurationMsMax,
                                      onChanged: (ms) => _save(
                                        settings,
                                        policy.copyWith(minItemDurationMs: ms),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const _SectionLabel('只看最近'),
                        _GroupedCard(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final days
                                    in ContinueWatchPolicy.maxAgeDayChoices)
                                  _IosChoiceChip(
                                    label: days == 0
                                        ? '不限'
                                        : (days == 365 ? '1年' : '$days天'),
                                    selected: policy.maxAgeDays == days,
                                    onTap: () => _save(
                                      settings,
                                      policy.copyWith(maxAgeDays: days),
                                    ),
                                  ),
                                if (!ContinueWatchPolicy.maxAgeDayChoices
                                    .contains(policy.maxAgeDays))
                                  _IosChoiceChip(
                                    label: '${policy.maxAgeDays}天',
                                    selected: true,
                                    onTap: () async {
                                      final next = await _promptAgeDays(
                                        context,
                                        policy.maxAgeDays,
                                      );
                                      if (next == null) return;
                                      _save(
                                        settings,
                                        policy.copyWith(maxAgeDays: next),
                                      );
                                    },
                                  ),
                                _IosChoiceChip(
                                  label: '自定义',
                                  selected: false,
                                  onTap: () async {
                                    final next = await _promptAgeDays(
                                      context,
                                      policy.maxAgeDays,
                                    );
                                    if (next == null) return;
                                    _save(
                                      settings,
                                      policy.copyWith(maxAgeDays: next),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        _GroupedCard(
                          child: _IosSwitchRow(
                            title: '旧记录用播放位置代替',
                            subtitle: '升级前只记下进度条、没有观看时钟的条目。',
                            value: policy.useProgressIfNoWatchClock,
                            onChanged: (value) => _save(
                              settings,
                              policy.copyWith(
                                useProgressIfNoWatchClock: value,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: CupertinoButton(
                            onPressed: () => _save(
                              settings,
                              ContinueWatchPolicy.defaults,
                            ),
                            child: const Text(
                              '恢复默认',
                              style: TextStyle(
                                color: MediaLibraryContinuePolicySheet.iosBlue,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _examples(ContinueWatchPolicy policy) {
    const tenMin = 10 * 60 * 1000;
    const thirtySec = 30 * 1000;
    final longNeed = ContinueWatchPolicy.formatDurationMs(
      policy.watchNeedMsForDuration(tenMin),
    );
    final shortNeed = ContinueWatchPolicy.formatDurationMs(
      policy.watchNeedMsForDuration(thirtySec),
    );
    if (policy.minWatchMs <= 0 && policy.minDurationFraction <= 0) {
      return '举例：现在不限制观看时长，点开过就会进入未完成（仍受下面的过滤影响）。';
    }
    return '举例：10 分钟的片子要实际看满 $longNeed；30 秒的短片要实际看满 $shortNeed。';
  }

  static void _save(SettingsService settings, ContinueWatchPolicy policy) {
    unawaited(
      settings.updateSetting(
        'mediaLibraryContinuePolicy',
        policy.toJsonString(),
      ),
    );
  }

  static Future<int?> _promptAgeDays(BuildContext context, int currentDays) {
    return _promptParsedValue<int>(
      context: context,
      title: '只看最近几天',
      hint: '输入天数，0 或不填表示不限。',
      placeholder: '例如 3',
      initialText: currentDays <= 0 ? '' : '$currentDays',
      keyboardType: const TextInputType.numberWithOptions(decimal: false),
      parse: ContinueWatchPolicy.parseAgeDays,
    );
  }
}

Future<T?> _promptParsedValue<T>({
  required BuildContext context,
  required String title,
  required String hint,
  required String placeholder,
  required String initialText,
  required TextInputType keyboardType,
  required T? Function(String raw) parse,
}) {
  return showCupertinoDialog<T>(
    context: context,
    builder: (dialogContext) => _PolicyValueDialog<T>(
      title: title,
      hint: hint,
      placeholder: placeholder,
      initialText: initialText,
      keyboardType: keyboardType,
      parse: parse,
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: MediaLibraryContinuePolicySheet.tertiaryLabel,
          fontSize: 13,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _GroupedCard extends StatelessWidget {
  const _GroupedCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: MediaLibraryContinuePolicySheet.groupedCard,
        child: child,
      ),
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline();

  @override
  Widget build(BuildContext context) {
    return const Divider(
      height: 0.5,
      thickness: 0.5,
      color: Color(0x33FFFFFF),
      indent: 16,
    );
  }
}

class _IosSwitchRow extends StatelessWidget {
  const _IosSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 17),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      color: MediaLibraryContinuePolicySheet.secondaryLabel,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
          CupertinoSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _IosChoiceChip extends StatelessWidget {
  const _IosChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? MediaLibraryContinuePolicySheet.iosBlue
              : const Color(0xFF3A3A3C),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFFEBEBF5),
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _SteppedDurationSlider extends StatelessWidget {
  const _SteppedDurationSlider({
    required this.title,
    required this.hint,
    required this.stepsMs,
    required this.valueMs,
    required this.maxMs,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final List<int> stepsMs;
  final int valueMs;
  final int maxMs;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = valueMs <= 0
        ? '不限'
        : ContinueWatchPolicy.formatDurationMs(valueMs);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _TuneHeader(
          title: title,
          valueLabel: label,
          onMinus: () => onChanged(_maxInt(0, valueMs - 1000)),
          onPlus: () => onChanged(_minInt(maxMs, _nudgeDurationUp(valueMs))),
          onEdit: () async {
            final next = await _promptParsedValue<int>(
              context: context,
              title: title,
              hint: '直接填秒数，或 1:30、1分30秒。0 或不填表示不限。',
              placeholder: '例如 25 或 1:30',
              initialText: valueMs <= 0 ? '' : '${(valueMs / 1000).round()}',
              keyboardType: const TextInputType.numberWithOptions(
                decimal: false,
                signed: false,
              ),
              parse: (raw) =>
                  ContinueWatchPolicy.parseDurationMs(raw, maxMs: maxMs),
            );
            if (next == null) return;
            onChanged(next);
          },
        ),
        Text(
          hint,
          style: const TextStyle(
            color: MediaLibraryContinuePolicySheet.tertiaryLabel,
            fontSize: 11,
            height: 1.3,
          ),
        ),
        CupertinoSlider(
          value: ContinueWatchSliderSteps.sliderOf(valueMs, stepsMs),
          divisions: stepsMs.length - 1,
          activeColor: MediaLibraryContinuePolicySheet.iosBlue,
          onChanged: (t) =>
              onChanged(ContinueWatchSliderSteps.msOf(t, stepsMs)),
        ),
      ],
    );
  }

  /// 0 → 1s so the first plus doesn't sit on「不限」；already ≥1s adds one second.
  static int _nudgeDurationUp(int valueMs) =>
      valueMs <= 0 ? 1000 : valueMs + 1000;
}

class _PercentSlider extends StatelessWidget {
  const _PercentSlider({
    required this.title,
    required this.hint,
    required this.fraction,
    required this.maxFraction,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final double fraction;
  final double maxFraction;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final divisions = (maxFraction * 100).round();
    final label = fraction <= 0
        ? '不限'
        : ContinueWatchPolicy.formatPercent(fraction);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _TuneHeader(
          title: title,
          valueLabel: label,
          onMinus: () => onChanged(_snapPercent(fraction - 0.01)),
          onPlus: () => onChanged(_snapPercent(fraction + 0.01)),
          onEdit: () async {
            final next = await _promptParsedValue<double>(
              context: context,
              title: title,
              hint: '输入百分比，0 或不填表示不限。',
              placeholder: '例如 12 或 12.5',
              initialText: fraction <= 0 ? '' : _percentEditText(fraction),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              parse: (raw) => ContinueWatchPolicy.parsePercentFraction(
                raw,
                maxFraction: maxFraction,
              ),
            );
            if (next == null) return;
            onChanged(next);
          },
        ),
        Text(
          hint,
          style: const TextStyle(
            color: MediaLibraryContinuePolicySheet.tertiaryLabel,
            fontSize: 11,
            height: 1.3,
          ),
        ),
        CupertinoSlider(
          value: (fraction / maxFraction).clamp(0.0, 1.0),
          divisions: divisions,
          activeColor: MediaLibraryContinuePolicySheet.iosBlue,
          onChanged: (t) {
            final next = (t * maxFraction).clamp(0.0, maxFraction);
            onChanged((next * 100).round() / 100);
          },
        ),
      ],
    );
  }

  double _snapPercent(double value) {
    final snapped = (value * 100).round() / 100;
    return snapped.clamp(0.0, maxFraction);
  }

  static String _percentEditText(double fraction) {
    final pct = fraction * 100;
    if ((pct - pct.roundToDouble()).abs() < 0.05) return '${pct.round()}';
    return pct.toStringAsFixed(1);
  }
}

/// Title + minus / tappable value / plus. The number is the custom-entry
/// affordance so people are not stuck on slider ticks.
class _TuneHeader extends StatelessWidget {
  const _TuneHeader({
    required this.title,
    required this.valueLabel,
    required this.onMinus,
    required this.onPlus,
    required this.onEdit,
  });

  final String title;
  final String valueLabel;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
        _TuneIconButton(
          icon: CupertinoIcons.minus_circle,
          onPressed: onMinus,
        ),
        CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          minimumSize: Size.zero,
          onPressed: onEdit,
          child: Text(
            valueLabel,
            style: const TextStyle(
              color: MediaLibraryContinuePolicySheet.iosBlue,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _TuneIconButton(
          icon: CupertinoIcons.plus_circle,
          onPressed: onPlus,
        ),
      ],
    );
  }
}

class _TuneIconButton extends StatelessWidget {
  const _TuneIconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.all(2),
      minimumSize: const Size(28, 28),
      onPressed: onPressed,
      child: Icon(
        icon,
        size: 22,
        color: MediaLibraryContinuePolicySheet.iosBlue,
      ),
    );
  }
}

class _PolicyValueDialog<T> extends StatefulWidget {
  const _PolicyValueDialog({
    required this.title,
    required this.hint,
    required this.placeholder,
    required this.initialText,
    required this.keyboardType,
    required this.parse,
  });

  final String title;
  final String hint;
  final String placeholder;
  final String initialText;
  final TextInputType keyboardType;
  final T? Function(String raw) parse;

  @override
  State<_PolicyValueDialog<T>> createState() => _PolicyValueDialogState<T>();
}

class _PolicyValueDialogState<T> extends State<_PolicyValueDialog<T>> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final parsed = widget.parse(raw);
    if (parsed == null) {
      setState(() => _error = '看不懂这个值，请改成数字后再试。');
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text(widget.title),
      content: Column(
        children: [
          const SizedBox(height: 8),
          Text(widget.hint, style: const TextStyle(fontSize: 13, height: 1.35)),
          const SizedBox(height: 10),
          CupertinoTextField(
            controller: _controller,
            autofocus: true,
            keyboardType: widget.keyboardType,
            placeholder: widget.placeholder,
            textInputAction: TextInputAction.done,
            onSubmitted: _submit,
            style: const TextStyle(color: Colors.white),
            placeholderStyle: const TextStyle(
              color: MediaLibraryContinuePolicySheet.tertiaryLabel,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: const TextStyle(color: Color(0xFFFF453A), fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(widget.parse('')),
          child: const Text('不限'),
        ),
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => _submit(_controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

int _maxInt(int a, int b) => a > b ? a : b;

int _minInt(int a, int b) => a < b ? a : b;
