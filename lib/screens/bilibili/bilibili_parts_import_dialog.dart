import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/bilibili_models.dart';
import '../../theme/app_tokens.dart';

Future<List<int>?> showBilibiliPartsImportDialog(
  BuildContext context, {
  required BilibiliVideoInfo info,
}) => showDialog<List<int>>(
  context: context,
  builder: (_) => BilibiliPartsImportDialog(info: info),
);

/// A bounded, keyboard-aware selector; only the list scrolls on normal screens.
class BilibiliPartsImportDialog extends StatefulWidget {
  const BilibiliPartsImportDialog({super.key, required this.info});

  final BilibiliVideoInfo info;

  @override
  State<BilibiliPartsImportDialog> createState() => _PartsImportState();
}

class _PartsImportState extends State<BilibiliPartsImportDialog> {
  late final Set<int> _selected = widget.info.pages.map((p) => p.page).toSet();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = AppTokens.brandBilibili;
    final colors = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final available =
        media.size.height -
        media.viewInsets.bottom -
        media.padding.vertical -
        32;
    final visible = widget.info.pages
        .where(
          (p) =>
              _query.isEmpty ||
              '${p.page} ${p.part}'.toLowerCase().contains(_query),
        )
        .toList();
    final compact = available < 420;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: SizedBox(
        width: 620,
        height: math.max(0, math.min(680, available)),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, compact ? 4 : 16, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.playlist_add_rounded, color: accent),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '选择导入分P',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (!compact)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.info.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: TextField(
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: '搜索分P标题或序号',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  filled: true,
                  fillColor: colors.onSurface.withValues(alpha: 0.04),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已选 ${_selected.length} / ${widget.info.pages.length} P',
                      style: const TextStyle(color: accent),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (_selected.length == widget.info.pages.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(widget.info.pages.map((p) => p.page));
                      }
                    }),
                    child: Text(
                      _selected.length == widget.info.pages.length
                          ? '取消全选'
                          : '全选',
                      style: const TextStyle(color: accent),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('没有匹配的分P'))
                  : Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final part = visible[index];
                          final selected = _selected.contains(part.page);
                          final minutes = part.duration ~/ 60;
                          final seconds = (part.duration % 60)
                              .toString()
                              .padLeft(2, '0');
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Material(
                              color: selected
                                  ? accent.withValues(alpha: 0.08)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              child: CheckboxListTile(
                                key: ValueKey('import-part-${part.page}'),
                                value: selected,
                                activeColor: accent,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                title: Text(
                                  'P${part.page}  ${part.part}',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text('$minutes:$seconds'),
                                onChanged: (_) => setState(() {
                                  selected
                                      ? _selected.remove(part.page)
                                      : _selected.add(part.page);
                                }),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.all(compact ? 8 : 16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 44),
                      ),
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.pop(context, [
                              for (final p in widget.info.pages)
                                if (_selected.contains(p.page)) p.page,
                            ]),
                      child: Text('导入所选 ${_selected.length} P'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
