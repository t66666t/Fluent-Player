import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'folder_transfer_models.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class FolderTransferCard extends StatelessWidget {
  const FolderTransferCard({
    super.key,
    required this.task,
    this.busy = false,
    this.onAccept,
    this.onReject,
    this.onCancel,
    this.onRetry,
    this.onDismiss,
  });

  final FolderTransferTask task;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  bool get _needsAcceptance =>
      task.incoming &&
      !task.accepted &&
      (task.phase == FolderTransferPhase.offered ||
          task.phase == FolderTransferPhase.waiting);

  @override
  Widget build(BuildContext context) {
    final transferring = task.phase == FolderTransferPhase.transferring;
    final stageProgress = task.stageProgress?.clamp(0.0, 1.0);
    final showStageProgress =
        !transferring &&
        stageProgress != null &&
        const [
          FolderTransferPhase.preparing,
          FolderTransferPhase.verifying,
          FolderTransferPhase.importing,
          FolderTransferPhase.linking,
        ].contains(task.phase);
    final detailStyle = const TextStyle(
      fontSize: 12,
      color: AppTokens.text2,
      height: 1.5,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 10, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 12),
                child: Icon(
                  task.incoming
                      ? Icons.folder_copy_outlined
                      : Icons.drive_folder_upload_outlined,
                  size: 22,
                  color: AppTokens.text2,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.folderName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppTokens.text1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${task.incoming ? '来自' : '发送至'} ${task.peerName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: detailStyle,
                    ),
                  ],
                ),
              ),
              if (!_needsAcceptance)
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: task.canCancel ? '取消传输' : '移除记录',
                    visualDensity: VisualDensity.compact,
                    onPressed: busy
                        ? null
                        : task.canCancel
                        ? onCancel
                        : onDismiss,
                    icon: const Icon(Icons.close, size: 18),
                    color: AppTokens.text3,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (_needsAcceptance) ...[
            Text(
              [
                if (task.mediaCount > 0) '${task.mediaCount} 个媒体文件',
                if (task.estimatedBytes > 0)
                  '约 ${formatFolderTransferBytes(task.estimatedBytes)}',
              ].join(' · '),
              style: detailStyle,
            ),
            const SizedBox(height: 5),
            const Text(
              '接收后加入媒体库，内容与观看进度持续同步。',
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: AppTokens.text2,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                children: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: busy ? null : onReject,
                      child: const Text('拒绝'),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: FilledButton(
                      onPressed: busy ? null : onAccept,
                      child: const Text('接收'),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    folderTransferPhaseLabel(task),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: task.phase == FolderTransferPhase.failed
                          ? AppTokens.danger
                          : AppTokens.text2,
                    ),
                  ),
                ),
                if (transferring && task.progress != null)
                  Text(
                    '${((task.progress! * 1000).floor() / 10).toStringAsFixed(1)}%',
                    key: ValueKey('folder-transfer-percent-${task.id}'),
                    style: detailStyle.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                if (showStageProgress)
                  Text('${(stageProgress * 100).round()}%', style: detailStyle),
              ],
            ),
            if ((transferring && task.progress != null) ||
                showStageProgress) ...[
              const SizedBox(height: 9),
              LinearProgressIndicator(
                key: ValueKey('folder-transfer-progress-${task.id}'),
                value: transferring ? task.progress : stageProgress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
                color: AppTokens.accent,
                backgroundColor: AppTokens.lineSubtle,
              ),
            ],
            if (transferring) ...[
              const SizedBox(height: 8),
              Text(
                '${formatFolderTransferBytes(task.completedBytes)} / ${task.totalBytes > 0 ? formatFolderTransferBytes(task.totalBytes) : '等待文件信息'}',
                key: ValueKey('folder-transfer-bytes-${task.id}'),
                style: detailStyle,
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (task.bytesPerSecond > 0)
                    '${formatFolderTransferBytes(task.bytesPerSecond.round())}/s',
                  if (task.remaining != null)
                    '剩余${formatFolderTransferRemaining(task.remaining!)}',
                  if (task.bytesPerSecond <= 0) '正在连接设备…',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: detailStyle.copyWith(color: AppTokens.text3),
              ),
            ],
            if (task.canRetry && task.error?.isNotEmpty == true) ...[
              const SizedBox(height: 4),
              Text(
                task.error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: detailStyle.copyWith(color: AppTokens.text2),
              ),
            ],
            if (task.canRetry)
              Align(
                alignment: Alignment.centerRight,
                child: DesktopButtonClickRegion(
                  child: TextButton.icon(
                    onPressed: busy ? null : onRetry,
                    icon: Icon(
                      task.phase == FolderTransferPhase.paused
                          ? Icons.play_arrow_outlined
                          : Icons.refresh,
                      size: 17,
                    ),
                    label: Text(
                      task.phase == FolderTransferPhase.paused ? '继续' : '重试',
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

String folderTransferPhaseLabel(FolderTransferTask task) =>
    switch (task.phase) {
      FolderTransferPhase.waiting => '等待设备响应',
      FolderTransferPhase.offered => '等待对方接收',
      FolderTransferPhase.preparing => '正在准备文件…',
      FolderTransferPhase.transferring => task.incoming ? '正在接收' : '正在发送',
      FolderTransferPhase.verifying => '正在校验文件…',
      FolderTransferPhase.importing => '正在加入媒体库…',
      FolderTransferPhase.linking => '正在完成同步关联…',
      FolderTransferPhase.paused => '传输已暂停',
      FolderTransferPhase.needsAttention => '需要处理',
      FolderTransferPhase.completed =>
        task.incoming ? '已接收 · 自动同步已开启' : '已发送 · 自动同步已开启',
      FolderTransferPhase.cancelled => '已取消',
      FolderTransferPhase.failed => '传输未完成',
    };

/// Decimal units: 1 MB = 1,000,000 bytes. Logs keep the raw byte count.
String formatFolderTransferBytes(int bytes) {
  if (bytes < 1000) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var amount = bytes / 1000;
  var index = 0;
  while (amount >= 1000 && index < units.length - 1) {
    amount /= 1000;
    index++;
  }
  return '${amount.toStringAsFixed(amount >= 100 ? 0 : 1)} ${units[index]}';
}

String formatFolderTransferRemaining(Duration remaining) {
  if (remaining.inSeconds < 60) return '${remaining.inSeconds} 秒';
  if (remaining.inMinutes < 60) {
    return '${remaining.inMinutes} 分 ${remaining.inSeconds % 60} 秒';
  }
  return '${remaining.inHours} 小时 ${remaining.inMinutes % 60} 分钟';
}
