import 'package:flutter/material.dart';

import '../features/model_center/model_center_screen.dart';
import '../features/model_center/model_center_service.dart';
import '../services/subtitle_translate_settings.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Opens feature bindings while keeping the current subtitle workflow mounted.
class ModelCenterButton extends StatelessWidget {
  const ModelCenterButton({
    super.key,
    this.compact = false,
    this.foregroundColor,
    this.onPressed,
    this.translateSettings,
    this.service,
  });

  final bool compact;
  final Color? foregroundColor;
  final VoidCallback? onPressed;
  final SubtitleTranslateSettings? translateSettings;
  final ModelCenterService? service;

  @override
  Widget build(BuildContext context) {
    void open() => openModelCenter(
      context,
      tab: 0,
      translateSettings: translateSettings,
      service: service,
    );
    if (compact) {
      return DesktopButtonClickRegion(
        child: IconButton(
          tooltip: '模型中心（转录与翻译）',
          color: foregroundColor,
          icon: const Icon(Icons.tune_rounded, size: 20),
          onPressed: onPressed ?? open,
        ),
      );
    }
    return DesktopButtonClickRegion(
      child: TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: foregroundColor),
        onPressed: onPressed ?? open,
        icon: const Icon(Icons.tune_rounded, size: 18),
        label: const Text('模型中心', maxLines: 1),
      ),
    );
  }
}
