import '../models/subtitle_copy_format.dart';

/// One sidebar cue split into the primary line and optional secondary line.
///
/// [secondary] is empty in 1/2 display modes and when a dual-mode cue has no
/// matched translation. Display concatenation matches the sidebar: one space
/// between the two lines, which is also how a bilingual cue appears in the
/// SelectionArea `plainText`.
class SubtitleCueCopyParts {
  const SubtitleCueCopyParts({required this.primary, required this.secondary});

  static const SubtitleCueCopyParts empty = SubtitleCueCopyParts(
    primary: '',
    secondary: '',
  );

  final String primary;
  final String secondary;

  bool get hasSecondary => secondary.isNotEmpty;
  bool get isEmpty => primary.isEmpty && secondary.isEmpty;
}

/// A selected slice of one cue. First/last cues may be partial.
class SelectedCueSlice {
  const SelectedCueSlice({required this.primary, required this.secondary});

  final String primary;
  final String secondary;

  bool get isEmpty => primary.isEmpty && secondary.isEmpty;
}

/// Rebuilds selected sidebar text using [SubtitleCopyFormat].
///
/// Flutter only gives a flattened `plainText`. Mapping walks the same
/// space-joined display string the sidebar puts into the selection so cue
/// boundaries (and the bilingual space) can be recovered.
class SubtitleCopyFormatter {
  const SubtitleCopyFormatter._();

  /// Display form stored in the sidebar selection cache for one cue.
  static String displayText(SubtitleCueCopyParts parts) {
    if (parts.primary.isEmpty) return parts.secondary;
    if (parts.secondary.isEmpty) return parts.primary;
    return '${parts.primary} ${parts.secondary}';
  }

  /// Canonical space-joined transcript matching SelectionArea output.
  static String joinedDisplayText(List<SubtitleCueCopyParts> cues) {
    final StringBuffer buffer = StringBuffer();
    bool hasVisible = false;
    for (final SubtitleCueCopyParts parts in cues) {
      final String text = displayText(parts);
      if (text.isEmpty) continue;
      if (hasVisible) buffer.write(' ');
      buffer.write(text);
      hasVisible = true;
    }
    return buffer.toString();
  }

  /// Maps [selectedText] onto [cues]. Returns null when the selection cannot
  /// be placed in the joined display string.
  static List<SelectedCueSlice>? mapSelection({
    required String selectedText,
    required List<SubtitleCueCopyParts> cues,
  }) {
    if (selectedText.isEmpty) return const <SelectedCueSlice>[];
    final List<_CueDisplaySpan> spans = _buildDisplaySpans(cues);
    if (spans.isEmpty) return null;
    final String joined = joinedDisplayText(cues);
    final int selStart = joined.indexOf(selectedText);
    if (selStart < 0) return null;
    final int selEnd = selStart + selectedText.length;

    final List<SelectedCueSlice> slices = <SelectedCueSlice>[];
    for (final _CueDisplaySpan span in spans) {
      final int overlapStart = selStart > span.start ? selStart : span.start;
      final int overlapEnd = selEnd < span.end ? selEnd : span.end;
      if (overlapStart >= overlapEnd) continue;
      slices.add(
        _sliceCue(
          cues[span.cueIndex],
          overlapStart - span.start,
          overlapEnd - span.start,
        ),
      );
    }
    if (slices.isEmpty) return null;
    return slices;
  }

  static String format({
    required String selectedText,
    required List<SubtitleCueCopyParts> cues,
    required SubtitleCopyFormat format,
  }) {
    if (selectedText.isEmpty) return '';
    final List<SelectedCueSlice>? slices = mapSelection(
      selectedText: selectedText,
      cues: cues,
    );
    if (slices == null || slices.isEmpty) {
      return selectedText;
    }
    final StringBuffer buffer = StringBuffer();
    bool hasVisible = false;
    for (final SelectedCueSlice slice in slices) {
      final String text = _formatSlice(slice, format);
      if (text.isEmpty) continue;
      if (hasVisible) buffer.write(format.cueSeparator);
      buffer.write(text);
      hasVisible = true;
    }
    final String rendered = buffer.toString();
    return rendered.isEmpty ? selectedText : rendered;
  }

  static String _formatSlice(
    SelectedCueSlice slice,
    SubtitleCopyFormat format,
  ) {
    if (slice.secondary.isEmpty) return slice.primary;
    if (slice.primary.isEmpty) return slice.secondary;
    if (format.bilingualJoin == SubtitleCopyBilingualJoin.newline) {
      return '${slice.primary}\n${slice.secondary}';
    }
    return '${slice.primary} ${slice.secondary}';
  }

  static List<_CueDisplaySpan> _buildDisplaySpans(
    List<SubtitleCueCopyParts> cues,
  ) {
    final List<_CueDisplaySpan> spans = <_CueDisplaySpan>[];
    int offset = 0;
    bool hasVisible = false;
    for (int index = 0; index < cues.length; index++) {
      final String text = displayText(cues[index]);
      if (text.isEmpty) continue;
      if (hasVisible) offset += 1;
      spans.add(
        _CueDisplaySpan(
          cueIndex: index,
          start: offset,
          end: offset + text.length,
        ),
      );
      offset += text.length;
      hasVisible = true;
    }
    return spans;
  }

  /// Splits a substring of the cue's display text back into primary/secondary
  /// using the single space that bilingual display inserts after [primary].
  static SelectedCueSlice _sliceCue(
    SubtitleCueCopyParts parts,
    int start,
    int end,
  ) {
    final String display = displayText(parts);
    if (start < 0) start = 0;
    if (end > display.length) end = display.length;
    if (start >= end) {
      return const SelectedCueSlice(primary: '', secondary: '');
    }
    if (!parts.hasSecondary) {
      return SelectedCueSlice(
        primary: display.substring(start, end),
        secondary: '',
      );
    }
    if (parts.primary.isEmpty) {
      return SelectedCueSlice(
        primary: '',
        secondary: display.substring(start, end),
      );
    }

    final int boundary = parts.primary.length;
    String primary = '';
    String secondary = '';
    if (start < boundary) {
      final int primaryEnd = end < boundary ? end : boundary;
      primary = parts.primary.substring(start, primaryEnd);
    }
    final int secondaryOrigin = boundary + 1;
    if (end > secondaryOrigin) {
      final int secondaryStart = start > secondaryOrigin
          ? start - secondaryOrigin
          : 0;
      secondary = parts.secondary.substring(
        secondaryStart,
        end - secondaryOrigin,
      );
    }
    return SelectedCueSlice(primary: primary, secondary: secondary);
  }
}

class _CueDisplaySpan {
  const _CueDisplaySpan({
    required this.cueIndex,
    required this.start,
    required this.end,
  });

  final int cueIndex;
  final int start;
  final int end;
}
