import 'package:flutter/material.dart';

import '../models/subtitle_model.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class SubtitleAsrInfoButton extends StatelessWidget {
  const SubtitleAsrInfoButton({super.key, required this.subtitle});
  final SubtitleItem subtitle;
  @override
  Widget build(BuildContext context) {
    final info = subtitle.asrInfo;
    final review = info.reviewReason.isNotEmpty;
    if (!info.hasData) return const SizedBox.shrink();
    return DesktopButtonClickRegion(
      child: IconButton(
        key: ValueKey('subtitle-asr-info-${subtitle.index}'),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        padding: const EdgeInsets.all(4),
        iconSize: 17,
        tooltip: review ? '此片段需要复核' : '转录增强信息',
        color: review ? Colors.amber : Colors.blueGrey,
        icon: Icon(review ? Icons.fact_check_outlined : Icons.info_outline),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(review ? '转录片段复核' : '转录增强信息'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: SelectionArea(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(subtitle.text),
                      const Divider(height: 24),
                      if (info.language.isNotEmpty)
                        Text('识别语言：${info.language}'),
                      if (info.backend.isNotEmpty) Text('识别后端：${info.backend}'),
                      if (info.speaker.isNotEmpty)
                        Text(
                          '匿名说话人：${info.speaker.replaceFirst('speaker-', '')}',
                        ),
                      if (info.alignmentScore != null) ...[
                        Text(
                          '声学对齐匹配度：${(info.alignmentScore! * 100).round()}%',
                        ),
                        const Text('此数值只反映音频与原文的对齐匹配，不代表识别准确率。'),
                      ],
                      if (review) ...[
                        const SizedBox(height: 12),
                        Text(info.reviewReason),
                      ],
                      if (info.alternateText.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text('声学复核参考文字（未替换原文）'),
                        Text(info.alternateText),
                      ],
                      for (final note in info.notes)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(note),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
