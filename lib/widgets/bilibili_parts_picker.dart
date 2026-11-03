import 'package:flutter/material.dart';

import '../models/bilibili_browse_models.dart';
import '../theme/app_tokens.dart';
import '../utils/bilibili_text.dart';
import 'add_to_playlist_button.dart';
import 'playback_queue_add_actions.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Choosing a part returns only its page number. Closing the picker, or
/// tapping the current part, does not restart or change playback.
Future<int?> showBilibiliPartsPicker(
  BuildContext context, {
  required BilibiliVideoDetail detail,
  required int currentPage,
}) {
  final size = MediaQuery.sizeOf(context);
  final content = BilibiliPartsPicker(detail: detail, currentPage: currentPage);
  if (size.width >= 600) {
    return showDialog<int>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: AppTokens.bgBase,
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 520, height: size.height * .72, child: content),
      ),
    );
  }
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppTokens.bgBase,
    clipBehavior: Clip.antiAlias,
    builder: (_) => SizedBox(height: size.height * .72, child: content),
  );
}

class BilibiliPartsPicker extends StatefulWidget {
  const BilibiliPartsPicker({
    super.key,
    required this.detail,
    required this.currentPage,
  });

  final BilibiliVideoDetail detail;
  final int currentPage;

  @override
  State<BilibiliPartsPicker> createState() => _BilibiliPartsPickerState();
}

class _BilibiliPartsPickerState extends State<BilibiliPartsPicker> {
  ScrollController? _scroll;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = widget.detail;
    final scaler = MediaQuery.textScalerOf(context);
    final rowHeight = (scaler.scale(14) * 1.35 * 2 + 24).clamp(
      68.0,
      double.infinity,
    );
    final currentIndex = detail.parts.indexWhere(
      (part) => part.page == widget.currentPage,
    );
    _scroll ??= ScrollController(
      initialScrollOffset: (currentIndex < 0 ? 0 : currentIndex) * rowHeight,
    );
    return Column(
      key: const ValueKey('bilibili-parts-picker'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选集 · ${detail.parts.length} P',
                  style: const TextStyle(
                    color: AppTokens.text1,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close,
                    color: AppTokens.text2,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    detail.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTokens.text3,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AddToPlaylistButton(
                  key: const ValueKey('bilibili-parts-add-all'),
                  onAdd: (progress) => addBilibiliVideoToQueue(
                    context,
                    detail.bvid,
                    progress: progress,
                  ),
                  label: '全部加入',
                  tooltip: '全部分P加入播放列表',
                  height: 32,
                  iconSize: 17,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1, color: AppTokens.text4),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemExtent: rowHeight,
            itemCount: detail.parts.length,
            itemBuilder: (context, index) {
              final part = detail.parts[index];
              final selected = part.page == widget.currentPage;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: Material(
                  color: selected
                      ? AppTokens.brandBilibili.withValues(alpha: .10)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: ValueKey('bilibili-part-${part.page}'),
                    onTap: () =>
                        Navigator.of(context).pop(selected ? null : part.page),
                    child: Semantics(
                      selected: selected,
                      label: selected
                          ? '正在播放 P${part.page}'
                          : '播放 P${part.page}',
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            SizedBox(
                              width:
                                  scaler.scale(12) *
                                  ('P${detail.parts.length}'.length * .65 + 1),
                              child: Text(
                                'P${part.page}',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: selected
                                      ? AppTokens.brandBilibili
                                      : AppTokens.text3,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                part.title.isEmpty
                                    ? '第 ${part.page} P'
                                    : part.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.35,
                                  color: selected
                                      ? AppTokens.brandBilibili
                                      : AppTokens.text1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            if (selected)
                              const Icon(
                                Icons.equalizer_rounded,
                                color: AppTokens.brandBilibili,
                                size: 18,
                              )
                            else if (part.durationSeconds > 0)
                              Text(
                                formatBilibiliDuration(part.durationSeconds),
                                style: const TextStyle(
                                  color: AppTokens.text3,
                                  fontSize: 11,
                                ),
                              ),
                            const SizedBox(width: 6),
                            AddToPlaylistButton(
                              key: ValueKey('bilibili-part-add-${part.page}'),
                              onAdd: (progress) => addBilibiliVideoToQueue(
                                context,
                                detail.bvid,
                                page: part.page,
                                progress: progress,
                              ),
                              iconOnly: true,
                              tooltip: 'P${part.page} · 加入播放列表',
                              height: 36,
                              iconSize: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(height: MediaQuery.paddingOf(context).bottom),
      ],
    );
  }
}
