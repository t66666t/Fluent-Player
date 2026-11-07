import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A flat list with stable children and separators shared by each visual row.
class MediaLibrarySettingsList extends StatefulWidget {
  const MediaLibrarySettingsList({
    super.key,
    required this.items,
    this.columns = 1,
  }) : assert(columns == 1 || columns == 2);

  final List<Widget> items;
  final int columns;

  @override
  State<MediaLibrarySettingsList> createState() =>
      _MediaLibrarySettingsListState();
}

class _MediaLibrarySettingsListState extends State<MediaLibrarySettingsList> {
  final _wrap = GlobalKey();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Material(
      color: const Color(0xFF232425),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        foregroundPainter: _SettingsSeparators(_wrap, widget.columns),
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Wrap(
            key: _wrap,
            textDirection: Directionality.of(context),
            children: [
              for (var i = 0; i < widget.items.length; i++)
                SizedBox(
                  key: widget.items[i].key == null
                      ? ValueKey(i)
                      : ValueKey(widget.items[i].key),
                  width:
                      widget.columns == 2 &&
                          widget.items.length.isOdd &&
                          i == widget.items.length - 1
                      ? constraints.maxWidth
                      : constraints.maxWidth / widget.columns,
                  child: FocusTraversalOrder(
                    order: NumericFocusOrder(i.toDouble()),
                    child: Semantics(
                      sortKey: OrdinalSortKey(i.toDouble()),
                      child: widget.items[i],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Painting follows Wrap's completed layout, including changes inside a child.
/// It never measures widgets or changes their state during layout or painting.
class _SettingsSeparators extends CustomPainter {
  const _SettingsSeparators(this.wrapKey, this.columns);

  final GlobalKey wrapKey;
  final int columns;

  @override
  void paint(Canvas canvas, Size size) {
    final wrap = wrapKey.currentContext?.findRenderObject();
    if (wrap is! RenderWrap || !wrap.hasSize) return;
    final bottoms = <double, double>{};
    final counts = <double, int>{};
    for (
      var child = wrap.firstChild;
      child != null;
      child = wrap.childAfter(child)
    ) {
      final offset = (child.parentData! as WrapParentData).offset;
      final bottom = offset.dy + child.size.height;
      if (bottom > (bottoms[offset.dy] ?? 0)) {
        bottoms[offset.dy] = bottom;
      }
      counts.update(offset.dy, (count) => count + 1, ifAbsent: () => 1);
    }
    final rows = bottoms.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final line = Paint()
      ..color = const Color(0xFF303234)
      ..strokeWidth = 1
      ..isAntiAlias = false;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (columns == 2 && counts[row.key]! > 1) {
        final x = size.width / 2 - .5;
        canvas.drawLine(Offset(x, row.key), Offset(x, row.value), line);
      }
      if (i < rows.length - 1) {
        final y = row.value - .5;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SettingsSeparators oldDelegate) => true;
}
