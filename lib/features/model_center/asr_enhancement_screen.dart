import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';

import 'asr_enhancement_options.dart';
import 'asr_language_options.dart';
import 'model_catalog.dart';
import 'model_center_service.dart';
import 'model_center_widgets.dart';
import 'subtitle_segmentation_screen.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class AsrEnhancementScreen extends StatefulWidget {
  const AsrEnhancementScreen({super.key, required this.center});
  final ModelCenterService center;
  @override
  State<AsrEnhancementScreen> createState() => _AsrEnhancementScreenState();
}

class _AsrEnhancementScreenState extends State<AsrEnhancementScreen> {
  ModelCenterService get center => widget.center;
  Future<void> _update(
    AsrEnhancementOptions options, {
    bool download = true,
  }) async {
    center.updateAsrEnhancements(options);
    try {
      await center.settingsChanged();
      final model = center.artifact(center.asrProfile.model);
      if (download && model?.purpose == ModelPurpose.transcription) {
        await center.queueAsrEnhancements(model!);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Widget _card(String title, List<Widget> children) => ModelCenterPanel(
    title: title,
    icon: Icons.auto_fix_high_outlined,
    children: children,
  );

  Widget _toggle(
    String key,
    String title,
    String description,
    bool value,
    AsrEnhancementOptions Function(bool) change, {
    bool master = false,
    bool enabled = true,
  }) => SwitchListTile.adaptive(
    key: ValueKey(key),
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(title),
    subtitle: Text(description),
    value: value,
    onChanged: enabled && (master || center.asrEnhancements.enabled)
        ? (v) => _update(change(v))
        : null,
  );

  Widget _slider(
    String title,
    String value,
    double current,
    double min,
    double max,
    int divisions,
    AsrEnhancementOptions Function(double) change,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('$title · $value'),
      Slider(
        value: current.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        onChanged: center.asrEnhancements.enabled
            ? (v) => _update(change(v), download: false)
            : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('转录增强')),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: center,
        builder: (context, _) {
          final options = center.currentAsrEnhancements;
          final primary =
              center.artifact(center.asrProfile.model) ??
              center.artifact('sensevoice-small-int8');
          final required = options.requiredModels(
            primary?.languages ?? const ['zh', 'en'],
            primary == null
                ? center.effectiveAsrLanguage
                : center.languageForModel(primary),
            textProcessingVersion: currentAsrTextProcessingVersion,
            recognitionEngine: primary?.engine ?? '',
          );
          final packs = [for (final id in required) ?center.artifact(id)];
          final missing = packs.where((m) => !center.installed(m.id)).toList();
          final cards = <Widget>[
            _card('处理选项', [
              _toggle(
                'asr-enhancements-enabled',
                '启用本地转录增强',
                '默认开启，自动保存；对新建任务生效。关闭后的偏好会保留。',
                options.enabled,
                (v) => options.copyWith(enabled: v),
                master: true,
              ),
              _toggle(
                'asr-denoise',
                '轻量降噪',
                primary?.engine == 'parakeet-ja'
                    ? '此日语模型默认保留原音，动画对白实测更完整；噪声严重时可手动启用 GTCRN。'
                    : 'GTCRN 降低背景噪声；干净人声若出现失真可单独关闭。',
                options.denoise,
                (v) => options.copyWith(denoise: v),
              ),
              _toggle(
                'asr-alignment',
                '声学时间精校',
                '补齐缺失或不可靠的词块时间，已有完整时间时直接复用。日语、韩语使用共享精校；Qwen 支持更多语言。匹配不足时保留原时间。',
                options.alignment,
                (v) => options.copyWith(alignment: v),
              ),
              _toggle(
                'asr-always-align',
                '每条字幕都做声学精校',
                '默认关闭。开启后也精校已有原生时间的字幕，可能改善细粒度边界，但会明显增加耗时。',
                options.alwaysAlign,
                (v) => options.copyWith(alwaysAlign: v),
                enabled: options.alignment,
              ),
              _toggle(
                'asr-punctuation',
                '补充缺失标点',
                '支持中文、英文；仅为缺少句末标点的语音段补标点，保留识别原文。',
                options.punctuation,
                (v) => options.copyWith(punctuation: v),
              ),
              _toggle(
                'asr-trim',
                '修整首尾静音',
                '根据音频能量收紧字幕边界，并保护已对齐的语音时间。',
                options.trimSilence,
                (v) => options.copyWith(trimSilence: v),
              ),
              _toggle(
                'asr-review',
                '标记需要复核的片段',
                '时间精校失败或声学复核文字差异较大时提示。声学匹配度不代表识别准确率，不自动改写。',
                options.review,
                (v) => options.copyWith(review: v),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('字幕短句与长度'),
                subtitle: Text(center.subtitleSegmentation.summary),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => SubtitleSegmentationScreen(center: center),
                  ),
                ),
              ),
            ]),
            _card('增强模型与下载', [
              Text(
                '当前：${primary?.name ?? '请选择本地转录模型'} · ${asrLanguageLabel(primary == null ? center.effectiveAsrLanguage : center.languageForModel(primary))}',
              ),
              const SizedBox(height: 8),
              Text(
                packs.isEmpty
                    ? '当前选项无需额外模型。'
                    : '所需模型 ${modelBytes(packs.fold(0, (n, m) => n + m.bytes))}，待下载 ${modelBytes(missing.fold(0, (n, m) => n + m.bytes))}。',
              ),
              const SizedBox(height: 8),
              const Text(
                '选择本地转录模型后自动准备所需增强模型。离开页面后继续下载，支持镜像和断点续传，下载完成即可使用，可在模型中心管理下载源。',
              ),
              for (final model in packs) ...[
                const Divider(height: 20),
                Text(model.name, style: Theme.of(context).textTheme.bodyLarge),
                Text(
                  '${model.parameters} · ${modelBytes(model.bytes)} · 建议 ${model.suggestedRamGb} GB 内存起测',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(center.downloads[model.id]?.label ?? '未下载'),
                    ),
                    if (!center.installed(model.id))
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () async {
                            try {
                              await center.enqueue(model.id);
                            } catch (error) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('$error')),
                                );
                              }
                            }
                          },
                          child: Text(
                            center.downloads[model.id]?.phase ==
                                    ModelDownloadPhase.paused
                                ? '继续'
                                : '下载',
                          ),
                        ),
                      ),
                  ],
                ),
                if (center.downloads[model.id]?.phase ==
                    ModelDownloadPhase.downloading)
                  ModelCenterProgress(
                    value:
                        ((center.downloads[model.id]?.received ?? 0) /
                                model.bytes)
                            .clamp(0, 1),
                  ),
                if (center.downloads[model.id]?.message.isNotEmpty == true)
                  Text(
                    center.downloads[model.id]!.message,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              const SizedBox(height: 12),
              const Text('同一套增强模型文件适用于各平台。增强会增加处理时间；资源不足时会调整调度或按阶段加载。'),
            ]),
            _card('音频声道', [
              CapsuleDropdownButtonFormField<AsrAudioChannel>(
                key: ValueKey('asr-channel-${options.channel.name}'),
                initialValue: options.channel,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '音频声道',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: AsrAudioChannel.mix,
                    child: Text('混合声道 · 默认'),
                  ),
                  DropdownMenuItem(
                    value: AsrAudioChannel.left,
                    child: Text('仅左声道'),
                  ),
                  DropdownMenuItem(
                    value: AsrAudioChannel.right,
                    child: Text('仅右声道'),
                  ),
                ],
                onChanged: options.enabled
                    ? (v) =>
                          _update(options.copyWith(channel: v), download: false)
                    : null,
              ),
              const SizedBox(height: 12),
              const Text('声道隔离适合双语左右声道或单侧噪声录音。单声道素材使用原声道。'),
              const SizedBox(height: 12),
              const Text('Qwen3-ASR 热词在每个视频的 AI 智能页单独设置，支持命名预设，不会自动带到其他视频。'),
            ]),
            _card('语音检测与边界', [
              const Text('缩短静音间隔有助于拆开连续语音；过短容易切碎。字幕显示长度仍由“字幕短句与长度”控制。'),
              const SizedBox(height: 12),
              _slider(
                '语音检测阈值',
                options.vadThreshold.toStringAsFixed(2),
                options.vadThreshold,
                .15,
                .85,
                14,
                (v) => options.copyWith(vadThreshold: v),
              ),
              _slider(
                '分段所需静音',
                '${options.minSilenceMs} ms',
                options.minSilenceMs.toDouble(),
                150,
                1500,
                27,
                (v) => options.copyWith(minSilenceMs: v.round()),
              ),
              _slider(
                '最短有效语音',
                '${options.minSpeechMs} ms',
                options.minSpeechMs.toDouble(),
                100,
                1000,
                45,
                (v) => options.copyWith(minSpeechMs: v.round()),
              ),
              _slider(
                '最长语音段',
                '${(options.maxSpeechMs / 1000).toStringAsFixed(1)} 秒',
                options.maxSpeechMs.toDouble(),
                5000,
                25000,
                40,
                (v) => options.copyWith(maxSpeechMs: v.round()),
              ),
              _slider(
                '语音前后留白',
                '${options.paddingMs} ms',
                options.paddingMs.toDouble(),
                0,
                500,
                25,
                (v) => options.copyWith(paddingMs: v.round()),
              ),
              const Text('留白保护词首、词尾，不会越过相邻语音段的中点。'),
            ]),
          ];
          return LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final bodyWidth = width.clamp(0.0, 1280.0);
              return SingleChildScrollView(
                key: const PageStorageKey('asr-enhancements-scroll'),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: bodyWidth,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: width >= 1000
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [
                                      cards[0],
                                      const SizedBox(height: 12),
                                      cards[3],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    children: [
                                      cards[1],
                                      const SizedBox(height: 12),
                                      cards[2],
                                    ],
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                for (final card in cards)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: card,
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}
