import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/processing_screen_protection_timing.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import 'desktop_button_click_region.dart';
import 'media_library_settings_controls.dart';

const _settingsLocation = '媒体库 → 设置 → 闲置屏幕保护';

Future<void> showProcessingScreenProtectionInfo(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (context) => _ProtectionDialog(
        title: const Text('防烧屏有什么用？'),
        content: const SizedBox(
          width: 420,
          child: Text(
            '当字幕转录、OCR 等任务正在处理，并通过“处理时不息屏”保持亮屏时，'
            '连续闲置达到设定秒数后，会淡入黑色屏幕，只显示低亮度的任务进度。'
            '显示内容会定期换位，减少静态画面长时间停留造成的烧屏风险，但不能完全避免烧屏。\n\n'
            '播放音频或视频、加载或缓冲媒体时不会进入。触摸、鼠标、键盘、滚动、'
            '输入文字或打开弹窗时也不会进入；这些活动结束后重新完整计时。'
            '仅有后台任务进度变化不算操作。\n\n'
            '点击空白处或进度、按键或返回可临时退出，任务会继续运行。'
            '勾选“关闭防烧屏”可打开确认窗口，关闭此功能或修改等待时间。\n\n'
            '默认等待 15 秒，可在“$_settingsLocation”随时调整。'
            '此设置不控制系统息屏时间，也不会改变任务的亮屏开关。',
          ),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: AppHaptics.wrap(
                () => Navigator.of(context).pop(),
                light: true,
              ),
              child: const Text('知道了'),
            ),
          ),
        ],
      ),
    );

Future<void> showProcessingScreenProtectionSettings(
  BuildContext context,
  SettingsService settings, {
  bool confirmDisable = false,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ProtectionSettingsDialog(
    settings: settings,
    confirmDisable: confirmDisable,
  ),
);

/// Shared by the library settings and the protection display's exit control.
class ProcessingScreenProtectionSettings extends StatelessWidget {
  const ProcessingScreenProtectionSettings({super.key, required this.settings});
  final SettingsService settings;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings,
    builder: (context, _) => MediaLibrarySettingsRow(
      key: const ValueKey('processing-protection-enabled'),
      title: const Text('闲置屏幕保护'),
      description: const Text('处理亮屏时启用'),
      value: DesktopButtonClickRegion(
        child: TextButton(
          key: const ValueKey('processing-protection-wait'),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF9B9A97),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 44),
            textStyle: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 13),
          ),
          onPressed: AppHaptics.wrap(
            () => showProcessingScreenProtectionSettings(context, settings),
            light: true,
          ),
          child: Text('${settings.processingScreenProtectionWaitSeconds} 秒'),
        ),
      ),
      informationKey: const ValueKey('processing-protection-info'),
      informationLabel: '防烧屏说明',
      onInformation: () => showProcessingScreenProtectionInfo(context),
      toggled: settings.processingScreenProtection,
      trailing: ExcludeSemantics(
        child: ExcludeFocus(
          child: MediaLibrarySettingsSwitch(
            value: settings.processingScreenProtection,
            onChanged: (value) =>
                settings.updateSetting('processingScreenProtection', value),
          ),
        ),
      ),
      onTap: () => settings.updateSetting(
        'processingScreenProtection',
        !settings.processingScreenProtection,
      ),
    ),
  );
}

class _ProtectionSettingsDialog extends StatefulWidget {
  const _ProtectionSettingsDialog({
    required this.settings,
    required this.confirmDisable,
  });
  final SettingsService settings;
  final bool confirmDisable;

  @override
  State<_ProtectionSettingsDialog> createState() =>
      _ProtectionSettingsDialogState();
}

class _ProtectionSettingsDialogState extends State<_ProtectionSettingsDialog> {
  final _form = GlobalKey<FormState>();
  late final _seconds = TextEditingController(
    text: '${widget.settings.processingScreenProtectionWaitSeconds}',
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _seconds.dispose();
    super.dispose();
  }

  Future<void> _save({bool disable = false}) async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.settings.updateSetting(
        'processingScreenProtectionWaitSeconds',
        int.parse(_seconds.text.trim()),
      );
      if (disable) {
        await widget.settings.updateSetting(
          'processingScreenProtection',
          false,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '设置未能保存，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _ProtectionDialog(
    key: const ValueKey('processing-protection-settings-dialog'),
    title: Text(widget.confirmDisable ? '关闭防烧屏？' : '防烧屏等待时间'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.confirmDisable
                  ? '关闭后，任务仍按“处理时不息屏”设置保持亮屏。'
                        '可在“$_settingsLocation”重新开启。\n\n'
                        '也可只保存等待时间，保留防烧屏。'
                  : '在没有媒体播放且没有操作时开始计时。'
                        '播放、滚动、输入或弹窗结束后，会重新等待完整时长。',
            ),
            const SizedBox(height: 20),
            TextFormField(
              key: const ValueKey('processing-protection-seconds'),
              controller: _seconds,
              style: const TextStyle(fontSize: 14),
              enabled: !_saving,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '防烧屏等待时间',
                suffixText: '秒',
                helperText: '默认 15 秒，可输入 1–86400 秒。',
                helperMaxLines: 2,
                errorMaxLines: 2,
                border: OutlineInputBorder(),
                isDense: true,
              ),
              validator: (text) {
                final seconds = int.tryParse(text?.trim() ?? '');
                return seconds == null ||
                        seconds < ProcessingScreenProtectionTiming.minSeconds ||
                        seconds > ProcessingScreenProtectionTiming.maxSeconds
                    ? '请输入 1–86400 之间的整数秒数'
                    : null;
              },
              onFieldSubmitted: (_) => _save(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: AppHaptics.wrap(
            _saving ? null : () => Navigator.of(context).pop(),
            light: true,
          ),
          child: const Text('取消'),
        ),
      ),
      if (widget.confirmDisable)
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: AppHaptics.wrap(
              _saving ? null : () => _save(),
              light: true,
            ),
            child: const Text('保存等待时间'),
          ),
        ),
      DesktopButtonClickRegion(
        child: FilledButton(
          onPressed: AppHaptics.wrap(
            _saving ? null : () => _save(disable: widget.confirmDisable),
            light: true,
          ),
          child: Text(widget.confirmDisable ? '确认关闭' : '保存'),
        ),
      ),
    ],
  );
}

/// On short screens (including the on-screen keyboard), title and actions
/// scroll with the content so they cannot squeeze the editor out of the dialog.
class _ProtectionDialog extends StatelessWidget {
  const _ProtectionDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });
  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium!.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
    );
    final bodyStyle = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 13,
      height: 1.5,
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    if (media.size.height - media.viewInsets.bottom >= 440 &&
        media.textScaler.scale(14) <= 21) {
      return AlertDialog(
        backgroundColor: const Color(0xFF252525),
        surfaceTintColor: Colors.transparent,
        shape: shape,
        title: title,
        titleTextStyle: titleStyle,
        titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        content: content,
        contentTextStyle: bodyStyle,
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        actions: actions,
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      );
    }
    return Dialog(
      backgroundColor: const Color(0xFF252525),
      surfaceTintColor: Colors.transparent,
      shape: shape,
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 468),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefaultTextStyle(style: titleStyle, child: title),
              const SizedBox(height: 20),
              DefaultTextStyle(style: bodyStyle, child: content),
              const SizedBox(height: 20),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                overflowSpacing: 4,
                children: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
