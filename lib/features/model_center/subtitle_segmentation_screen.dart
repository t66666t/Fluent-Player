import 'package:flutter/material.dart';

import '../../models/subtitle_model.dart';
import 'model_center_service.dart';
import 'model_center_widgets.dart';
import 'subtitle_segmentation.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

class SubtitleSegmentationScreen extends StatelessWidget {
  const SubtitleSegmentationScreen({super.key, required this.center});
  final ModelCenterService center;

  Future<void> _update(
    BuildContext context,
    SubtitleSegmentationOptions options,
  ) async {
    center.subtitleSegmentation = options;
    try {
      await center.settingsChanged();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存分句设置失败：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('字幕分句')),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: center,
        builder: (context, _) {
          final options = center.subtitleSegmentation;
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  ModelCenterPanel(
                    title: '分句设置',
                    icon: Icons.segment_rounded,
                    children: [
                      const Text('按语义与停顿整理字幕长度。自动保存，对新建本地转录任务生效。'),
                      const SizedBox(height: 16),
                      CapsuleDropdownButtonFormField<String>(
                        key: ValueKey('segmentation-preset-${options.preset}'),
                        initialValue: options.preset,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '分句方案',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'natural',
                            child: Text('自然分句 · 推荐'),
                          ),
                          DropdownMenuItem(value: 'short', child: Text('短句')),
                          DropdownMenuItem(
                            value: 'standard',
                            child: Text('标准'),
                          ),
                          DropdownMenuItem(
                            value: 'original',
                            child: Text('保留原始语音段'),
                          ),
                          DropdownMenuItem(
                            value: 'custom',
                            enabled: false,
                            child: Text('自定义'),
                          ),
                        ],
                        onChanged: (value) => _update(context, switch (value) {
                          'natural' => SubtitleSegmentationOptions.natural,
                          'short' => SubtitleSegmentationOptions.short,
                          'standard' => SubtitleSegmentationOptions.standard,
                          'original' => SubtitleSegmentationOptions.original,
                          _ => options.copyWith(enabled: true),
                        }),
                      ),
                      const SizedBox(height: 16),
                      _fields(context, options),
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        key: const ValueKey('segmentation-natural'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('结合句子与停顿重新分句'),
                        subtitle: const Text(
                          '衔接相邻语音片段，优先句末、从句与停顿，尽量避免在介词、冠词之后断开。',
                        ),
                        value: options.naturalBreaks,
                        onChanged: options.enabled
                            ? (v) => _update(
                                context,
                                options.copyWith(naturalBreaks: v),
                              )
                            : null,
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('按句末标点分句'),
                        subtitle: const Text('优先在句号、问号、感叹号处分开；长句尽量在逗号附近拆分。'),
                        value: options.splitOnPunctuation,
                        onChanged: !options.enabled
                            ? null
                            : (value) => _update(
                                context,
                                options.copyWith(splitOnPunctuation: value),
                              ),
                      ),
                      SwitchListTile.adaptive(
                        key: const ValueKey('segmentation-estimated'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('无词级时间时允许估算分句'),
                        subtitle: const Text(
                          '默认关闭。开启后按文字长度估算句级时间，可能与语音有偏差；不会生成逐词时间。',
                        ),
                        value: options.allowEstimatedTiming,
                        onChanged: !options.enabled
                            ? null
                            : (value) => _update(
                                context,
                                options.copyWith(allowEstimatedTiming: value),
                              ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '自然分句以时长和长度为参考，可在目标附近选择更完整的边界；保留单词与模型词块，不制造词级时间。缺少可靠时间轴时保留原片段。',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ModelCenterPanel(
                    title: '分句预览',
                    subtitle: '示意文本与时间轴；实际分句以识别结果为准。',
                    icon: Icons.subtitles_outlined,
                    children: [
                      for (final sample in [
                        ('中文', _sample()),
                        ('English', _englishSample()),
                      ]) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 4),
                          child: Text(
                            sample.$1,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        for (final cue in segmentAsrSubtitles([
                          sample.$2,
                        ], options))
                          Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_time(cue.startTime)} → ${_time(cue.endTime)}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(cue.text),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _fields(BuildContext context, SubtitleSegmentationOptions options) {
    final duration = CapsuleDropdownButtonFormField<int>(
      key: ValueKey('segmentation-duration-${options.maxDurationMs}'),
      initialValue: options.maxDurationMs,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '每条时长目标',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final ms in ({
          2000,
          3000,
          4000,
          5000,
          6000,
          8000,
          10000,
          12000,
          options.maxDurationMs,
        }.toList()..sort()))
          DropdownMenuItem(
            value: ms,
            child: Text(
              '${ms / 1000 == ms ~/ 1000 ? ms ~/ 1000 : ms / 1000} 秒',
            ),
          ),
      ],
      onChanged: !options.enabled
          ? null
          : (value) => _update(context, options.copyWith(maxDurationMs: value)),
    );
    final width = CapsuleDropdownButtonFormField<int>(
      key: ValueKey('segmentation-width-${options.maxWidth}'),
      initialValue: options.maxWidth,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '中文等每条长度目标',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final cells in ({
          32,
          40,
          56,
          72,
          96,
          120,
          options.maxWidth,
        }.toList()..sort()))
          DropdownMenuItem(value: cells, child: Text('中文约 ${cells ~/ 2} 字')),
      ],
      onChanged: !options.enabled
          ? null
          : (value) => _update(context, options.copyWith(maxWidth: value)),
    );
    final latin = CapsuleDropdownButtonFormField<int>(
      key: ValueKey(
        'segmentation-latin-${options.maxLatinWidth ?? options.maxWidth}',
      ),
      initialValue: options.maxLatinWidth ?? options.maxWidth,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '英文等每条字符目标',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final cells in ({
          32,
          40,
          56,
          64,
          72,
          80,
          96,
          120,
          options.maxLatinWidth ?? options.maxWidth,
        }.toList()..sort()))
          DropdownMenuItem(value: cells, child: Text('$cells 字符')),
      ],
      onChanged: options.enabled
          ? (v) => _update(context, options.copyWith(maxLatinWidth: v))
          : null,
    );
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= 640
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: duration),
                const SizedBox(width: 12),
                Expanded(child: width),
                const SizedBox(width: 12),
                Expanded(child: latin),
              ],
            )
          : Column(
              children: [
                duration,
                const SizedBox(height: 16),
                width,
                const SizedBox(height: 16),
                latin,
              ],
            ),
    );
  }

  static String _time(Duration value) =>
      '${value.inSeconds}.${(value.inMilliseconds % 1000).toString().padLeft(3, '0')}s';

  static SubtitleItem _sample() {
    const text = '今天我们来了解本地字幕转录。先保持完整的语音上下文，再把识别结果分成短句，这样阅读会更轻松。';
    return SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: Duration(milliseconds: text.length * 240),
      text: text,
      timedSpans: [
        for (var i = 0; i < text.length; i++)
          SubtitleTimedSpan(
            textStart: i,
            textEnd: i + 1,
            startTime: Duration(milliseconds: i * 240),
            endTime: Duration(milliseconds: (i + 1) * 240),
            role: 'token',
          ),
      ],
    );
  }

  static SubtitleItem _englishSample() {
    const text =
        'We wanted to understand what this means, because small changes can make a real difference.';
    final words = RegExp(r'\S+').allMatches(text).toList();
    return SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: Duration(milliseconds: words.length * 400),
      text: text,
      timedSpans: [
        for (var i = 0; i < words.length; i++)
          SubtitleTimedSpan(
            textStart: words[i].start,
            textEnd: words[i].end,
            startTime: Duration(milliseconds: i * 400),
            endTime: Duration(milliseconds: (i + 1) * 400),
            role: 'token',
          ),
      ],
    );
  }
}
