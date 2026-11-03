import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/subtitle_copy_format.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Compact copy-format editor parked next to the text-selection toolbar.
///
/// Placement is handled here so the sidebar only supplies an anchor; the
/// card flips around the selection and is clamped into the safe area on
/// phones, tablets, and desktops.
class SubtitleCopyFormatPopover extends StatelessWidget {
  const SubtitleCopyFormatPopover({
    super.key,
    required this.anchor,
    required this.format,
    required this.previewText,
    required this.showBilingualOptions,
    required this.onFormatChanged,
    this.onCopy,
    required this.onReset,
  });

  final Offset anchor;
  final SubtitleCopyFormat format;
  final String previewText;
  final bool showBilingualOptions;
  final ValueChanged<SubtitleCopyFormat> onFormatChanged;
  final VoidCallback? onCopy;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) => _SubtitleCopyFormatViewport(
    anchor: anchor,
    child: _SubtitleCopyFormatCard(
      format: format,
      previewText: previewText,
      showBilingualOptions: showBilingualOptions,
      onFormatChanged: onFormatChanged,
      onCopy: onCopy,
      onReset: onReset,
    ),
  );
}

class _SubtitleCopyFormatViewport extends StatelessWidget {
  const _SubtitleCopyFormatViewport({
    required this.anchor,
    required this.child,
  });

  final Offset anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomSingleChildLayout(
    delegate: _SubtitleCopyFormatPopoverDelegate(
      anchor: anchor,
      padding: MediaQuery.paddingOf(context) + MediaQuery.viewInsetsOf(context),
    ),
    child: child,
  );
}

class _SubtitleCopyFormatPopoverDelegate extends SingleChildLayoutDelegate {
  const _SubtitleCopyFormatPopoverDelegate({
    required this.anchor,
    required this.padding,
  });

  final Offset anchor;
  final EdgeInsets padding;

  static const double _margin = 8;
  static const double _maxWidth = 300;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double horizontalRoom =
        constraints.maxWidth - padding.horizontal - _margin * 2;
    final double verticalRoom =
        constraints.maxHeight - padding.vertical - _margin * 2;
    return BoxConstraints(
      maxWidth: math.max(160, math.min(_maxWidth, horizontalRoom)),
      maxHeight: math.max(80, verticalRoom),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double minX = padding.left + _margin;
    final double minY = padding.top + _margin;
    final double maxX = size.width - padding.right - _margin - childSize.width;
    final double maxY =
        size.height - padding.bottom - _margin - childSize.height;

    // Prefer just below the anchor (selection / toolbar). Flip above, then
    // slide horizontally, so a right-click near the screen edge still fits.
    double x = anchor.dx;
    double y = anchor.dy + _margin;
    if (y + childSize.height > size.height - padding.bottom - _margin) {
      y = anchor.dy - childSize.height - _margin;
    }
    if (x + childSize.width > size.width - padding.right - _margin) {
      x = anchor.dx - childSize.width;
    }

    final double clampedX = maxX < minX ? minX : x.clamp(minX, maxX);
    final double clampedY = maxY < minY ? minY : y.clamp(minY, maxY);
    return Offset(clampedX, clampedY);
  }

  @override
  bool shouldRelayout(
    covariant _SubtitleCopyFormatPopoverDelegate oldDelegate,
  ) {
    return oldDelegate.anchor != anchor || oldDelegate.padding != padding;
  }
}

class _SubtitleCopyFormatCard extends StatefulWidget {
  const _SubtitleCopyFormatCard({
    required this.format,
    required this.previewText,
    required this.showBilingualOptions,
    required this.onFormatChanged,
    this.onCopy,
    required this.onReset,
  });

  final SubtitleCopyFormat format;
  final String previewText;
  final bool showBilingualOptions;
  final ValueChanged<SubtitleCopyFormat> onFormatChanged;
  final VoidCallback? onCopy;
  final VoidCallback onReset;

  @override
  State<_SubtitleCopyFormatCard> createState() =>
      _SubtitleCopyFormatCardState();
}

class _SubtitleCopyFormatCardState extends State<_SubtitleCopyFormatCard> {
  late final TextEditingController _customController;
  late final FocusNode _customFocusNode;

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController(
      text: widget.format.customSeparator,
    );
    _customFocusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _SubtitleCopyFormatCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the field in sync with persisted settings unless the user is
    // mid-keystroke, which would otherwise reset the caret on every rebuild.
    if (widget.format.customSeparator != _customController.text &&
        !_customFocusNode.hasFocus) {
      _customController.value = TextEditingValue(
        text: widget.format.customSeparator,
        selection: TextSelection.collapsed(
          offset: widget.format.customSeparator.length,
        ),
      );
    }
  }

  @override
  void dispose() {
    _customController.dispose();
    _customFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final SubtitleCopyFormat format = widget.format;
    return Material(
      color: const Color(0xFF2A2A2A),
      elevation: 10,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 220),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '复制格式',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              _labeledRow(
                label: '条间',
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    _chip(
                      label: '空格',
                      selected: format.cueJoin == SubtitleCopyCueJoin.spaces,
                      onTap: () => widget.onFormatChanged(
                        format.copyWith(cueJoin: SubtitleCopyCueJoin.spaces),
                      ),
                    ),
                    _chip(
                      label: '换行',
                      selected: format.cueJoin == SubtitleCopyCueJoin.newline,
                      onTap: () => widget.onFormatChanged(
                        format.copyWith(cueJoin: SubtitleCopyCueJoin.newline),
                      ),
                    ),
                    _chip(
                      label: '空行',
                      selected: format.cueJoin == SubtitleCopyCueJoin.blankLine,
                      onTap: () => widget.onFormatChanged(
                        format.copyWith(cueJoin: SubtitleCopyCueJoin.blankLine),
                      ),
                    ),
                    _chip(
                      label: '自定义',
                      selected: format.cueJoin == SubtitleCopyCueJoin.custom,
                      onTap: () => widget.onFormatChanged(
                        format.copyWith(cueJoin: SubtitleCopyCueJoin.custom),
                      ),
                    ),
                  ],
                ),
              ),
              if (format.cueJoin == SubtitleCopyCueJoin.spaces) ...[
                const SizedBox(height: 6),
                _spaceCountRow(format),
              ],
              if (format.cueJoin == SubtitleCopyCueJoin.custom) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _customController,
                    focusNode: _customFocusNode,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    cursorColor: Colors.blueAccent,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: r'例如 | 或 \n',
                      hintStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Colors.white12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Colors.white12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        borderSide: const BorderSide(color: Colors.blueAccent),
                      ),
                    ),
                    onChanged: (String value) {
                      widget.onFormatChanged(
                        format.copyWith(
                          cueJoin: SubtitleCopyCueJoin.custom,
                          customSeparator: value,
                        ),
                      );
                    },
                  ),
                ),
              ],
              if (widget.showBilingualOptions) ...[
                const SizedBox(height: 8),
                _labeledRow(
                  label: '双语',
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      _chip(
                        label: '同行',
                        selected:
                            format.bilingualJoin ==
                            SubtitleCopyBilingualJoin.inline,
                        onTap: () => widget.onFormatChanged(
                          format.copyWith(
                            bilingualJoin: SubtitleCopyBilingualJoin.inline,
                          ),
                        ),
                      ),
                      _chip(
                        label: '换行',
                        selected:
                            format.bilingualJoin ==
                            SubtitleCopyBilingualJoin.newline,
                        onTap: () => widget.onFormatChanged(
                          format.copyWith(
                            bilingualJoin: SubtitleCopyBilingualJoin.newline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.previewText.isEmpty ? '无预览' : widget.previewText,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: widget.onReset,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white54,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('重置', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  const Spacer(),
                  if (widget.onCopy != null)
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: widget.onCopy,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.blueAccent,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('复制', style: TextStyle(fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _labeledRow({required String label, required Widget child}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: SizedBox(
            width: 32,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }

  Widget _spaceCountRow(SubtitleCopyFormat format) {
    return Row(
      children: [
        const SizedBox(width: 32),
        _stepButton(
          icon: Icons.remove,
          enabled: format.spaceCount > SubtitleCopyFormat.minSpaceCount,
          onTap: () => widget.onFormatChanged(
            format.copyWith(spaceCount: format.spaceCount - 1),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${format.spaceCount}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ),
        _stepButton(
          icon: Icons.add,
          enabled: format.spaceCount < SubtitleCopyFormat.maxSpaceCount,
          onTap: () => widget.onFormatChanged(
            format.copyWith(spaceCount: format.spaceCount + 1),
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          '个空格',
          style: TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }

  Widget _stepButton({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: 24,
      height: 24,
      child: DesktopButtonClickRegion(
        child: IconButton(
          onPressed: enabled ? onTap : null,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          splashRadius: 14,
          iconSize: 14,
          color: Colors.white70,
          disabledColor: Colors.white24,
          icon: Icon(icon),
        ),
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected
          ? Colors.blueAccent.withValues(alpha: 0.28)
          : Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: selected ? Colors.blueAccent : Colors.white12,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.white70,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}
