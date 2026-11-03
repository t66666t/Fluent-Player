import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Rebuild a reading block only when its own highlighted cues change.
class SubtitleActiveRangeBuilder extends StatefulWidget {
  const SubtitleActiveRangeBuilder({
    super.key,
    required this.valueListenable,
    required this.startIndex,
    required this.endIndex,
    required this.builder,
    this.contentKey,
    this.child,
  });

  final ValueListenable<List<int>> valueListenable;
  final int startIndex;
  final int endIndex;
  final ValueWidgetBuilder<List<int>> builder;

  /// Stable presentation and text identity. Unchanged streamed prefixes keep
  /// their rendered subtree even when the indexed list updates its delegate.
  final Object? contentKey;
  final Widget? child;

  @override
  State<SubtitleActiveRangeBuilder> createState() =>
      _SubtitleActiveRangeBuilderState();
}

class _SubtitleActiveRangeBuilderState
    extends State<SubtitleActiveRangeBuilder> {
  late List<int> _indices;
  Widget? _content;

  List<int> _select() => [
    for (final index in widget.valueListenable.value)
      if (index >= widget.startIndex && index < widget.endIndex) index,
  ];

  @override
  void initState() {
    super.initState();
    _indices = _select();
    widget.valueListenable.addListener(_handleChange);
  }

  void _handleChange() {
    final next = _select();
    if (listEquals(next, _indices)) return;
    setState(() {
      _indices = next;
      _content = null;
    });
  }

  @override
  void didUpdateWidget(SubtitleActiveRangeBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueListenable != widget.valueListenable) {
      oldWidget.valueListenable.removeListener(_handleChange);
      widget.valueListenable.addListener(_handleChange);
    }
    final next = _select();
    if (oldWidget.contentKey != widget.contentKey ||
        oldWidget.startIndex != widget.startIndex ||
        oldWidget.endIndex != widget.endIndex ||
        oldWidget.child != widget.child ||
        !listEquals(_indices, next)) {
      _content = null;
    }
    _indices = next;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _content = null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.contentKey == null) {
      return widget.builder(context, _indices, widget.child);
    }
    return _content ??= widget.builder(context, _indices, widget.child);
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_handleChange);
    super.dispose();
  }
}
