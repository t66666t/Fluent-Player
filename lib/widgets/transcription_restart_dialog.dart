import 'package:flutter/material.dart';
import '../features/model_center/model_center_service.dart';
import 'transcription_language_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

Future<bool> confirmTranscriptionRestart(
  BuildContext context, {
  bool? withTranslation,
  ModelCenterService? modelCenter,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          withTranslation == null
              ? '从头开始转录？'
              : '重新开始${withTranslation ? '转录并翻译' : '转录'}？',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '将使用当前${withTranslation == false ? '转录设置' : '模型与翻译设置'}从头处理，本次断点将不再使用。'
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
          DesktopButtonClickRegion(child: TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          )),
          DesktopButtonClickRegion(child: FilledButton(
            key: const ValueKey('transcription-restart-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(withTranslation == null ? '从头开始' : '重新开始'),
          )),
        ],
      ),
    ) ??
    false;
