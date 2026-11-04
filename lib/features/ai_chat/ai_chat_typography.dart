import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_chat_layout.dart';
import 'ai_capsule_menu.dart';
import '../../widgets/anchored_menu_layout.dart';
import '../../theme/app_typography.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Reading preferences are independent of model credentials and generation.
/// All open conversation surfaces share the same relative size preference.
class AiChatReadingSettings extends ValueNotifier<double> {
  AiChatReadingSettings({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance,
      super(1);

  static final instance = AiChatReadingSettings();
  static const preferenceKey = 'ai_chat_reading_scale_v1';
  static const minimum = .8;
  static const maximum = 1.6;
  final Future<SharedPreferences> Function() _preferences;
  Future<void>? _loading;
  Future<void>? _writing;
  int _revision = 0;

  static double normalize(double scale) =>
      scale.isFinite ? scale.clamp(minimum, maximum).toDouble() : 1;

  Future<void> load() => _loading ??= _load();
  Future<void> flushPreferencesForTrial() async {
    await _writing;
  }

  Future<void> reloadPreferencesForTrial() async {
    await _writing;
    ++_revision;
    final raw = (await _preferences()).get(preferenceKey);
    value = normalize(raw is num ? raw.toDouble() : 1);
  }

  Future<void> _load() async {
    final revision = _revision;
    try {
      final preferences = await _preferences();
      final raw = preferences.get(preferenceKey);
      if (_revision == revision && raw is num) {
        value = normalize(raw.toDouble());
      }
    } catch (_) {
      // An unavailable preference store must not prevent reading a reply.
    }
  }

  Future<void> setScale(double scale) {
    final normalized = normalize(scale);
    ++_revision;
    value = normalized;
    final operation = (_writing ?? Future<void>.value()).then((_) async {
      final preferences = await _preferences();
      if (!await preferences.setDouble(preferenceKey, normalized)) {
        throw StateError('字号保存失败，请重试。');
      }
    });
    // Serialize slider updates, and let later changes retry a failed write.
    late final Future<void> tail;
    tail = operation.catchError((Object _) {}).whenComplete(() {
      if (identical(_writing, tail)) _writing = null;
    });
    _writing = tail;
    return operation;
  }
}

@immutable
class AiChatTextMetrics {
  const AiChatTextMetrics({
    this.fontSize = 14,
    this.dense = false,
    double? baseFontSize,
  }) : baseFontSize = baseFontSize ?? fontSize;

  factory AiChatTextMetrics.resolve({
    required double panelWidth,
    required Size screen,
    required bool fullscreen,
    double scale = 1,
  }) {
    // Screen orientation is stable while the keyboard animates. Do not shrink
    // reading text merely because the input method reduced the panel height.
    final phoneLandscape =
        screen.shortestSide < 600 &&
        screen.width > screen.height &&
        !fullscreen;
    final base = phoneLandscape || panelWidth < 320
        ? 12.0
        : panelWidth < 380
        ? 13.0
        : panelWidth < 600
        ? 14.0
        : panelWidth < 1000
        ? 15.0
        : 16.0;
    return AiChatTextMetrics(
      baseFontSize: base,
      fontSize: (base * AiChatReadingSettings.normalize(scale)).clamp(11, 26),
      dense: phoneLandscape || panelWidth < 380,
    );
  }

  final double fontSize;
  final double baseFontSize;
  final bool dense;
  double get horizontalInset => dense ? 8 : 12;
  double get lineHeight => dense ? 1.45 : 1.6;
  double get codeSize => fontSize - 1;
  double get heading1 => fontSize * (dense ? 1.4 : 1.55);
  double get heading2 => fontSize * (dense ? 1.25 : 1.35);
  double get heading3 => fontSize * 1.14;
  double get blockSpacing => dense ? 6 : 10;
  TextStyle get bodyStyle =>
      appReadingStyle.copyWith(fontSize: fontSize, height: lineHeight);

  @override
  bool operator ==(Object other) =>
      other is AiChatTextMetrics &&
      other.fontSize == fontSize &&
      other.baseFontSize == baseFontSize &&
      other.dense == dense;
  @override
  int get hashCode => Object.hash(fontSize, baseFontSize, dense);
}

class AiChatTypography extends InheritedWidget {
  const AiChatTypography({
    super.key,
    required this.metrics,
    required super.child,
  });
  final AiChatTextMetrics metrics;

  static AiChatTextMetrics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AiChatTypography>()?.metrics ??
      const AiChatTextMetrics();

  @override
  bool updateShouldNotify(AiChatTypography oldWidget) =>
      metrics != oldWidget.metrics;
}

Future<void> showAiChatReadingSettings(
  BuildContext context, {
  required AiChatTextMetrics metrics,
  BuildContext? anchorContext,
  AiChatReadingSettings? settings,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭字体大小调节',
  barrierColor: Colors.transparent,
  transitionDuration: const Duration(milliseconds: 140),
  pageBuilder: (_, _, _) => Theme(
    data: aiChatDialogTheme(Theme.of(context)),
    child: Material(
      type: MaterialType.transparency,
      child: AnchoredMenuLayout(
        position: AnchoredMenuPosition.fromContext(anchorContext ?? context),
        width: 320,
        maxHeight: 200,
        child: _ReadingSettingsPopover(
          settings: settings ?? AiChatReadingSettings.instance,
          metrics: metrics,
        ),
      ),
    ),
  ),
  transitionBuilder: (_, animation, _, child) =>
      FadeTransition(opacity: animation, child: child),
);

class _ReadingSettingsPopover extends StatefulWidget {
  const _ReadingSettingsPopover({
    required this.settings,
    required this.metrics,
  });
  final AiChatReadingSettings settings;
  final AiChatTextMetrics metrics;

  @override
  State<_ReadingSettingsPopover> createState() =>
      _ReadingSettingsPopoverState();
}

class _ReadingSettingsPopoverState extends State<_ReadingSettingsPopover> {
  String? _error;
  int _writeRevision = 0;

  Future<void> _change(double scale) async {
    final revision = ++_writeRevision;
    setState(() => _error = null);
    try {
      await widget.settings.setScale(scale);
    } catch (_) {
      if (mounted && revision == _writeRevision) {
        setState(() => _error = '字号已应用，保存失败，请重试。');
      }
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: widget.settings,
    builder: (context, scale, _) => Semantics(
      namesRoute: true,
      label: '字体大小',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Material(
            key: const ValueKey('ai-chat-font-popover'),
            color: const Color(0xFF242424).withValues(alpha: .84),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: Colors.white.withValues(alpha: .12)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 4),
                      Expanded(
                        child: Tooltip(
                          message:
                              '当前正文约 ${(widget.metrics.baseFontSize * scale).clamp(11, 26).round()} px',
                          child: Text(
                            '字体大小 · ${(scale * 100).round()}%',
                            key: const ValueKey('ai-chat-font-scale-label'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () => unawaited(_change(1)),
                          child: const Text('恢复默认'),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('完成'),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      aiToolbarIcon(
                        tooltip: '缩小字体',
                        icon: Icons.text_decrease,
                        onPressed: scale <= AiChatReadingSettings.minimum
                            ? null
                            : () => unawaited(_change(scale - .05)),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 14,
                            ),
                          ),
                          child: Slider(
                            key: const ValueKey('ai-chat-font-scale'),
                            label: '${(scale * 100).round()}%',
                            min: AiChatReadingSettings.minimum,
                            max: AiChatReadingSettings.maximum,
                            divisions: 16,
                            value: scale,
                            onChanged: (value) => unawaited(_change(value)),
                          ),
                        ),
                      ),
                      aiToolbarIcon(
                        tooltip: '放大字体',
                        icon: Icons.text_increase,
                        onPressed: scale >= AiChatReadingSettings.maximum
                            ? null
                            : () => unawaited(_change(scale + .05)),
                      ),
                    ],
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
