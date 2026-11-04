import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/danmaku_style.dart';
import '../models/video_item.dart';
import '../services/bilibili/bilibili_danmaku_auto_update.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/subtitle_font_service.dart';
import 'bilibili_login_dialogs.dart';
import 'stable_width_label.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const _accent = Color(0xFFFF6699);

/// Short screens reduce spacing first; content scales only if it cannot fit.
@immutable
class _DanmakuDialogMetrics {
  const _DanmakuDialogMetrics({
    required this.compact,
    required this.extraCompact,
    required this.insetPadding,
    required this.contentPadding,
    required this.headerGap,
    required this.titleSize,
    required this.bodySize,
    required this.valueSize,
    required this.captionSize,
    required this.headerButtonIconSize,
    required this.headerButtonPadding,
    required this.sliderVerticalPadding,
    required this.sliderTrackHeight,
    required this.sliderThumbRadius,
    required this.sliderLabelWidth,
    required this.sliderValueWidth,
    required this.sliderPadding,
    required this.previewHeight,
    required this.previewFontSize,
    required this.sectionGap,
    required this.fieldVerticalPadding,
    required this.outlineRunSpacing,
    required this.outlineItemPadding,
  });

  factory _DanmakuDialogMetrics.fromSize(Size screen, EdgeInsets viewPadding) {
    // Typical phone landscape is ~360–400px tall; portrait phones stay roomy.
    final extraCompact = screen.height < 430;
    final compact = extraCompact || screen.height < 560;
    final verticalInset = extraCompact
        ? 6.0
        : compact
        ? 10.0
        : 24.0;
    final horizontalInset = screen.width < 600
        ? 12.0
        : compact
        ? 16.0
        : 20.0;

    return _DanmakuDialogMetrics(
      compact: compact,
      extraCompact: extraCompact,
      insetPadding: EdgeInsets.fromLTRB(
        horizontalInset + viewPadding.left,
        verticalInset + viewPadding.top,
        horizontalInset + viewPadding.right,
        verticalInset + viewPadding.bottom,
      ),
      contentPadding: extraCompact
          ? const EdgeInsets.fromLTRB(18, 10, 18, 12)
          : compact
          ? const EdgeInsets.fromLTRB(16, 8, 12, 12)
          : const EdgeInsets.fromLTRB(22, 14, 16, 20),
      headerGap: extraCompact ? 0 : (compact ? 2 : 4),
      titleSize: 18,
      bodySize: 15,
      valueSize: 14,
      captionSize: extraCompact ? 10 : 12,
      headerButtonIconSize: 17,
      headerButtonPadding: extraCompact
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 2)
          : const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
      sliderVerticalPadding: extraCompact ? 0 : (compact ? 2 : 5),
      sliderTrackHeight: compact ? 5 : 7,
      sliderThumbRadius: 8,
      sliderLabelWidth: 72,
      sliderValueWidth: 112,
      sliderPadding: extraCompact
          ? const EdgeInsets.symmetric(horizontal: 4, vertical: 1)
          : compact
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
          : null,
      previewHeight: extraCompact ? 48 : (compact ? 64 : 92),
      previewFontSize: extraCompact ? 18 : (compact ? 20 : 24),
      sectionGap: extraCompact ? 6 : (compact ? 10 : 20),
      fieldVerticalPadding: extraCompact ? 8 : 12,
      outlineRunSpacing: extraCompact ? 6 : 10,
      outlineItemPadding: extraCompact
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 5)
          : const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    );
  }

  final bool compact;
  final bool extraCompact;
  final EdgeInsets insetPadding;
  final EdgeInsets contentPadding;
  final double headerGap;
  final double titleSize;
  final double bodySize;
  final double valueSize;
  final double captionSize;
  final double headerButtonIconSize;
  final EdgeInsets headerButtonPadding;
  final double sliderVerticalPadding;
  final double sliderTrackHeight;
  final double sliderThumbRadius;
  final double sliderLabelWidth;
  final double sliderValueWidth;
  final EdgeInsetsGeometry? sliderPadding;
  final double previewHeight;
  final double previewFontSize;
  final double sectionGap;
  final double fieldVerticalPadding;
  final double outlineRunSpacing;
  final EdgeInsets outlineItemPadding;
}

class _DanmakuDialogScope extends InheritedWidget {
  const _DanmakuDialogScope({required this.metrics, required super.child});

  final _DanmakuDialogMetrics metrics;

  static _DanmakuDialogMetrics of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_DanmakuDialogScope>();
    assert(scope != null, 'Danmaku settings widgets need dialog metrics');
    return scope!.metrics;
  }

  @override
  bool updateShouldNotify(_DanmakuDialogScope oldWidget) =>
      metrics != oldWidget.metrics;
}

Future<void> showDanmakuSettingsDialog(
  BuildContext context, {
  DanmakuPresentationMode initialMode = DanmakuPresentationMode.landscape,
  VideoItem? videoItem,
  VoidCallback? onDanmakuUpdated,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (context) => _DanmakuSettingsDialog(
      initialMode: initialMode,
      videoItem: videoItem,
      onDanmakuUpdated: onDanmakuUpdated,
    ),
  );
}

class _DanmakuSettingsDialog extends StatefulWidget {
  final DanmakuPresentationMode initialMode;
  final VideoItem? videoItem;
  final VoidCallback? onDanmakuUpdated;

  const _DanmakuSettingsDialog({
    required this.initialMode,
    this.videoItem,
    this.onDanmakuUpdated,
  });

  @override
  State<_DanmakuSettingsDialog> createState() => _DanmakuSettingsDialogState();
}

class _DanmakuSettingsDialogState extends State<_DanmakuSettingsDialog> {
  late DanmakuPresentationMode _mode = widget.initialMode;
  bool _updating = false;
  String? _status;
  bool _statusIsError = false;

  Future<void> _updateDanmaku() async {
    if (_updating) return;
    final videoItem = widget.videoItem;
    if (videoItem == null) {
      setState(() {
        _status = '缺少B站视频信息';
        _statusIsError = true;
      });
      return;
    }
    setState(() {
      _updating = true;
      _status = '正在获取最新弹幕…';
      _statusIsError = false;
    });
    final autoUpdate = BilibiliDanmakuAutoUpdate.instance;
    autoUpdate.beginManual(videoItem.id);
    try {
      final service = context.read<BilibiliDownloadService>();
      final library = context.read<LibraryService>();
      await service.updateDanmakuForVideo(videoItem, library);
      unawaited(autoUpdate.recordManualSuccess(videoItem));
      if (!mounted) return;
      widget.onDanmakuUpdated?.call();
      setState(() {
        _updating = false;
        _status = '弹幕已更新';
      });
    } catch (error) {
      if (!mounted) return;
      final message = error is BilibiliDanmakuUpdateException
          ? error.message
          : '获取最新弹幕失败，请重试';
      setState(() {
        _updating = false;
        _status = message;
        _statusIsError = true;
      });
    } finally {
      autoUpdate.endManual(videoItem.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final metrics = _DanmakuDialogMetrics.fromSize(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    return _SettingsDialogFrame(
      title: '弹幕设置',
      maxWidth: metrics.compact ? 560 : 640,
      metrics: metrics,
      headerAction: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesktopButtonClickRegion(
            child: TextButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                barrierColor: Colors.black54,
                builder: (_) => const _DanmakuAdvancedSettingsDialog(),
              ),
              icon: Icon(
                Icons.tune_rounded,
                size: metrics.headerButtonIconSize,
              ),
              label: const Text('高级设置'),
              style: TextButton.styleFrom(
                foregroundColor: _accent,
                padding: metrics.headerButtonPadding,
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: TextButton.icon(
              onPressed: () => unawaited(showBilibiliLoginDialog(context)),
              icon: Icon(
                Icons.person_rounded,
                size: metrics.headerButtonIconSize,
              ),
              label: const Text('登录/Cookie'),
              style: TextButton.styleFrom(
                foregroundColor: _accent,
                padding: metrics.headerButtonPadding,
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ),
      child: Flexible(
        child: _FitSettingsContent(
          key: const ValueKey('danmaku-settings-scroll'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  for (final mode in DanmakuPresentationMode.values)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: DesktopButtonClickRegion(
                          child: TextButton(
                            key: ValueKey('danmaku-profile-${mode.name}'),
                            onPressed: () => setState(() => _mode = mode),
                            style: TextButton.styleFrom(
                              foregroundColor: _mode == mode
                                  ? _accent
                                  : Colors.white70,
                              backgroundColor: _mode == mode
                                  ? _accent.withValues(alpha: .12)
                                  : Colors.white.withValues(alpha: .04),
                              minimumSize: const Size(0, 28),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            child: Text(mode.label),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              ..._sliderControls(settings),
              _CheckboxRow(
                label: '弹幕仅在视频区域内展示',
                checkboxKey: const ValueKey('danmaku-video-area-checkbox'),
                value: settings.bilibiliDanmakuOnlyInVideoArea,
                onChanged: (value) => unawaited(
                  settings.saveBilibiliDanmakuOnlyInVideoArea(value),
                ),
              ),
              _CheckboxRow(
                label: '以锁定倍速为弹幕速度基准',
                value: settings.bilibiliDanmakuUseLockedSpeedAsBaseline,
                onChanged: (value) => unawaited(
                  settings.saveBilibiliDanmakuUseLockedSpeedAsBaseline(value),
                ),
              ),
              _CheckboxRow(
                label: '自动更新弹幕',
                checkboxKey: const ValueKey('danmaku-auto-update-checkbox'),
                value: settings.bilibiliDanmakuAutoUpdate,
                onChanged: (value) =>
                    unawaited(settings.saveBilibiliDanmakuAutoUpdate(value)),
              ),
              SizedBox(height: metrics.extraCompact ? 4 : 8),
              const Divider(color: Colors.white12, height: 1),
              SizedBox(height: metrics.extraCompact ? 6 : 12),
              ..._updateControls(metrics),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sliderControls(SettingsService settings) {
    final area = settings.danmakuDisplayAreaFor(_mode);
    final fontScale = settings.danmakuFontScaleFor(_mode);
    final speed = settings.danmakuSpeedFor(_mode);
    final density = settings.danmakuDensityFor(_mode);
    return [
      _SliderRow(
        label: '显示区域',
        valueText: '${(area * 100).round()}%',
        value: area,
        min: kDanmakuDisplayAreaMin,
        max: kDanmakuDisplayAreaMax,
        divisions: 99,
        onChanged: (value) => unawaited(
          settings.saveBilibiliDanmakuDisplayArea(value, mode: _mode),
        ),
      ),
      _SliderRow(
        label: '弹幕密度',
        valueText: '${(density * 100).round()}%',
        value: density,
        min: kDanmakuDensityMin,
        max: kDanmakuDensityMax,
        divisions: 18,
        onChanged: (value) =>
            unawaited(settings.saveBilibiliDanmakuDensity(value, mode: _mode)),
      ),
      _SliderRow(
        label: '不透明度',
        valueText: '${(settings.bilibiliDanmakuOpacity * 100).round()}%',
        value: settings.bilibiliDanmakuOpacity,
        min: 0.1,
        max: 1,
        divisions: 90,
        onChanged: (value) =>
            unawaited(settings.saveBilibiliDanmakuOpacity(value)),
      ),
      _SliderRow(
        label: '弹幕字号',
        valueText: '${(fontScale * 100).round()}%',
        value: fontScale,
        min: kDanmakuFontScaleMin,
        max: kDanmakuFontScaleMax,
        divisions: 190,
        onChanged: (value) => unawaited(
          settings.saveBilibiliDanmakuFontScale(value, mode: _mode),
        ),
      ),
      _SliderRow(
        label: '弹幕速度',
        valueText: _speedLabel(speed),
        value: danmakuSpeedToSlider(speed),
        min: 0,
        max: 1,
        divisions: 200,
        onChanged: (value) => unawaited(
          settings.saveBilibiliDanmakuSpeed(
            danmakuSpeedFromSlider(value),
            mode: _mode,
          ),
        ),
      ),
    ];
  }

  List<Widget> _updateControls(_DanmakuDialogMetrics metrics) {
    final textHeight =
        MediaQuery.textScalerOf(context).scale(metrics.captionSize) * 1.4;
    final statusHeight =
        (textHeight < 22 ? 22.0 : textHeight) + (metrics.extraCompact ? 4 : 6);
    return [
      // Reserve the status line so a busy/error state cannot rescale the
      // whole fitted panel and change the update button's width/position.
      SizedBox(
        height: statusHeight,
        child: _status == null
            ? null
            : Padding(
                padding: EdgeInsets.only(top: metrics.extraCompact ? 4 : 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _status!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _statusIsError
                              ? const Color(0xFFFF8A80)
                              : Colors.white60,
                          fontSize: metrics.captionSize,
                        ),
                      ),
                    ),
                    if (_statusIsError)
                      InkWell(
                        onTap: () => setState(() => _status = null),
                        borderRadius: BorderRadius.circular(12),
                        child: const Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(
                            Icons.close_rounded,
                            size: 15,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
      Row(
        children: [
          Expanded(
            child: Text(
              '更新弹幕',
              style: TextStyle(
                color: Colors.white,
                fontSize: metrics.bodySize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton.icon(
              onPressed: _updating ? null : _updateDanmaku,
              // 转圈占用图标位、文案按最宽的那条排版，更新时按钮宽度不变。
              icon: StableIconSlot(
                icon: Icons.refresh_rounded,
                size: metrics.extraCompact ? 16 : 18,
                busy: _updating,
                spinnerSize: metrics.extraCompact ? 13 : 15,
                spinnerColor: Colors.white,
              ),
              label: StableWidthLabel(
                _updating ? '更新中' : '立即更新',
                variants: const ['立即更新', '更新中'],
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _accent.withValues(alpha: 0.55),
                disabledForegroundColor: Colors.white70,
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: metrics.extraCompact
                    ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                    : null,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  String _speedLabel(double value) {
    final description = switch (value) {
      < 0.15 => '极慢',
      < 0.5 => '很慢',
      < 0.85 => '较慢',
      <= 1.2 => '适中',
      <= 2.0 => '较快',
      <= 5.0 => '很快',
      _ => '极快',
    };
    final digits = value < 1 ? 2 : (value < 10 ? 1 : 0);
    return '$description · ${value.toStringAsFixed(digits)}×';
  }
}

class _DanmakuAdvancedSettingsDialog extends StatefulWidget {
  const _DanmakuAdvancedSettingsDialog();

  @override
  State<_DanmakuAdvancedSettingsDialog> createState() =>
      _DanmakuAdvancedSettingsDialogState();
}

class _DanmakuAdvancedSettingsDialogState
    extends State<_DanmakuAdvancedSettingsDialog> {
  int _tab = 0;
  bool _importing = false;
  String? _error;
  final _fonts = SubtitleFontService.instance;
  final Map<String, Future<void>> _fontLoads = {};

  List<int> _weightsFor(String family) {
    final weights = _fonts.find(family)?.weights;
    // The platform default is resolved by Flutter; named faces use their catalog.
    if (family.isEmpty) return List.generate(9, (i) => (i + 1) * 100);
    return (weights == null || weights.isEmpty ? [400] : weights)
        .toSet()
        .toList()
      ..sort();
  }

  int _nearestWeight(List<int> weights, int value) =>
      weights.reduce((a, b) => (a - value).abs() <= (b - value).abs() ? a : b);

  String _weightLabel(int weight) => switch (weight) {
    100 => '极细',
    200 => '纤细',
    300 => '细体',
    400 => '常规',
    500 => '中等',
    600 => '半粗',
    700 => '粗体',
    800 => '特粗',
    900 => '重黑',
    _ => '$weight',
  };

  Widget _fontLabel(String id) {
    Widget label({String? suffix}) => Text(
      '${id.isEmpty ? '当前默认字体' : _fonts.nameOf(id)}${suffix ?? ''}',
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        inherit: false,
        color: Colors.white,
        fontSize: 14,
        fontFamily: id.isEmpty || suffix != null ? null : id,
        fontWeight: danmakuFontWeight(_nearestWeight(_weightsFor(id), 400)),
      ),
    );
    if (_fonts.isLoaded(id)) return label();
    return FutureBuilder<void>(
      future: _fontLoads.putIfAbsent(id, () => _fonts.ensureLoaded(id)),
      builder: (context, snapshot) => label(
        suffix: snapshot.hasError
            ? '（字体不可用）'
            : snapshot.connectionState == ConnectionState.done
            ? null
            : '（加载中）',
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _fonts.ready.then((_) async {
      if (!mounted) return;
      final settings = context.read<SettingsService>();
      final family = settings.bilibiliDanmakuFontFamily;
      if (family != null && _fonts.find(family) != null) {
        final weight = _nearestWeight(
          _weightsFor(family),
          settings.bilibiliDanmakuFontWeight,
        );
        if (weight != settings.bilibiliDanmakuFontWeight) {
          await settings.saveBilibiliDanmakuFontWeight(weight);
        }
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _importFont() async {
    setState(() {
      _importing = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['ttf', 'otf', 'ttc'],
      );
      final path = result?.files.single.path;
      if (path == null) return;
      final font = await _fonts.importFile(path);
      if (!mounted) return;
      await _selectFont(font.id);
    } catch (_) {
      if (mounted) setState(() => _error = '字体导入失败，请选择有效的 TTF、OTF 或 TTC 文件');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _selectFont(String? value) async {
    try {
      if (value != null && value.isNotEmpty) await _fonts.ensureLoaded(value);
      if (!mounted) return;
      setState(() => _error = null);
      final settings = context.read<SettingsService>();
      final weight = _nearestWeight(
        _weightsFor(value ?? ''),
        settings.bilibiliDanmakuFontWeight,
      );
      await settings.saveBilibiliDanmakuFontWeight(weight);
      await settings.saveBilibiliDanmakuFontFamily(
        value == null || value.isEmpty ? null : value,
      );
    } catch (_) {
      if (mounted) setState(() => _error = '字体文件不可用，请重新导入');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final metrics = _DanmakuDialogMetrics.fromSize(
      MediaQuery.sizeOf(context),
      MediaQuery.paddingOf(context),
    );
    final family = settings.bilibiliDanmakuFontFamily ?? '';
    final weights = _weightsFor(family);
    final selectedWeight = _nearestWeight(
      weights,
      settings.bilibiliDanmakuFontWeight,
    );
    final families = <String>{
      '',
      ...kDanmakuFontFamilies.whereType<String>(),
      ..._fonts.fonts
          .where((font) => font.id.startsWith('subtitle_font_'))
          .map((font) => font.id),
      family,
    };
    return _SettingsDialogFrame(
      title: '弹幕高级设置',
      maxWidth: metrics.compact ? 560 : 640,
      metrics: metrics,
      child: Flexible(
        child: _FitSettingsContent(
          key: const ValueKey('danmaku-advanced-settings-scroll'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DanmakuPreview(settings: settings),
              SizedBox(height: metrics.compact ? 6 : 12),
              Row(
                children: [
                  for (final entry in const ['字体', '样式', '微调'].asMap().entries)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: () => setState(() => _tab = entry.key),
                            style: TextButton.styleFrom(
                              foregroundColor: _tab == entry.key
                                  ? _accent
                                  : Colors.white70,
                              backgroundColor: _tab == entry.key
                                  ? _accent.withValues(alpha: 0.12)
                                  : Colors.white.withValues(alpha: 0.04),
                              minimumSize: const Size(0, 32),
                              visualDensity: VisualDensity.standard,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                            child: Text(entry.value),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: metrics.compact ? 6 : 12),
              if (_tab == 0) ...[
                CapsuleDropdownButtonFormField<String>(
                  key: ValueKey('danmaku-font-$family'),
                  initialValue: family,
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: const Color(0xFF292929),
                  iconEnabledColor: Colors.white70,
                  style: TextStyle(
                    color: Colors.white,
                    fontFamily: family.isEmpty ? null : family,
                    fontSize: 14,
                  ),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Color(0xFF171717),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(borderSide: BorderSide.none),
                  ),
                  items: [
                    for (final id in families)
                      DropdownMenuItem(value: id, child: _fontLabel(id)),
                  ],
                  onChanged: _selectFont,
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 64,
                        child: Text(
                          '字重',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      if (weights.length == 1)
                        Expanded(
                          child: Text(
                            '${_weightLabel(weights.single)} · 此字体仅提供这一种字重',
                            key: const ValueKey('danmaku-fixed-weight'),
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: CapsuleDropdownButtonFormField<int>(
                            key: ValueKey(
                              'danmaku-weight-$family-$selectedWeight',
                            ),
                            initialValue: selectedWeight,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            items: [
                              for (final weight in weights)
                                DropdownMenuItem(
                                  value: weight,
                                  child: Text(
                                    '${_weightLabel(weight)} · $weight',
                                    style: TextStyle(
                                      fontFamily: family.isEmpty
                                          ? null
                                          : family,
                                      fontWeight: danmakuFontWeight(weight),
                                    ),
                                  ),
                                ),
                            ],
                            onChanged: (weight) {
                              if (weight != null) {
                                unawaited(
                                  settings.saveBilibiliDanmakuFontWeight(
                                    weight,
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopButtonClickRegion(
                    child: TextButton.icon(
                      onPressed: _importing ? null : _importFont,
                      icon: const Icon(Icons.file_upload_outlined, size: 18),
                      label: Text(
                        _importing ? '正在导入…' : '导入字体 · TTF / OTF / TTC',
                      ),
                      style: TextButton.styleFrom(foregroundColor: _accent),
                    ),
                  ),
                ),
              ],
              if (_tab == 1)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth < 380 ? 2 : 3;
                    final gap = metrics.compact ? 6.0 : 10.0;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final type in DanmakuOutlineType.values)
                          SizedBox(
                            width:
                                (constraints.maxWidth - gap * (columns - 1)) /
                                columns,
                            child: _OutlineOption(
                              type: type,
                              selected:
                                  settings.bilibiliDanmakuOutlineType == type,
                              onTap: () => unawaited(
                                settings.saveBilibiliDanmakuOutlineType(type),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              if (_tab == 2) ...[
                _FineAdjustment(
                  label: '描边强度',
                  value: settings.bilibiliDanmakuOutlineScale,
                  min: 0,
                  max: 3,
                  step: 0.05,
                  valueText:
                      '${settings.bilibiliDanmakuOutlineScale.toStringAsFixed(2)}×',
                  enabled:
                      danmakuOutlineWidthRatio(
                        settings.bilibiliDanmakuOutlineType,
                      ) >
                      0,
                  onChanged: (v) =>
                      unawaited(settings.saveBilibiliDanmakuOutlineScale(v)),
                ),
                _FineAdjustment(
                  label: '阴影距离',
                  value: settings.bilibiliDanmakuShadowScale,
                  min: 0,
                  max: 3,
                  step: 0.05,
                  valueText:
                      '${settings.bilibiliDanmakuShadowScale.toStringAsFixed(2)}×',
                  enabled:
                      resolveDanmakuProjectionDistance(
                        settings.bilibiliDanmakuOutlineType,
                        1,
                      ) >
                      0,
                  onChanged: (v) =>
                      unawaited(settings.saveBilibiliDanmakuShadowScale(v)),
                ),
                _FineAdjustment(
                  label: '字距',
                  value: settings.bilibiliDanmakuLetterSpacing,
                  min: 0,
                  max: 0.3,
                  step: 0.01,
                  valueText:
                      '${(settings.bilibiliDanmakuLetterSpacing * 100).round()}%',
                  onChanged: (v) =>
                      unawaited(settings.saveBilibiliDanmakuLetterSpacing(v)),
                ),
                const Text(
                  '描边与阴影按所选样式启用；字距按字号比例调整',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
              if (_error != null)
                Text(
                  _error!,
                  style: const TextStyle(
                    color: Color(0xFFFF8A80),
                    fontSize: 12,
                  ),
                ),
              SizedBox(height: metrics.compact ? 4 : 12),
              const Divider(color: Colors.white12, height: 1),
              Align(
                alignment: Alignment.centerRight,
                child: DesktopButtonClickRegion(
                  child: TextButton.icon(
                    onPressed: () =>
                        unawaited(settings.resetBilibiliDanmakuSettings()),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    label: const Text('恢复弹幕默认设置'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
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

class _FineAdjustment extends StatelessWidget {
  const _FineAdjustment({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.valueText,
    required this.onChanged,
    this.enabled = true,
  });
  final String label, valueText;
  final double value, min, max, step;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 42,
    child: Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white : Colors.white38,
              fontSize: 14,
            ),
          ),
        ),
        DesktopButtonClickRegion(
          child: IconButton(
            tooltip: '减小$label',
            onPressed: enabled && value > min
                ? () => onChanged((value - step).clamp(min, max))
                : null,
            constraints: const BoxConstraints.tightFor(width: 28, height: 32),
            padding: EdgeInsets.zero,
            icon: const Icon(
              Icons.remove_rounded,
              size: 16,
              color: Colors.white70,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              activeTrackColor: _accent,
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: ((max - min) / step).round(),
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ),
        DesktopButtonClickRegion(
          child: IconButton(
            tooltip: '增大$label',
            onPressed: enabled && value < max
                ? () => onChanged((value + step).clamp(min, max))
                : null,
            constraints: const BoxConstraints.tightFor(width: 28, height: 32),
            padding: EdgeInsets.zero,
            icon: const Icon(
              Icons.add_rounded,
              size: 16,
              color: Colors.white70,
            ),
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(
            valueText,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: enabled ? _accent : Colors.white38,
              fontSize: 13,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Prefer the available dialog space, then scale the entire control group only
/// when necessary. Settings never require scrolling, including advanced options.
class _FitSettingsContent extends StatelessWidget {
  const _FitSettingsContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topCenter,
        child: SizedBox(width: constraints.maxWidth, child: child),
      ),
    );
  }
}

class _SettingsDialogFrame extends StatelessWidget {
  final String title;
  final double maxWidth;
  final _DanmakuDialogMetrics metrics;
  final Widget? headerAction;
  final Widget child;

  const _SettingsDialogFrame({
    required this.title,
    required this.maxWidth,
    required this.metrics,
    this.headerAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final maxHeight = (screen.height - metrics.insetPadding.vertical).clamp(
      0.0,
      screen.height,
    );
    return Dialog(
      backgroundColor: const Color(0xFF222222),
      insetPadding: metrics.insetPadding,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: _DanmakuDialogScope(
        metrics: metrics,
        child: Theme(
          data: Theme.of(context).copyWith(
            materialTapTargetSize: metrics.compact
                ? MaterialTapTargetSize.shrinkWrap
                : Theme.of(context).materialTapTargetSize,
            visualDensity: metrics.extraCompact
                ? const VisualDensity(horizontal: -4, vertical: -4)
                : metrics.compact
                ? const VisualDensity(horizontal: -2, vertical: -3)
                : VisualDensity.compact,
          ),
          child: ConstrainedBox(
            key: const ValueKey('danmaku-dialog-surface'),
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: Padding(
              padding: metrics.contentPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: metrics.titleSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (headerAction != null)
                        Expanded(
                          flex: 3,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: headerAction,
                            ),
                          ),
                        ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            Icons.close,
                            color: Colors.white70,
                            size: 22,
                          ),
                          visualDensity: VisualDensity.compact,
                          padding: metrics.extraCompact
                              ? const EdgeInsets.all(4)
                              : null,
                          constraints: metrics.extraCompact
                              ? const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: metrics.headerGap),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DanmakuPreview extends StatelessWidget {
  final SettingsService settings;

  const _DanmakuPreview({required this.settings});

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Container(
      height: metrics.previewHeight,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF172C3A), Color(0xFF576675)],
        ),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: _OutlinedPreviewText(
            text: '弹幕预览  Danmaku',
            type: settings.bilibiliDanmakuOutlineType,
            outlineScale: settings.bilibiliDanmakuOutlineScale,
            shadowScale: settings.bilibiliDanmakuShadowScale,
            letterSpacing: settings.bilibiliDanmakuLetterSpacing,
            fontFamily: settings.bilibiliDanmakuFontFamily,
            fontWeight: settings.bilibiliDanmakuFontWeight,
            fontSize: metrics.previewFontSize,
          ),
        ),
      ),
    );
  }
}

class _OutlineOption extends StatelessWidget {
  final DanmakuOutlineType type;
  final bool selected;
  final VoidCallback onTap;

  const _OutlineOption({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Material(
      color: selected ? _accent : const Color(0xFF555555),
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: metrics.outlineItemPadding,
          child: Column(
            children: [
              _OutlinedPreviewText(
                text: '弹幕',
                type: type,
                fontWeight: 600,
                fontSize: 18,
              ),
              SizedBox(height: metrics.extraCompact ? 2 : 5),
              Text(
                type.label,
                maxLines: 1,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                type.description,
                maxLines: 1,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: metrics.extraCompact ? 9 : 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutlinedPreviewText extends StatelessWidget {
  final double outlineScale, shadowScale, letterSpacing;
  final String text;
  final DanmakuOutlineType type;
  final String? fontFamily;
  final int fontWeight;
  final double fontSize;

  const _OutlinedPreviewText({
    required this.text,
    this.outlineScale = 1,
    this.shadowScale = 1,
    this.letterSpacing = 0,
    required this.type,
    this.fontFamily,
    required this.fontWeight,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    final width = resolveDanmakuOutlineWidth(type, fontSize) * outlineScale;
    final projectionDistance =
        resolveDanmakuProjectionDistance(type, fontSize) * shadowScale;
    final base = TextStyle(
      letterSpacing: fontSize * letterSpacing,
      fontFamily: fontFamily,
      fontWeight: danmakuFontWeight(fontWeight),
      fontSize: fontSize,
      height: 1,
    );
    return Stack(
      alignment: Alignment.center,
      children: [
        if (projectionDistance > 0)
          Transform.translate(
            offset: Offset(projectionDistance, projectionDistance),
            child: Text(
              text,
              style: base.copyWith(
                color: Colors.black87,
                shadows: type == DanmakuOutlineType.shadow
                    ? [
                        Shadow(
                          color: Colors.black87,
                          blurRadius: resolveDanmakuShadowBlur(type, fontSize),
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        if (width > 0)
          Text(
            text,
            style: base.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeJoin = StrokeJoin.round
                ..strokeWidth = width
                ..color = Colors.black,
            ),
          ),
        Text(text, style: base.copyWith(color: Colors.white)),
      ],
    );
  }
}

class _CheckboxRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Key? checkboxKey;

  const _CheckboxRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.checkboxKey = const ValueKey('danmaku-locked-speed-baseline-checkbox'),
  });

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    // Compact trailing checkbox so the extra setting can sit under the speed
    // slider without growing the dialog past a small phone viewport.
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: EdgeInsets.fromLTRB(0, metrics.extraCompact ? 0 : 2, 0, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: metrics.bodySize,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(
              width: 32,
              height: 32,
              child: IgnorePointer(
                child: Checkbox(
                  key: checkboxKey,
                  value: value,
                  onChanged: (_) {},
                  activeColor: _accent,
                  checkColor: Colors.white,
                  side: const BorderSide(color: Colors.white54, width: 1.25),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final metrics = _DanmakuDialogScope.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: metrics.sliderVerticalPadding),
      child: Row(
        children: [
          SizedBox(
            width: metrics.sliderLabelWidth,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: metrics.bodySize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: _accent,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: const Color(0x33FF6699),
                trackHeight: metrics.sliderTrackHeight,
                padding: metrics.sliderPadding,
                // Overlay padding is the main height sink on Material sliders.
                overlayShape: metrics.compact
                    ? SliderComponentShape.noOverlay
                    : RoundSliderOverlayShape(
                        overlayRadius: metrics.sliderThumbRadius + 8,
                      ),
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: metrics.sliderThumbRadius,
                ),
              ),
              child: metrics.compact
                  ? SizedBox(
                      height: metrics.extraCompact ? 25 : 32,
                      child: Slider(
                        value: value.clamp(min, max),
                        min: min,
                        max: max,
                        divisions: divisions,
                        onChanged: onChanged,
                      ),
                    )
                  : Slider(
                      value: value.clamp(min, max),
                      min: min,
                      max: max,
                      divisions: divisions,
                      onChanged: onChanged,
                    ),
            ),
          ),
          SizedBox(
            width: metrics.sliderValueWidth,
            child: Text(
              valueText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white70,
                fontSize: metrics.valueSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
