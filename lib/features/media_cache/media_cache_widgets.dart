import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/storage_audit_models.dart';
import '../../theme/app_tokens.dart';
import '../../utils/app_toast.dart';
import 'media_cache_models.dart';
import 'media_cache_service.dart';
import 'media_cache_card_state.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

const cacheQuietBlue = Color(0xFF8AA7C5);

class MediaCacheCountBadge extends StatelessWidget {
  const MediaCacheCountBadge({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final service = MediaCacheService.instance;
    if (service == null) return child;
    return ListenableBuilder(
      listenable: service,
      child: child,
      builder: (_, child) => Stack(
        clipBehavior: Clip.none,
        children: [
          child!,
          if (service.runningCount > 0)
            Positioned(
              top: 0,
              right: 0,
              child: IgnorePointer(
                child: Container(
                  constraints: const BoxConstraints(
                    minWidth: 18,
                    minHeight: 16,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF35414D),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${service.runningCount}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.3,
                      color: Color(0xFFC1CEDB),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> cacheUiAction(Future<void> Function() action) async {
  try {
    await action();
  } catch (_) {
    AppToast.show('操作未完成，请检查网络或存储后重试', type: AppToastType.error);
  }
}

Future<void> showMediaCacheSettings(
  BuildContext context, {
  bool networkOnly = false,
}) async {
  final service = MediaCacheService.instance;
  if (service == null) return;
  await service.initialize();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppTokens.bgRaised,
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) =>
        MediaCacheSettings(service: service, networkOnly: networkOnly),
  );
}

class MediaCacheSettings extends StatefulWidget {
  const MediaCacheSettings({
    super.key,
    required this.service,
    this.networkOnly = false,
  });
  final MediaCacheService service;
  final bool networkOnly;
  @override
  State<MediaCacheSettings> createState() => _MediaCacheSettingsState();
}

class _MediaCacheSettingsState extends State<MediaCacheSettings> {
  String? _error;
  Future<void> _change(VoidCallback update) async {
    setState(update);
    try {
      await widget.service.updatePreferences();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) setState(() => _error = '设置未能保存，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = widget.service.preferences;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .88,
        maxWidth: 640,
      ),
      child: SafeArea(
        top: false,
        minimum: EdgeInsets.only(
          bottom: MediaQuery.systemGestureInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.networkOnly ? '缓存传输设置' : '缓存设置',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: IconButton(
                      tooltip: '关闭',
                      style: IconButton.styleFrom(
                        minimumSize: const Size(32, 32),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: AppTokens.text2,
                      ),
                    ),
                  ),
                ],
              ),
              if (!widget.networkOnly) ...[
                const SizedBox(height: 8),
                const Text(
                  '批量缓存画质上限',
                  style: TextStyle(
                    color: AppTokens.text2,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                for (final provider in const {
                  'bilibili': '哔哩哔哩',
                  'baidu': '百度网盘',
                  'quark': '夸克网盘',
                  'uc': 'UC网盘',
                  'aliyun': '阿里云盘',
                }.entries)
                  _setting(
                    provider.value,
                    DesktopButtonClickRegion(
                      child: DropdownButton<int>(
                        value: prefs.limits[provider.key] ?? 0,
                        isDense: true,
                        borderRadius: BorderRadius.circular(12),
                        dropdownColor: AppTokens.bgCard,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTokens.text1,
                          fontSize: 13,
                        ),
                        icon: const Icon(Icons.expand_more_rounded, size: 18),
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final height in [
                            // Preserve imported/custom limits as valid choices.
                            if (prefs.limits[provider.key] case final int value)
                              if (![
                                0,
                                4320,
                                2160,
                                1440,
                                1080,
                                720,
                                480,
                                360,
                              ].contains(value))
                                value,
                            0,
                            4320,
                            2160,
                            1440,
                            1080,
                            720,
                            480,
                            360,
                          ])
                            DropdownMenuItem(
                              value: height,
                              child: Text(
                                height == 0
                                    ? provider.key == 'bilibili'
                                          ? '最高可用'
                                          : '原画（最高）'
                                    : '${height}P',
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            unawaited(
                              _change(
                                () => prefs.limits[provider.key] = value == 0
                                    ? null
                                    : value,
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ),
                const Text(
                  '音频保留原音质。在播放器中单独选择画质下载时，以你的选择为准。',
                  style: TextStyle(color: AppTokens.text3, fontSize: 12),
                ),
                const SizedBox(height: 12),
                _setting(
                  '自动清理较低画质',
                  Semantics(
                    label: '自动清理较低画质',
                    child: SizedBox(
                      width: 38,
                      height: 24,
                      child: Transform.scale(
                        scale: .65,
                        alignment: Alignment.centerRight,
                        child: Switch(
                          value: prefs.pruneLower,
                          onChanged: (v) =>
                              unawaited(_change(() => prefs.pruneLower = v)),
                          activeThumbColor: Colors.blueAccent,
                          activeTrackColor: Colors.blueAccent.withValues(
                            alpha: .25,
                          ),
                          inactiveThumbColor: AppTokens.text2,
                          inactiveTrackColor: Colors.white.withValues(
                            alpha: .05,
                          ),
                          trackOutlineColor: const WidgetStatePropertyAll(
                            Colors.white10,
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ),
                ),
                const Text(
                  '更高画质缓存完成后清理，使用中的文件会等待播放或处理结束。',
                  style: TextStyle(
                    color: AppTokens.text3,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const Divider(height: 24, color: AppTokens.lineSubtle),
              ],
              const Text(
                '传输并发',
                style: TextStyle(
                  color: AppTokens.text2,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              _number(
                '同时缓存任务',
                prefs.parallelTasks,
                1,
                8,
                (v) => unawaited(_change(() => prefs.parallelTasks = v)),
              ),
              _number(
                '每任务连接上限',
                prefs.connectionsPerTask,
                1,
                4,
                (v) => unawaited(_change(() => prefs.connectionsPerTask = v)),
              ),
              _number(
                '全局连接预算',
                prefs.connectionBudget,
                1,
                16,
                (v) => unawaited(_change(() => prefs.connectionBudget = v)),
              ),
              const Text(
                '网络方式沿用网络设置中的 B 站与网盘配置。网络波动自动重试，并保留断点。',
                style: TextStyle(color: AppTokens.text3, fontSize: 12),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _number(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> change,
  ) => _setting(
    label,
    DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '减少$label',
              style: IconButton.styleFrom(
                minimumSize: const Size(28, 28),
                maximumSize: const Size(28, 28),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: AppTokens.text2,
              ),
              onPressed: value > min ? () => change(value - 1) : null,
              icon: const Icon(Icons.remove, size: 14),
            ),
          ),
          SizedBox(
            width: 20,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppTokens.text1),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: '增加$label',
              style: IconButton.styleFrom(
                minimumSize: const Size(28, 28),
                maximumSize: const Size(28, 28),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: AppTokens.text2,
              ),
              onPressed: value < max ? () => change(value + 1) : null,
              icon: const Icon(Icons.add, size: 14),
            ),
          ),
        ],
      ),
    ),
  );
  Widget _setting(String label, Widget control) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 270 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 13)),
                    Align(alignment: Alignment.centerRight, child: control),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Text(label, style: const TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 16),
                    control,
                  ],
                ),
        ),
      );
    },
  );
}

/// The trailing action is deliberately independent of a quality row's tap.
/// Downloading and deleting leave the menu open and do not switch playback.
class CacheQualityAction extends StatelessWidget {
  const CacheQualityAction({
    super.key,
    required this.source,
    required this.qualityId,
    this.available = true,
    this.compact = false,
  });
  final CacheSource source;
  final String qualityId;
  final bool available, compact;
  @override
  Widget build(BuildContext context) {
    final service = MediaCacheService.instance;
    if (service == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final variants = service
            .variantsFor(source.key)
            .where((v) => v.quality.id == qualityId)
            .toList();
        final task = service.taskFor(source.key, qualityId: qualityId);
        final pendingDelete = service.variants.any(
          (v) =>
              v.source.key == source.key &&
              v.quality.id == qualityId &&
              v.pendingDelete,
        );
        if (variants.isNotEmpty) {
          final complete = variants.any((variant) => variant.completeMedia);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: complete
                    ? '此画质已缓存'
                    : '${variants.first.contentLabel}，完整离线播放仍需补齐其余轨道',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_done_rounded,
                      size: 18,
                      color: cacheQuietBlue,
                    ),
                    if (!complete)
                      Text(
                        variants.first.content == CacheContent.audio
                            ? '音轨'
                            : '视频轨',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppTokens.text3,
                        ),
                      ),
                  ],
                ),
              ),
              if (!complete)
                DesktopButtonClickRegion(
                  child: IconButton(
                    tooltip: task == null
                        ? '补齐此画质缓存'
                        : '${task.state.primaryActionLabel}缓存此画质',
                    onPressed: task == null && !available
                        ? null
                        : () => unawaited(
                            cacheUiAction(() async {
                              if (task == null) {
                                await service.enqueue(
                                  source,
                                  qualityId: qualityId,
                                );
                              } else if (task.state.canPause) {
                                await service.pause(task.id);
                              } else {
                                await service.resume(task.id);
                              }
                            }),
                          ),
                    icon: Icon(
                      task?.state.canPause == true
                          ? Icons.pause_rounded
                          : task?.state.canRetry == true
                          ? Icons.refresh_rounded
                          : Icons.download_outlined,
                      size: 18,
                      color: cacheQuietBlue,
                    ),
                  ),
                ),
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '删除此画质缓存',
                  onPressed: () => unawaited(
                    cacheUiAction(() async {
                      for (final v in variants) {
                        await service.deleteVariant(v.id);
                      }
                    }),
                  ),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: AppTokens.text2,
                  ),
                ),
              ),
            ],
          );
        }
        if (pendingDelete) {
          return const Tooltip(
            message: '使用结束后删除',
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Icon(Icons.hourglass_empty, size: 18),
            ),
          );
        }
        return DesktopButtonClickRegion(
          child: IconButton(
            tooltip: task == null
                ? '缓存此画质'
                : '${task.state.primaryActionLabel}缓存此画质',
            onPressed: task == null && !available
                ? null
                : () => unawaited(
                    cacheUiAction(() async {
                      if (task == null) {
                        await service.enqueue(source, qualityId: qualityId);
                      } else if (task.state.canPause) {
                        await service.pause(task.id);
                      } else {
                        await service.resume(task.id);
                      }
                    }),
                  ),
            icon: Icon(
              task == null
                  ? Icons.download_outlined
                  : task.state.canPause
                  ? Icons.pause_rounded
                  : task.state.canRetry
                  ? Icons.refresh_rounded
                  : Icons.play_arrow_rounded,
              color: available || task != null
                  ? cacheQuietBlue
                  : AppTokens.text3,
              size: 20,
            ),
          ),
        );
      },
    );
  }
}

class CacheCardProgress extends StatelessWidget {
  const CacheCardProgress({
    super.key,
    required this.source,
    required this.onOpen,
  });
  final CacheSource? source;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final service = MediaCacheService.instance;
    if (service == null || source == null) return const SizedBox.shrink();
    return ValueListenableBuilder<MediaCacheCardState>(
      valueListenable: service.cardStateFor(source!),
      builder: (context, state, _) {
        if (!state.active) return const SizedBox.shrink();
        final progress = state.progress;
        return Semantics(
          button: true,
          label: '打开此媒体的缓存任务',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: SizedBox(
              height: 12,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  minHeight: 3,
                  value: progress,
                  color: AppTokens.accent,
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String cacheSpeed(double value) => '${formatStorageSize(value.round())}/s';
String cacheDuration(Duration duration) {
  if (duration.inHours > 0) {
    return '${duration.inHours} 小时 ${duration.inMinutes % 60} 分钟';
  }
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes} 分钟 ${duration.inSeconds % 60} 秒';
  }
  return '${duration.inSeconds} 秒';
}
