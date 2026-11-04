import 'dart:async';
import 'package:flutter/material.dart';
import '../models/local_asr_progress.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class LocalAsrProgressView extends StatefulWidget {
  const LocalAsrProgressView({
    super.key,
    required this.progress,
    this.compact = false,
    this.foregroundColor,
    this.compactFontSize,
  });
  final LocalAsrProgress progress;
  final bool compact;
  final Color? foregroundColor;
  final double? compactFontSize;
  @override
  State<LocalAsrProgressView> createState() => _LocalAsrProgressViewState();
}

class _LocalAsrProgressViewState extends State<LocalAsrProgressView> {
  Timer? _timer;
  ValueNotifier<LocalAsrProgress?>? _dialogProgress;
  void _publishDialog(LocalAsrProgress? value) {
    final live = _dialogProgress;
    if (live == null) return;
    scheduleMicrotask(() {
      if (identical(_dialogProgress, live)) live.value = value;
    });
  }

  @override
  void didUpdateWidget(covariant LocalAsrProgressView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publishDialog(widget.progress);
  }

  @override
  void initState() {
    super.initState();
    if (!widget.compact) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _publishDialog(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.progress;
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: widget.foregroundColor);
    Widget lane(
      String title,
      LocalAsrLaneProgress state,
      Duration covered,
      double value,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.compact
              ? '$title ${(value * 100).floor()}%'
              : '$title ${LocalAsrProgress.clock(covered)} / ${LocalAsrProgress.clock(p.total)}',
          style: style?.copyWith(
            fontSize: widget.compact ? (widget.compactFontSize ?? 9) : 12,
          ),
          maxLines: widget.compact ? 1 : null,
        ),
        if (!widget.compact)
          Text(
            state.label,
            style: style?.copyWith(fontSize: 11),
            softWrap: true,
          ),
        const SizedBox(height: 3),
        LinearProgressIndicator(
          value: value,
          minHeight: widget.compact ? 2 : 3,
          borderRadius: BorderRadius.circular(99),
        ),
      ],
    );
    final elapsed = p.elapsed + DateTime.now().difference(p.capturedAt);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.compact) ...[
          Text('${p.model} · ${p.backend}', style: style),
          Text(p.mode, style: style?.copyWith(fontWeight: FontWeight.w600)),
          if (p.audioPreparation.isNotEmpty)
            Text(p.audioPreparation, style: style?.copyWith(fontSize: 11)),
          if (!p.pipeline && p.pipelineRequested ||
              p.limitReason.isNotEmpty && p.limitReason != 'none')
            Text(p.reason, style: style?.copyWith(fontSize: 11)),
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              key: const PageStorageKey('asr-resource-details'),
              dense: true,
              tilePadding: EdgeInsets.zero,
              title: Text('运行详情', style: style),
              children: [
                Text(
                  '识别 ${p.asrThreads} 线程 · 辅助 ${p.enhancementThreads} 线程\n${p.reason}',
                  style: style,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (p.preprocessAhead && !widget.compact) ...[
          lane('降噪', p.preparation, p.prepared, p.preparationFraction),
          const SizedBox(height: 8),
        ],
        lane('识别', p.recognition, p.recognized, p.recognitionFraction),
        SizedBox(height: widget.compact ? 4 : 8),
        lane('增强', p.enhancement, p.enhanced, p.enhancementFraction),
        if (!widget.compact) ...[
          const SizedBox(height: 8),
          Text(
            '已完成 ${p.completedPieces}/${p.pieces} 块 · 本地已用 ${LocalAsrProgress.clock(elapsed)}'
            '${p.reusedPieces > 0 ? ' · 复用 ${p.reusedPieces} 块' : ''}',
            style: style?.copyWith(fontSize: 11),
          ),
          Text(
            '以上为音频处理进度；总进度还包括保存及已开启的翻译。',
            style: TextStyle(fontSize: 10, color: widget.foregroundColor),
          ),
        ],
      ],
    );
    if (!widget.compact) return content;
    return Tooltip(
      message: p.summary,
      child: InkWell(
        onTap: () async {
          if (_dialogProgress != null) return;
          final live = ValueNotifier<LocalAsrProgress?>(p);
          _dialogProgress = live;
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('本地转录进度'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: ValueListenableBuilder<LocalAsrProgress?>(
                    valueListenable: live,
                    builder: (context, value, _) => value == null
                        ? const Text('本地处理已结束或暂停，请查看任务状态。')
                        : LocalAsrProgressView(progress: value),
                  ),
                ),
              ),
              actions: [
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ),
              ],
            ),
          );
          if (identical(_dialogProgress, live)) _dialogProgress = null;
          live.dispose();
        },
        child: content,
      ),
    );
  }
}
