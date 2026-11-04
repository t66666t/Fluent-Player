import 'package:flutter/material.dart';

import '../services/media_materialization_service.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class MediaMaterializationProgressCard extends StatelessWidget {
  final MediaMaterializationProgress progress;
  final String? error;
  final VoidCallback? onCancel;
  final EdgeInsetsGeometry padding;

  const MediaMaterializationProgressCard({
    super.key,
    required this.progress,
    this.error,
    this.onCancel,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    final failed = error?.trim().isNotEmpty == true;
    final color = failed
        ? Colors.redAccent
        : progress.stage == MediaMaterializationStage.completed
        ? const Color(0xFF58D68D)
        : const Color(0xFF5B9CFF);
    final known = progress.totalBytes != null && progress.totalBytes! > 0;
    final completed = progress.stage == MediaMaterializationStage.completed;
    final value = known || completed
        ? progress.progress.clamp(0.0, 1.0).toDouble()
        : null;
    final details = _details(progress);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xFF252930),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                failed
                    ? Icons.error_outline_rounded
                    : Icons.downloading_rounded,
                size: 19,
                color: color,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  failed ? '素材下载失败' : progress.message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                value == null ? '大小未知' : '${(value * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (onCancel != null) ...[
                const SizedBox(width: 4),
                DesktopButtonClickRegion(
                  child: IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '取消下载',
                    onPressed: onCancel,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: Colors.black26,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              details,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
          if (failed) ...[
            const SizedBox(height: 6),
            SelectableText(
              error!.trim(),
              maxLines: 3,
              style: const TextStyle(color: Colors.redAccent, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  String _details(MediaMaterializationProgress value) {
    if (value.stage != MediaMaterializationStage.downloadingVideo &&
        value.stage != MediaMaterializationStage.downloadingAudio) {
      return '';
    }
    final transferred = value.totalBytes == null
        ? _formatBytes(value.receivedBytes)
        : '${_formatBytes(value.receivedBytes)} / '
              '${_formatBytes(value.totalBytes!)}';
    final speed = value.bytesPerSecond > 0
        ? '  ·  ${_formatBytes(value.bytesPerSecond.round())}/s'
        : '';
    final eta = value.remaining == null
        ? ''
        : '  ·  剩余约 ${_formatDuration(value.remaining!)}';
    return '$transferred$speed$eta';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}时${duration.inMinutes.remainder(60)}分';
    }
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}分${duration.inSeconds.remainder(60)}秒';
    }
    return '${duration.inSeconds}秒';
  }
}
