import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import '../services/default_settings_trial.dart';
import '../services/settings_service.dart';
import '../models/recommended_app_defaults.dart';
import '../utils/app_toast.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<void> toggleDefaultSettingsTrial(
  BuildContext context,
  SettingsService settings,
) async {
  final trial = settings.defaultSettingsTrial;
  if (trial.busy) return;
  if (!trial.hasBackup) {
    settings.defaultTrialDevice = DefaultSettingsDevice(
      defaultTargetPlatform,
      MediaQuery.sizeOf(context),
    );
  }
  try {
    final result = await trial.toggle();
    if (!context.mounted || result == null) return;
    AppToast.show(
      result == DefaultSettingsTrialResult.activated
          ? '${settings.defaultTrialDevice.label}默认方案已启用，原设置已备份；再次点击可恢复'
          : '已恢复测试前的全软件设置',
      type: AppToastType.success,
    );
  } catch (error) {
    if (!context.mounted) return;
    AppToast.show(
      trial.hasBackup
          ? '切换未完成，原设置备份仍保留，请点击恢复重试：$error'
          : '切换未完成，原设置未被替换：$error',
      type: AppToastType.error,
    );
  }
}

Future<void> showDefaultSettingsPlan(
  BuildContext context,
  SettingsService settings,
) {
  final device = settings.defaultSettingsTrial.hasBackup
      ? settings.defaultTrialDevice
      : DefaultSettingsDevice(
          defaultTargetPlatform,
          MediaQuery.sizeOf(context),
        );
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${device.label}默认设置方案'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('试用会先保存原设置；再次点击可恢复。账号、密钥、模型选择、媒体记录和本机路径保持原样。'),
            const SizedBox(height: 16),
            for (final entry in RecommendedAppDefaults.summary(
              device,
            ).entries) ...[
              Text(
                entry.key,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(entry.value),
              const SizedBox(height: 14),
            ],
            const Text('试用期间可以继续调整这些设置；恢复时会还原测试前的偏好。'),
          ],
        ),
      ),
      actions: [
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ),
      ],
    ),
  );
}

class DefaultSettingsTrialButton extends StatelessWidget {
  const DefaultSettingsTrialButton({super.key, required this.settings});
  final SettingsService settings;

  @override
  Widget build(BuildContext context) {
    final trial = settings.defaultSettingsTrial;
    return ListenableBuilder(
      listenable: trial,
      builder: (context, _) {
        final color = trial.hasBackup ? Colors.amberAccent : Colors.white;
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Tooltip(
              message: trial.hasBackup
                  ? '恢复测试前的全软件设置。长按查看默认方案。'
                  : '先备份原设置，再试用全软件默认方案。长按查看方案。',
              child: DesktopButtonClickRegion(
                child: TextButton.icon(
                  key: const ValueKey('default-settings-trial-toggle'),
                  onPressed: trial.busy
                      ? null
                      : () => toggleDefaultSettingsTrial(context, settings),
                  onLongPress: trial.busy
                      ? null
                      : () => showDefaultSettingsPlan(context, settings),
                  style: TextButton.styleFrom(
                    foregroundColor: color,
                    disabledForegroundColor: color.withValues(alpha: .5),
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(fontSize: 12),
                    side: BorderSide(color: color.withValues(alpha: .35)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                  icon: trial.busy
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: color,
                          ),
                        )
                      : Icon(
                          trial.hasBackup
                              ? Icons.settings_backup_restore
                              : Icons.science_outlined,
                          size: 17,
                        ),
                  label: Text(trial.label),
                ),
              ),
            ),
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: '查看默认设置方案',
                icon: const Icon(
                  Icons.info_outline,
                  size: 17,
                  color: Colors.white70,
                ),
                visualDensity: VisualDensity.compact,
                onPressed: trial.busy
                    ? null
                    : () => showDefaultSettingsPlan(context, settings),
              ),
            ),
          ],
        );
      },
    );
  }
}

class DefaultSettingsTrialNotice extends StatelessWidget {
  const DefaultSettingsTrialNotice({super.key, required this.settings});
  final SettingsService settings;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: settings.defaultSettingsTrial,
    builder: (context, _) {
      final trial = settings.defaultSettingsTrial;
      if (!trial.hasBackup) return const SizedBox.shrink();
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              trial.error == null ? '全软件默认设置测试中 · 原设置已保留' : '切换未完成 · 原设置备份已保留',
              style: const TextStyle(fontSize: 12, color: Colors.amberAccent),
            ),
            const SizedBox(height: 6),
            DefaultSettingsTrialButton(settings: settings),
          ],
        ),
      );
    },
  );
}
