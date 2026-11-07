import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/app_haptics.dart';
import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
import '../services/sleep_timer_controller.dart';
import '../utils/app_toast.dart';
import 'dialog_keyboard_viewport.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const String _sleepTimerFontFamily = 'Noto Sans SC';

bool _countsPlaybackTime(SleepTimerController timer) {
  switch (timer.mode) {
    case SleepTimerMode.afterPlaybackDuration:
      return true;
    case SleepTimerMode.afterDuration:
      return false;
    case SleepTimerMode.off:
    case SleepTimerMode.endOfCurrentItem:
    case SleepTimerMode.endOfQueue:
    case SleepTimerMode.afterItemCount:
    case SleepTimerMode.atTime:
      return timer.countOnlyWhilePlaying;
  }
}

Future<void> showSleepTimerDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (_) => const DialogKeyboardViewport(child: _SleepTimerDialog()),
  );
}

class _SleepTimerDialog extends StatefulWidget {
  const _SleepTimerDialog();

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  final TextEditingController _minutesController = TextEditingController();
  final TextEditingController _itemCountController = TextEditingController();
  bool _fieldsInitialized = false;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fieldsInitialized) return;
    _fieldsInitialized = true;
    final timer = context.read<MediaPlaybackService>().sleepTimer;
    _minutesController.text = '${timer.customMinutes}';
    _itemCountController.text = '${timer.customItemCount}';
  }

  @override
  void dispose() {
    _minutesController.dispose();
    _itemCountController.dispose();
    super.dispose();
  }

  Future<void> _scheduleDuration(SleepTimerController timer, int minutes) {
    return timer.scheduleAfter(
      Duration(minutes: minutes),
      countOnlyWhilePlaying: _countsPlaybackTime(timer),
    );
  }

  Future<void> _scheduleCustom(SleepTimerController timer) async {
    final minutes = int.tryParse(_minutesController.text.trim());
    if (minutes == null || minutes < 1 || minutes > 1440) {
      AppToast.show('请输入 1 至 1440 分钟', type: AppToastType.info);
      return;
    }
    await timer.setCustomMinutes(minutes);
    await _scheduleDuration(timer, minutes);
  }

  Future<void> _scheduleCustomItems(SleepTimerController timer) async {
    final count = int.tryParse(_itemCountController.text.trim());
    if (count == null ||
        count < SleepTimerController.minCustomItemCount ||
        count > SleepTimerController.maxCustomItemCount) {
      AppToast.show(
        '请输入 ${SleepTimerController.minCustomItemCount} 至 ${SleepTimerController.maxCustomItemCount} 个',
        type: AppToastType.info,
      );
      return;
    }
    await timer.setCustomItemCount(count);
    await timer.scheduleAfterItems(count);
  }

  Future<void> _pickClockTime(SleepTimerController timer) async {
    final now = DateTime.now();
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: '选择暂停时间',
      builder: (context, child) => _NotoTheme(child: child!),
    );
    if (selected == null) return;
    var target = DateTime(
      now.year,
      now.month,
      now.day,
      selected.hour,
      selected.minute,
    );
    if (!target.isAfter(now)) target = target.add(const Duration(days: 1));
    await timer.scheduleAt(target);
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.read<MediaPlaybackService>();
    final timer = playback.sleepTimer;
    final metrics = _DialogMetrics.resolve(MediaQuery.sizeOf(context));

    return _NotoTheme(
      child: Dialog(
        insetPadding: metrics.insetPadding,
        backgroundColor: const Color(0xFF1C1D20),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(metrics.cornerRadius),
          side: const BorderSide(color: Color(0x1FFFFFFF)),
        ),
        clipBehavior: Clip.hardEdge,
        child: RepaintBoundary(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: metrics.dialogWidth,
              maxWidth: metrics.dialogWidth,
              maxHeight: metrics.maxHeight,
            ),
            child: Padding(
              padding: metrics.contentPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(timer, metrics),
                  SizedBox(height: metrics.sectionGap),
                  _TimerStatusCard(timer: timer, dense: metrics.dense),
                  SizedBox(height: metrics.sectionGap),
                  if (metrics.twoColumns)
                    _buildTwoColumnBody(timer, metrics)
                  else
                    _buildSingleColumnBody(timer, metrics),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(SleepTimerController timer, _DialogMetrics metrics) {
    return SizedBox(
      height: metrics.headerHeight,
      child: Row(
        children: [
          Container(
            width: metrics.dense ? 30 : 34,
            height: metrics.dense ? 30 : 34,
            decoration: BoxDecoration(
              color: const Color(0xFF4D8DFF).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: ListenableBuilder(
              listenable: timer,
              builder: (context, _) => Icon(
                timer.isActive
                    ? Icons.alarm_on_rounded
                    : Icons.schedule_rounded,
                size: metrics.dense ? 19 : 21,
                color: timer.isActive
                    ? const Color(0xFF75A7FF)
                    : Colors.white70,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '定时关闭',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: metrics.dense ? 17 : 19,
                    height: 1.05,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!metrics.dense)
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Text(
                      '到时暂停播放并保存当前位置',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 10.5,
                        height: 1.1,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '关闭',
              onPressed: () {
                AppHaptics.pulse(light: true);
                Navigator.of(context).pop();
              },
              icon: const Icon(Icons.close_rounded),
              color: Colors.white54,
              iconSize: 20,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 34, height: 34),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTwoColumnBody(
    SleepTimerController timer,
    _DialogMetrics metrics,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _DurationCard(
            timer: timer,
            dense: metrics.dense,
            minutesController: _minutesController,
            onDurationSelected: (minutes) =>
                unawaited(_scheduleDuration(timer, minutes)),
            onCustomSubmitted: () => unawaited(_scheduleCustom(timer)),
            onPickClockTime: () => unawaited(_pickClockTime(timer)),
          ),
        ),
        SizedBox(width: metrics.columnGap),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CompletionCard(
                timer: timer,
                dense: metrics.dense,
                itemCountController: _itemCountController,
                onCustomItemCountSubmitted: () =>
                    unawaited(_scheduleCustomItems(timer)),
              ),
              SizedBox(height: metrics.cardGap),
              _PlaybackSettingsCard(
                isMobile: _isMobile,
                horizontal: metrics.shortLandscape,
                dense: metrics.dense,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSingleColumnBody(
    SleepTimerController timer,
    _DialogMetrics metrics,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _DurationCard(
          timer: timer,
          dense: metrics.dense,
          minutesController: _minutesController,
          onDurationSelected: (minutes) =>
              unawaited(_scheduleDuration(timer, minutes)),
          onCustomSubmitted: () => unawaited(_scheduleCustom(timer)),
          onPickClockTime: () => unawaited(_pickClockTime(timer)),
        ),
        SizedBox(height: metrics.cardGap),
        _CompletionCard(
          timer: timer,
          dense: metrics.dense,
          itemCountController: _itemCountController,
          onCustomItemCountSubmitted: () =>
              unawaited(_scheduleCustomItems(timer)),
        ),
        SizedBox(height: metrics.cardGap),
        _PlaybackSettingsCard(
          isMobile: _isMobile,
          horizontal: false,
          dense: metrics.dense,
        ),
      ],
    );
  }
}

class _NotoTheme extends StatelessWidget {
  const _NotoTheme({required this.child});

  final Widget child;

  static ThemeData? _cachedSource;
  static ThemeData? _cachedThemed;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    var themed = _cachedThemed;
    if (!identical(base, _cachedSource) || themed == null) {
      final textTheme = base.textTheme.apply(fontFamily: _sleepTimerFontFamily);
      final primaryTextTheme = base.primaryTextTheme.apply(
        fontFamily: _sleepTimerFontFamily,
      );
      themed = base.copyWith(
        textTheme: textTheme,
        primaryTextTheme: primaryTextTheme,
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          labelStyle: textTheme.bodyMedium,
          hintStyle: textTheme.bodyMedium,
          suffixStyle: textTheme.bodySmall,
        ),
      );
      _cachedSource = base;
      _cachedThemed = themed;
    }
    return Theme(
      data: themed,
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontFamily: _sleepTimerFontFamily),
        child: child,
      ),
    );
  }
}

class _TimerStatusCard extends StatelessWidget {
  const _TimerStatusCard({required this.timer, required this.dense});

  final SleepTimerController timer;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        final active = timer.isActive;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          constraints: BoxConstraints(minHeight: dense ? 36 : 44),
          padding: EdgeInsets.fromLTRB(dense ? 10 : 12, 3, 4, 3),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF3378F6).withValues(alpha: 0.13)
                : Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: active
                  ? const Color(0xFF6B9FFF).withValues(alpha: 0.32)
                  : Colors.white.withValues(alpha: 0.07),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? const Color(0xFF75A7FF) : Colors.white30,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  timer.statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: active ? Colors.white : Colors.white54,
                    fontSize: dense ? 11.5 : 12.5,
                    height: 1.15,
                    fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
              if (timer.mode == SleepTimerMode.afterDuration ||
                  timer.mode == SleepTimerMode.afterPlaybackDuration ||
                  timer.mode == SleepTimerMode.atTime)
                _StatusAction(
                  label: '+10分',
                  onPressed: () =>
                      unawaited(timer.extend(const Duration(minutes: 10))),
                ),
              if (active)
                _StatusAction(
                  label: '取消',
                  destructive: true,
                  onPressed: () => unawaited(timer.cancel()),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusAction extends StatelessWidget {
  const _StatusAction({
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    return DesktopButtonClickRegion(
      child: TextButton(
        onPressed: AppHaptics.wrap(onPressed, light: true),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 7),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: destructive
              ? const Color(0xFFFF8181)
              : const Color(0xFF84AFFF),
          textStyle: const TextStyle(
            fontFamily: _sleepTimerFontFamily,
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
          ),
        ),
        child: Text(label),
      ),
    );
  }
}

class _DurationCard extends StatelessWidget {
  const _DurationCard({
    required this.timer,
    required this.dense,
    required this.minutesController,
    required this.onDurationSelected,
    required this.onCustomSubmitted,
    required this.onPickClockTime,
  });

  final SleepTimerController timer;
  final bool dense;
  final TextEditingController minutesController;
  final ValueChanged<int> onDurationSelected;
  final VoidCallback onCustomSubmitted;
  final VoidCallback onPickClockTime;

  @override
  Widget build(BuildContext context) {
    return _SettingCard(
      dense: dense,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionHeader(
            icon: Icons.hourglass_bottom_rounded,
            title: '倒计时',
          ),
          SizedBox(height: dense ? 7 : 10),
          for (final row in const [
            [15, 30, 45],
            [60, 90, 120],
          ]) ...[
            Row(
              children: [
                for (var index = 0; index < row.length; index++) ...[
                  Expanded(
                    child: _QuickDurationButton(
                      minutes: row[index],
                      dense: dense,
                      onPressed: () => onDurationSelected(row[index]),
                    ),
                  ),
                  if (index < row.length - 1) SizedBox(width: dense ? 5 : 7),
                ],
              ],
            ),
            if (row.first == 15) SizedBox(height: dense ? 5 : 7),
          ],
          SizedBox(height: dense ? 5 : 8),
          _CountingModeSwitch(timer: timer, dense: dense),
          SizedBox(height: dense ? 7 : 10),
          const Text(
            '自定义',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: dense ? 5 : 7),
          Row(
            children: [
              SizedBox(
                width: dense ? 72 : 80,
                height: dense ? 34 : 38,
                child: TextField(
                  controller: minutesController,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => onCustomSubmitted(),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: dense ? 11.5 : 12.5,
                    fontWeight: FontWeight.w400,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: dense ? 8 : 10,
                      vertical: 8,
                    ),
                    suffixText: '分',
                    filled: true,
                    fillColor: Colors.black.withValues(alpha: 0.18),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.white12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF6B9FFF)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _SmallFilledButton(
                label: '设置',
                dense: dense,
                onPressed: onCustomSubmitted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _ClockTimeButton(
                  dense: dense,
                  onPressed: onPickClockTime,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompletionCard extends StatelessWidget {
  const _CompletionCard({
    required this.timer,
    required this.dense,
    required this.itemCountController,
    required this.onCustomItemCountSubmitted,
  });

  final SleepTimerController timer;
  final bool dense;
  final TextEditingController itemCountController;
  final VoidCallback onCustomItemCountSubmitted;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) => _SettingCard(
        dense: dense,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SectionHeader(
              icon: Icons.playlist_play_rounded,
              title: '播放完成后',
            ),
            if (!dense) ...[
              const SizedBox(height: 6),
              const Text(
                '会连续播放到这里的停止条件，不受设置里的「自动连播」影响。时间定时仍跟随自动连播。',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10.5,
                  height: 1.25,
                ),
              ),
            ],
            SizedBox(height: dense ? 7 : 10),
            Row(
              children: [
                Expanded(
                  child: _CompletionButton(
                    label: '当前内容结束',
                    icon: Icons.skip_next_rounded,
                    dense: dense,
                    selected: timer.mode == SleepTimerMode.endOfCurrentItem,
                    onPressed: () =>
                        unawaited(timer.scheduleAtEndOfCurrentItem()),
                  ),
                ),
                SizedBox(width: dense ? 5 : 7),
                Expanded(
                  child: _CompletionButton(
                    label: '队列结束',
                    icon: Icons.queue_music_rounded,
                    dense: dense,
                    selected: timer.mode == SleepTimerMode.endOfQueue,
                    onPressed: () => unawaited(timer.scheduleAtEndOfQueue()),
                  ),
                ),
              ],
            ),
            SizedBox(height: dense ? 5 : 7),
            Row(
              children: [
                Expanded(
                  child: _CompletionButton(
                    label: '再播 1 个',
                    icon: Icons.looks_one_outlined,
                    dense: dense,
                    selected:
                        timer.mode == SleepTimerMode.afterItemCount &&
                        timer.scheduledItemCount == 1,
                    onPressed: () => unawaited(timer.scheduleAfterItems(1)),
                  ),
                ),
                SizedBox(width: dense ? 5 : 7),
                Expanded(
                  child: _CustomItemCountButton(
                    timer: timer,
                    controller: itemCountController,
                    dense: dense,
                    onSubmitted: onCustomItemCountSubmitted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackSettingsCard extends StatelessWidget {
  const _PlaybackSettingsCard({
    required this.isMobile,
    required this.horizontal,
    required this.dense,
  });

  final bool isMobile;
  final bool horizontal;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final exitPage = _PlaybackSettingTile(
      title: '退出页面后自动暂停',
      subtitle: '主动退出播放页时暂停媒体',
      value: settings.autoPauseOnExit,
      dense: dense,
      compact: horizontal,
      onChanged: settings.saveAutoPauseOnExit,
    );
    final leaveApp = _PlaybackSettingTile(
      title: '离开软件后暂停播放',
      subtitle: '进入后台或锁屏时暂停媒体',
      value: settings.pausePlaybackWhenAppBackgrounded,
      dense: dense,
      compact: horizontal,
      onChanged: settings.savePausePlaybackWhenAppBackgrounded,
    );

    return _SettingCard(
      dense: dense,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _SectionHeader(icon: Icons.tune_rounded, title: '播放行为'),
          SizedBox(height: dense ? 5 : 7),
          if (horizontal && isMobile)
            Row(
              children: [
                Expanded(child: exitPage),
                const SizedBox(width: 5),
                Expanded(child: leaveApp),
              ],
            )
          else ...[
            exitPage,
            if (isMobile) ...[
              const Divider(height: 1, color: Colors.white10),
              leaveApp,
            ],
          ],
        ],
      ),
    );
  }
}

class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.child, required this.dense});

  final Widget child;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(dense ? 9 : 13),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.038),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: child,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF8AB2FF)),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            color: Color(0xDBFFFFFF),
            fontSize: 12,
            height: 1.1,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _QuickDurationButton extends StatelessWidget {
  const _QuickDurationButton({
    required this.minutes,
    required this.dense,
    required this.onPressed,
  });

  final int minutes;
  final bool dense;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: dense ? 28 : 34,
      child: DesktopButtonClickRegion(
        child: OutlinedButton(
          onPressed: AppHaptics.wrap(onPressed),
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            foregroundColor: Colors.white70,
            backgroundColor: Colors.black.withValues(alpha: 0.12),
            side: const BorderSide(color: Colors.white12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: TextStyle(
              fontFamily: _sleepTimerFontFamily,
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: Text('$minutes 分'),
        ),
      ),
    );
  }
}

class _CountingModeSwitch extends StatelessWidget {
  const _CountingModeSwitch({required this.timer, required this.dense});

  final SleepTimerController timer;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: timer,
      builder: (context, _) {
        final value = _countsPlaybackTime(timer);
        return InkWell(
          onTap: () {
            AppHaptics.pulse();
            unawaited(timer.setCountOnlyWhilePlaying(!value));
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: dense ? 32 : 38,
            padding: const EdgeInsets.only(left: 8, right: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    value ? '仅计算实际播放时间' : '按现实时间计时',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: dense ? 10 : 11,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
                IgnorePointer(
                  child: Transform.scale(
                    scale: dense ? 0.72 : 0.82,
                    child: Switch(
                      value: value,
                      onChanged: (next) =>
                          unawaited(timer.setCountOnlyWhilePlaying(next)),
                      activeThumbColor: const Color(0xFF6B9FFF),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CompletionButton extends StatelessWidget {
  const _CompletionButton({
    required this.label,
    required this.icon,
    required this.dense,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool dense;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF82ADFF) : Colors.white60;
    return SizedBox(
      height: dense ? 30 : 36,
      child: DesktopButtonClickRegion(
        child: OutlinedButton.icon(
          onPressed: AppHaptics.wrap(onPressed),
          icon: Icon(icon, size: dense ? 14 : 16),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label, maxLines: 1),
          ),
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: dense ? 5 : 8),
            foregroundColor: color,
            backgroundColor: selected
                ? const Color(0xFF397AF2).withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.1),
            side: BorderSide(
              color: selected
                  ? const Color(0xFF6B9FFF).withValues(alpha: 0.55)
                  : Colors.white12,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: TextStyle(
              fontFamily: _sleepTimerFontFamily,
              fontSize: dense ? 9.5 : 10.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomItemCountButton extends StatefulWidget {
  const _CustomItemCountButton({
    required this.timer,
    required this.controller,
    required this.dense,
    required this.onSubmitted,
  });

  final SleepTimerController timer;
  final TextEditingController controller;
  final bool dense;
  final VoidCallback onSubmitted;

  @override
  State<_CustomItemCountButton> createState() => _CustomItemCountButtonState();
}

class _CustomItemCountButtonState extends State<_CustomItemCountButton> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleTextChanged);
  }

  @override
  void didUpdateWidget(covariant _CustomItemCountButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleTextChanged);
    widget.controller.addListener(_handleTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChanged);
    super.dispose();
  }

  void _handleTextChanged() {
    if (mounted) setState(() {});
  }

  bool get _selected {
    final count = int.tryParse(widget.controller.text.trim());
    return count != null &&
        count > 1 &&
        widget.timer.mode == SleepTimerMode.afterItemCount &&
        widget.timer.scheduledItemCount == count;
  }

  @override
  Widget build(BuildContext context) {
    final dense = widget.dense;
    final selected = _selected;
    final color = selected ? const Color(0xFF82ADFF) : Colors.white60;
    return SizedBox(
      height: dense ? 30 : 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF397AF2).withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF6B9FFF).withValues(alpha: 0.55)
                : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            SizedBox(width: dense ? 6 : 8),
            Text(
              '再播',
              style: TextStyle(
                fontFamily: _sleepTimerFontFamily,
                color: color,
                fontSize: dense ? 9.5 : 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(
              width: dense ? 26 : 32,
              child: TextField(
                key: const Key('sleepTimerCustomItemCount'),
                controller: widget.controller,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                textAlign: TextAlign.center,
                textAlignVertical: TextAlignVertical.center,
                onSubmitted: (_) => widget.onSubmitted(),
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                style: TextStyle(
                  fontFamily: _sleepTimerFontFamily,
                  color: Colors.white,
                  fontSize: dense ? 11 : 12,
                  height: 1,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  isCollapsed: true,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: dense ? 7 : 10,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            Text(
              '个',
              style: TextStyle(
                fontFamily: _sleepTimerFontFamily,
                color: color,
                fontSize: dense ? 9.5 : 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Tooltip(
              message: '设置再播数量',
              child: DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: AppHaptics.wrap(widget.onSubmitted, light: true),
                  style: TextButton.styleFrom(
                    minimumSize: Size(0, dense ? 30 : 36),
                    padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    foregroundColor: const Color(0xFF84AFFF),
                    textStyle: TextStyle(
                      fontFamily: _sleepTimerFontFamily,
                      fontSize: dense ? 9.5 : 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: const Text('设置'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaybackSettingTile extends StatelessWidget {
  const _PlaybackSettingTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.dense,
    required this.compact,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool dense;
  final bool compact;
  final Future<void> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: title,
      toggled: value,
      child: InkWell(
        onTap: () {
          AppHaptics.pulse();
          unawaited(onChanged(!value));
        },
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: compact ? 43 : (dense ? 42 : 48),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: compact ? 9.5 : (dense ? 10.5 : 11.5),
                        height: compact ? 1.2 : 1.1,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (!compact)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white30,
                            fontSize: dense ? 8.5 : 9.5,
                            height: 1.1,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IgnorePointer(
                child: Transform.scale(
                  scale: dense ? 0.72 : 0.8,
                  child: Switch(
                    value: value,
                    onChanged: (next) => unawaited(onChanged(next)),
                    activeThumbColor: const Color(0xFF6B9FFF),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmallFilledButton extends StatelessWidget {
  const _SmallFilledButton({
    required this.label,
    required this.dense,
    required this.onPressed,
  });

  final String label;
  final bool dense;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: dense ? 34 : 38,
      child: DesktopButtonClickRegion(
        child: FilledButton(
          onPressed: AppHaptics.wrap(onPressed, light: true),
          style: FilledButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: dense ? 9 : 12),
            backgroundColor: const Color(0xFF3978E8),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: TextStyle(
              fontFamily: _sleepTimerFontFamily,
              fontSize: dense ? 10.5 : 11.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

class _ClockTimeButton extends StatelessWidget {
  const _ClockTimeButton({required this.dense, required this.onPressed});

  final bool dense;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: dense ? 34 : 38,
      child: DesktopButtonClickRegion(
        child: OutlinedButton.icon(
          onPressed: AppHaptics.wrap(onPressed, light: true),
          icon: Icon(Icons.schedule_rounded, size: dense ? 14 : 16),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('指定时间', maxLines: 1),
          ),
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 9),
            foregroundColor: Colors.white60,
            side: const BorderSide(color: Colors.white12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: TextStyle(
              fontFamily: _sleepTimerFontFamily,
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _DialogMetrics {
  const _DialogMetrics({
    required this.dialogWidth,
    required this.maxHeight,
    required this.insetPadding,
    required this.contentPadding,
    required this.cornerRadius,
    required this.headerHeight,
    required this.sectionGap,
    required this.cardGap,
    required this.columnGap,
    required this.twoColumns,
    required this.shortLandscape,
    required this.dense,
  });

  final double dialogWidth;
  final double maxHeight;
  final EdgeInsets insetPadding;
  final EdgeInsets contentPadding;
  final double cornerRadius;
  final double headerHeight;
  final double sectionGap;
  final double cardGap;
  final double columnGap;
  final bool twoColumns;
  final bool shortLandscape;
  final bool dense;

  static _DialogMetrics resolve(Size screen) {
    final shortLandscape = screen.width > screen.height && screen.height < 600;
    final twoColumns = shortLandscape || screen.width >= 700;
    final dense = screen.height < 720 || screen.width < 430;
    final horizontalInset = shortLandscape ? 8.0 : (dense ? 12.0 : 24.0);
    final verticalInset = shortLandscape ? 8.0 : (dense ? 10.0 : 24.0);
    final availableWidth = screen.width - horizontalInset * 2;
    final targetWidth = twoColumns
        ? (shortLandscape ? 720.0 : 680.0)
        : (dense ? 420.0 : 500.0);
    final dialogWidth = availableWidth.clamp(280.0, targetWidth);
    return _DialogMetrics(
      dialogWidth: dialogWidth,
      maxHeight: screen.height - verticalInset * 2,
      insetPadding: EdgeInsets.symmetric(
        horizontal: horizontalInset,
        vertical: verticalInset,
      ),
      contentPadding: EdgeInsets.all(shortLandscape || dense ? 8 : 18),
      cornerRadius: dense ? 15 : 18,
      headerHeight: dense ? 32 : 42,
      sectionGap: shortLandscape ? 5 : (dense ? 7 : 12),
      cardGap: shortLandscape ? 5 : (dense ? 7 : 10),
      columnGap: shortLandscape ? 8 : 12,
      twoColumns: twoColumns,
      shortLandscape: shortLandscape,
      dense: dense,
    );
  }
}
