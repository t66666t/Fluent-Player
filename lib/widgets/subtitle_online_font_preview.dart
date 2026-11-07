import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/subtitle_font.dart';
import '../services/subtitle_font_preview_service.dart';
import '../utils/subtitle_font_preview.dart';
import 'desktop_button_click_region.dart';

/// Loads a small specimen only after a list row remains near the viewport.
/// A missing preview is never painted with an unrelated system font.
class SubtitleOnlineFontPreview extends StatefulWidget {
  final SubtitleOnlineFont font;
  final SubtitleFontPreviewSample sample;
  final SubtitleFontPreviewService? previewService;
  final String? installedFamily;
  final Future<void> Function()? prepareInstalled;
  final VoidCallback? onOfficialPreview;

  const SubtitleOnlineFontPreview({
    super.key,
    required this.font,
    required this.sample,
    this.previewService,
    this.installedFamily,
    this.prepareInstalled,
    this.onOfficialPreview,
  });

  @override
  State<SubtitleOnlineFontPreview> createState() =>
      _SubtitleOnlineFontPreviewState();
}

class _SubtitleOnlineFontPreviewState extends State<SubtitleOnlineFontPreview> {
  Timer? _delay;
  CancelToken? _cancel;
  String? _family;
  bool _failed = false;
  int _generation = 0;

  bool get _colorEmoji => widget.font.name == 'Noto Color Emoji';

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(SubtitleOnlineFontPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.font.sourceUrl != widget.font.sourceUrl ||
        oldWidget.font.name != widget.font.name ||
        oldWidget.font.directDownload != widget.font.directDownload ||
        !listEquals(oldWidget.font.weights, widget.font.weights) ||
        oldWidget.sample.text != widget.sample.text ||
        oldWidget.installedFamily != widget.installedFamily ||
        oldWidget.previewService != widget.previewService) {
      _schedule();
    }
  }

  void _schedule() {
    final generation = ++_generation;
    _delay?.cancel();
    _cancel?.cancel();
    _family = null;
    _failed = false;
    if (_colorEmoji) return;
    if (!widget.font.directDownload && widget.installedFamily == null) return;
    _delay = Timer(const Duration(milliseconds: 150), () async {
      final cancel = CancelToken();
      _cancel = cancel;
      try {
        final installedFamily = widget.installedFamily;
        final String family;
        if (installedFamily != null) {
          await widget.prepareInstalled?.call();
          family = installedFamily;
        } else {
          family =
              await (widget.previewService ??
                      SubtitleFontPreviewService.instance)
                  .load(widget.font, widget.sample.text, cancel: cancel);
        }
        if (mounted && generation == _generation && !cancel.isCancelled) {
          setState(() => _family = family);
        }
      } catch (_) {
        if (mounted && generation == _generation && !cancel.isCancelled) {
          setState(() => _failed = true);
        }
      }
    });
  }

  @override
  void dispose() {
    ++_generation;
    _delay?.cancel();
    _cancel?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sample = widget.sample;
    final scaler = TextScaler.linear(
      MediaQuery.textScalerOf(context).scale(1).clamp(.9, 1.25).toDouble(),
    );
    final official =
        !widget.font.directDownload && widget.installedFamily == null;
    return Tooltip(
      message: sample.languageLabel,
      child: Semantics(
        label: '${widget.font.name}字体预览，${sample.languageLabel}',
        child: SizedBox(
          key: ValueKey('subtitle-font-preview-${widget.font.name}'),
          height: 20,
          child: ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              child: official
                  ? DesktopButtonClickRegion(
                      child: TextButton(
                        key: ValueKey(
                          'subtitle-font-official-preview-${widget.font.name}',
                        ),
                        onPressed: widget.onOfficialPreview,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 20),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          '官网预览',
                          textScaler: scaler,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    )
                  : _colorEmoji
                  ? Image.asset(
                      'assets/fonts/previews/noto-color-emoji.png',
                      key: const ValueKey('subtitle-color-emoji-preview'),
                      height: 20,
                      fit: BoxFit.contain,
                      semanticLabel: '彩色表情字体样张',
                    )
                  : _family == null
                  ? _status(scaler)
                  : Text(
                      sample.primary,
                      key: ValueKey(
                        'subtitle-font-preview-sample-${widget.font.name}',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: sample.direction,
                      textScaler: scaler,
                      style: TextStyle(
                        fontFamily: _family,
                        fontSize: 14,
                        height: 1.1,
                        color: Colors.white60,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(TextScaler scaler) => Row(
    children: [
      Expanded(
        child: Text(
          _failed ? '预览暂不可用' : '正在加载预览',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textScaler: scaler,
          style: const TextStyle(fontSize: 11, color: Colors.white38),
        ),
      ),
      if (_failed)
        DesktopButtonClickRegion(
          child: TextButton(
            key: ValueKey('subtitle-font-preview-retry-${widget.font.name}'),
            onPressed: () => setState(_schedule),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 20),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '重试',
              textScaler: scaler,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
    ],
  );
}
