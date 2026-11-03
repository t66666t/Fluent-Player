import 'package:flutter/material.dart';
import '../../theme/app_tokens.dart';
import 'podcast_typography.dart';

/// Labels and their geometry stay fixed as selection and episode counts change.
/// Counts remain available to assistive technology without moving the controls.
class PodcastFilterBar extends StatelessWidget {
  const PodcastFilterBar({
    super.key,
    required this.labels,
    required this.counts,
    required this.selected,
    required this.onSelected,
    this.compact = false,
  });

  final bool compact;
  final Map<String, String> labels;
  final Map<String, int> counts;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x09FFFFFF),
          borderRadius: BorderRadius.circular(compact ? 10 : 16),
          border: Border.all(color: const Color(0x06FFFFFF)),
        ),
        child: _layout(
          // Let the rendered font determine each segment's width. A separate
          // TextPainter can disagree with inherited type and loaded CJK fonts.
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: bounds.maxWidth.isFinite
                  ? (bounds.maxWidth - 8).clamp(0.0, double.infinity)
                  : 0,
            ),
            child: _segments(
              children: [
                for (final entry in labels.entries)
                  Semantics(
                    button: true,
                    selected: selected == entry.key,
                    label: '${entry.value}，${counts[entry.key] ?? 0} 集',
                    excludeSemantics: true,
                    onTap: () => onSelected(entry.key),
                    child: AnimatedContainer(
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: selected == entry.key
                            ? const Color(0x19FFFFFF)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(compact ? 8 : 12),
                        border: Border.all(
                          color: selected == entry.key
                              ? const Color(0x0DFFFFFF)
                              : Colors.transparent,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(compact ? 8 : 12),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          key: ValueKey('podcast-filter-${entry.key}'),
                          borderRadius: BorderRadius.circular(compact ? 8 : 12),
                          excludeFromSemantics: true,
                          onTap: () => onSelected(entry.key),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: compact ? 36 : 44,
                              minWidth: compact ? 0 : 52,
                            ),
                            child: Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 5 : 13,
                                vertical: compact ? 7 : 10,
                              ),
                              child: Center(
                                widthFactor: 1,
                                heightFactor: 1,
                                child: Text(
                                  entry.value,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: PodcastType.label.copyWith(
                                    fontSize: 12,
                                    color: selected == entry.key
                                        ? AppTokens.text1
                                        : AppTokens.text2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
  Widget _segments({required List<Widget> children}) => compact
      ? Wrap(alignment: WrapAlignment.spaceBetween, children: children)
      : Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: children,
        );

  Widget _layout({required Widget child}) {
    if (compact) return Padding(padding: const EdgeInsets.all(2), child: child);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(4),
      child: child,
    );
  }
}
