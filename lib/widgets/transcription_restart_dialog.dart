import 'package:flutter/material.dart';
import '../features/model_center/model_center_service.dart';
import 'transcription_language_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// 转录页按钮、停止说明和重新开始确认共用的任务名。
///
/// 只转录时是「转录」。空闲主按钮另显示成「开始语音转录」。
String transcriptionJobTitle({
  required bool optimize,
  required bool translate,
}) {
  if (optimize && translate) return '转录、优化并翻译';
  if (translate) return '转录并翻译';
  if (optimize) return '转录并优化';
  return '转录';
}

Future<bool> confirmTranscriptionRestart(
  BuildContext context, {
  bool? withTranslation,
  bool optimize = false,
  ModelCenterService? modelCenter,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          withTranslation == null
              ? '从头开始转录？'
              : '重新开始${transcriptionJobTitle(optimize: optimize, translate: withTranslation)}？',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '将使用当前${_restartSettingsPhrase(withTranslation: withTranslation, optimize: optimize)}从头处理，本次断点将不再使用。'
                '已保存的字幕会保留，直到新结果生成。',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TranscriptionLanguageSelector(
                  center: modelCenter ?? ModelCenterService.instance,
                  buttonKey: const ValueKey('restart-transcription-language'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              key: const ValueKey('transcription-restart-confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(withTranslation == null ? '从头开始' : '重新开始'),
            ),
          ),
        ],
      ),
    ) ??
    false;

/// 确认框里说明这次会带上哪些设置。未指定翻译时保持原来的说法。
String _restartSettingsPhrase({
  required bool? withTranslation,
  required bool optimize,
}) {
  if (withTranslation == false && !optimize) return '转录设置';
  if (optimize && withTranslation == true) return '模型、优化与翻译设置';
  if (optimize) return '模型与优化设置';
  return '模型与翻译设置';
}
