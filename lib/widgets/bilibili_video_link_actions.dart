import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/bilibili/bilibili_video_links.dart';
import '../theme/app_tokens.dart';
import '../utils/app_toast.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Shared by the portrait details and the landscape sidebar. No fixed height:
/// actions and their labels can wrap in a narrow panel or with large text.
class BilibiliVideoLinkActions extends StatefulWidget {
  const BilibiliVideoLinkActions({
    super.key,
    required this.bvid,
    this.page = 1,
    this.showIdentity = true,
    this.showActions = true,
  });

  final String bvid;
  final int page;
  final bool showIdentity;
  final bool showActions;

  @override
  State<BilibiliVideoLinkActions> createState() =>
      _BilibiliVideoLinkActionsState();
}

class _BilibiliVideoLinkActionsState extends State<BilibiliVideoLinkActions> {
  bool _copying = false;
  bool _opening = false;
  String? _feedback;
  Timer? _feedbackTimer;
  AppToastHandle? _notice;
  int _generation = 0;

  @override
  void didUpdateWidget(covariant BilibiliVideoLinkActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bvid != widget.bvid || oldWidget.page != widget.page) {
      _generation++;
      _copying = false;
      _opening = false;
      _feedback = null;
      _feedbackTimer?.cancel();
      _notice?.dismiss(immediate: true);
    }
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    _notice?.dismiss(immediate: true);
    super.dispose();
  }

  void _report(String message, {bool error = false}) {
    _notice = AppToast.show(
      message,
      type: error ? AppToastType.error : AppToastType.info,
    );
  }

  Future<void> _copy(String text, String success) async {
    if (_copying) return;
    final generation = _generation;
    setState(() {
      _copying = true;
      _feedback = null;
      _feedbackTimer?.cancel();
      _notice?.dismiss(immediate: true);
    });
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (_isCurrent(generation)) {
        setState(() => _feedback = success);
        _feedbackTimer = Timer(const Duration(seconds: 2), () {
          if (_isCurrent(generation)) setState(() => _feedback = null);
        });
      }
    } catch (_) {
      if (_isCurrent(generation)) {
        setState(() => _report('复制失败，请重试', error: true));
      }
    } finally {
      if (_isCurrent(generation)) setState(() => _copying = false);
    }
  }

  Future<void> _open(BilibiliVideoLinks links) async {
    if (_opening) return;
    final generation = _generation;
    setState(() {
      _opening = true;
      _feedback = null;
      _feedbackTimer?.cancel();
      _notice?.dismiss(immediate: true);
    });
    final result = await links.open(isCurrent: () => _isCurrent(generation));
    if (!_isCurrent(generation)) return;
    setState(() {
      _opening = false;
      switch (result) {
        case BilibiliVideoOpenResult.app:
        case BilibiliVideoOpenResult.cancelled:
          break;
        case BilibiliVideoOpenResult.browser:
          break;
        case BilibiliVideoOpenResult.failed:
          _report('无法打开视频，请复制链接后手动打开', error: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final links = BilibiliVideoLinks.tryParse(widget.bvid, page: widget.page);
    if (links == null) return const SizedBox.shrink();
    return Wrap(
      key: const ValueKey('bilibili-panel-video-links'),
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (widget.showIdentity) ...[
          Tooltip(
            message: '复制 BV 号',
            child: DesktopButtonClickRegion(
              child: TextButton.icon(
                key: const ValueKey('bilibili-panel-bvid'),
                style: TextButton.styleFrom(
                  foregroundColor: AppTokens.text3,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 32),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _copying ? null : () => _copy(links.bvid, 'BV 号已复制'),
                icon: Icon(
                  _feedback == 'BV 号已复制' ? Icons.check : Icons.copy_outlined,
                  size: 13,
                ),
                label: Text(links.bvid, style: const TextStyle(fontSize: 12)),
              ),
            ),
          ),
          if (links.page > 1)
            Text(
              'P${links.page}',
              style: const TextStyle(color: AppTokens.text3, fontSize: 12),
            ),
        ],
        if (widget.showActions) ...[
          Semantics(
            liveRegion: true,
            child: DesktopButtonClickRegion(
              child: IconButton(
                key: const ValueKey('bilibili-panel-copy-link'),
                tooltip: _feedback == '链接已复制' ? '已复制' : '复制链接',
                onPressed: _copying
                    ? null
                    : () => _copy(links.web.toString(), '链接已复制'),
                icon: Icon(_feedback == '链接已复制' ? Icons.check : Icons.link),
                iconSize: 18,
                color: AppTokens.text2,
              ),
            ),
          ),
          DesktopButtonClickRegion(
            child: IconButton(
              key: const ValueKey('bilibili-panel-open-externally'),
              tooltip: '在应用内打开官方播放器',
              onPressed: _opening ? null : () => _open(links),
              icon: const Icon(Icons.play_circle_outline),
              iconSize: 18,
              color: AppTokens.text2,
            ),
          ),
        ],
      ],
    );
  }
}
