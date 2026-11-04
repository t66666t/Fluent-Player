import 'package:flutter/material.dart';

import 'music_lyric_display_mode.dart';
import '../services/music_lyric_content_resolver.dart';

/// A fragment placed inside the single continuous selection string.
class MusicLyricTextFragment {
  final MusicLyricSourceKey source;
  final MusicLyricFragmentRole role;
  final String instanceId;
  final String groupId;
  final String text;
  final int documentStart;
  final int documentEnd;
  final Duration time;

  const MusicLyricTextFragment({
    required this.source,
    required this.role,
    required this.instanceId,
    required this.groupId,
    required this.text,
    required this.documentStart,
    required this.documentEnd,
    required this.time,
  });

  int get length => documentEnd - documentStart;
}

class MusicLyricTextGroup {
  final String groupId;
  final Duration start;
  final Duration end;
  final int? primaryOrdinal;
  final int? secondaryOrdinal;
  final int documentStart;
  final int documentEnd;
  final List<MusicLyricTextFragment> fragments;

  const MusicLyricTextGroup({
    required this.groupId,
    required this.start,
    required this.end,
    required this.primaryOrdinal,
    required this.secondaryOrdinal,
    required this.documentStart,
    required this.documentEnd,
    required this.fragments,
  });
}

/// Where playback sits relative to the visible lyric groups at one frozen clock.
enum MusicLyricPlaybackPlace { playing, beforeFirst, between, afterLast }

/// The line to show when selection opens. Only [playing] paints a background.
/// Gaps scroll to a boundary line without inventing placeholder words.
class MusicLyricPlaybackFocus {
  final MusicLyricPlaybackPlace place;
  final String? scrollGroupId;
  final String? highlightedGroupId;
  final MusicLyricReadingAnchor anchor;

  const MusicLyricPlaybackFocus({
    required this.place,
    required this.scrollGroupId,
    required this.highlightedGroupId,
    required this.anchor,
  });
}

/// Where to put the viewport after a mode change or rotation. The anchor is a
/// source cue plus a fraction of the viewport, not a raw scroll offset.
class MusicLyricReadingAnchor {
  final String? groupId;
  final Duration time;
  final int documentOffset;
  final double viewportFraction;

  const MusicLyricReadingAnchor({
    required this.groupId,
    required this.time,
    required this.documentOffset,
    this.viewportFraction = 0.24,
  });

  static const top = MusicLyricReadingAnchor(
    groupId: null,
    time: Duration.zero,
    documentOffset: 0,
  );
}

class MusicLyricSelectionRestore {
  final TextSelection selection;
  final bool cleared;
  final String? message;
  final MusicLyricReadingAnchor anchor;

  const MusicLyricSelectionRestore({
    required this.selection,
    required this.cleared,
    required this.anchor,
    this.message,
  });
}

/// One read-only document for the selection field. Offsets are UTF-16, matching
/// Flutter's [TextSelection], and every boundary is a grapheme boundary.
class MusicLyricSelectionDocument {
  final String documentKey;
  final String mediaId;
  final String sourceVersion;
  final MusicLyricTrackDisplayMode mode;
  final String fullText;
  final List<MusicLyricTextFragment> fragments;
  final List<MusicLyricTextGroup> groups;

  const MusicLyricSelectionDocument({
    required this.documentKey,
    required this.mediaId,
    required this.sourceVersion,
    required this.mode,
    required this.fullText,
    required this.fragments,
    required this.groups,
  });

  static const empty = MusicLyricSelectionDocument(
    documentKey: '',
    mediaId: '',
    sourceVersion: '',
    mode: MusicLyricTrackDisplayMode.both,
    fullText: '',
    fragments: [],
    groups: [],
  );

  bool get isEmpty => fullText.isEmpty;

  factory MusicLyricSelectionDocument.fromProjection(
    MusicLyricProjection projection,
  ) {
    final fragments = <MusicLyricTextFragment>[];
    final groups = <MusicLyricTextGroup>[];
    final buffer = StringBuffer();
    for (
      var groupIndex = 0;
      groupIndex < projection.rows.length;
      groupIndex++
    ) {
      final row = projection.rows[groupIndex];
      final visible = row.fragments.where((piece) => piece.text.isNotEmpty);
      if (visible.isEmpty) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      final groupStart = buffer.length;
      final groupFragments = <MusicLyricTextFragment>[];
      var first = true;
      for (final piece in visible) {
        if (!first) buffer.write('\n');
        first = false;
        final start = buffer.length;
        buffer.write(piece.text);
        final fragment = MusicLyricTextFragment(
          source: piece.source,
          role: piece.role,
          instanceId: piece.instanceId,
          groupId: row.groupId,
          text: piece.text,
          documentStart: start,
          documentEnd: buffer.length,
          time: row.start,
        );
        fragments.add(fragment);
        groupFragments.add(fragment);
      }
      groups.add(
        MusicLyricTextGroup(
          groupId: row.groupId,
          start: row.start,
          end: row.end,
          primaryOrdinal: row.primaryOrdinal,
          secondaryOrdinal: row.secondaryOrdinal,
          documentStart: groupStart,
          documentEnd: buffer.length,
          fragments: groupFragments,
        ),
      );
    }
    return MusicLyricSelectionDocument(
      documentKey: projection.documentKey,
      mediaId: projection.mediaId,
      sourceVersion: projection.sourceVersion,
      mode: projection.mode,
      fullText: buffer.toString(),
      fragments: fragments,
      groups: groups,
    );
  }

  MusicLyricTextGroup? groupById(String? groupId) {
    if (groupId == null) return null;
    for (final group in groups) {
      if (group.groupId == groupId) return group;
    }
    return null;
  }

  TextSelection selectionForGroup(String groupId) {
    final group = groupById(groupId);
    if (group == null || group.fragments.isEmpty) {
      return const TextSelection.collapsed(offset: 0);
    }
    return TextSelection(
      baseOffset: group.documentStart,
      extentOffset: group.documentEnd,
    );
  }

  /// The group that should be selected when the user opens the workspace
  /// without pressing a specific row.
  String? initialGroupId({Duration? playing, String? visibleGroupId}) {
    if (groups.isEmpty) return null;
    if (playing != null) {
      MusicLyricTextGroup? current;
      for (final group in groups) {
        if (group.start <= playing) current = group;
      }
      if (current != null && current.fragments.isNotEmpty) {
        return current.groupId;
      }
    }
    if (visibleGroupId != null && groupById(visibleGroupId) != null) {
      return visibleGroupId;
    }
    return groups.first.groupId;
  }

  TextSelection snap(TextSelection selection) {
    final start = _snapGrapheme(fullText, selection.start, towardEnd: false);
    final end = _snapGrapheme(fullText, selection.end, towardEnd: true);
    if (selection.isCollapsed) {
      final offset = _snapGrapheme(
        fullText,
        selection.extentOffset,
        towardEnd: false,
      );
      return TextSelection.collapsed(offset: offset);
    }
    return selection.baseOffset <= selection.extentOffset
        ? TextSelection(baseOffset: start, extentOffset: end)
        : TextSelection(baseOffset: end, extentOffset: start);
  }

  /// Clipboard text is the document substring. Hidden tracks are absent from
  /// [fullText], so they cannot be copied from here.
  String textFor(TextSelection selection) {
    if (selection.isCollapsed || fullText.isEmpty) return '';
    final snapped = snap(selection);
    final start = snapped.start.clamp(0, fullText.length);
    final end = snapped.end.clamp(0, fullText.length);
    if (end <= start) return '';
    return fullText.substring(start, end);
  }

  /// Soft wash behind the lyric that was playing when selection opened.
  /// It stays distinct from the blue text-selection color.
  static const Color playingBackground = Color(0x33FFFFFF);

  /// Resolves the frozen clock against group ranges. Overlapping groups keep
  /// the one that started latest. Gaps do not invent text.
  MusicLyricPlaybackFocus playbackFocusAt(Duration time) {
    if (groups.isEmpty) {
      return MusicLyricPlaybackFocus(
        place: MusicLyricPlaybackPlace.beforeFirst,
        scrollGroupId: null,
        highlightedGroupId: null,
        anchor: MusicLyricReadingAnchor(
          groupId: null,
          time: time,
          documentOffset: 0,
        ),
      );
    }
    final first = groups.first;
    if (time < first.start) {
      return _focus(
        MusicLyricPlaybackPlace.beforeFirst,
        first,
        highlighted: null,
        time: time,
      );
    }
    MusicLyricTextGroup? playing;
    for (final group in groups) {
      final contains = time >= group.start && time < group.end;
      if (!contains) continue;
      if (playing == null || group.start >= playing.start) playing = group;
    }
    if (playing != null) {
      return _focus(
        MusicLyricPlaybackPlace.playing,
        playing,
        highlighted: playing,
        time: time,
      );
    }
    final last = groups.last;
    if (time >= last.end) {
      return _focus(
        MusicLyricPlaybackPlace.afterLast,
        last,
        highlighted: null,
        time: time,
      );
    }
    MusicLyricTextGroup? upcoming;
    for (final group in groups) {
      if (group.start > time) {
        upcoming = group;
        break;
      }
    }
    return _focus(
      MusicLyricPlaybackPlace.between,
      upcoming ?? last,
      highlighted: null,
      time: time,
    );
  }

  MusicLyricPlaybackFocus _focus(
    MusicLyricPlaybackPlace place,
    MusicLyricTextGroup scrollGroup, {
    required MusicLyricTextGroup? highlighted,
    required Duration time,
  }) {
    return MusicLyricPlaybackFocus(
      place: place,
      scrollGroupId: scrollGroup.groupId,
      highlightedGroupId: highlighted?.groupId,
      anchor: MusicLyricReadingAnchor(
        groupId: scrollGroup.groupId,
        time: scrollGroup.start,
        documentOffset: scrollGroup.documentStart,
        viewportFraction: 0.24,
      ),
    );
  }

  TextSpan buildTextSpan({
    required TextStyle primaryStyle,
    required TextStyle secondaryStyle,
    required TextStyle romanizationStyle,
    required TextStyle backgroundStyle,
    String? highlightedGroupId,
  }) {
    if (fullText.isEmpty) {
      return TextSpan(text: '', style: primaryStyle);
    }
    final highlighted = groupById(highlightedGroupId);
    TextStyle mark(TextStyle style) =>
        style.copyWith(backgroundColor: playingBackground);
    final children = <InlineSpan>[];
    var cursor = 0;
    void writePlain(int until, TextStyle style) {
      if (until <= cursor) return;
      final inside =
          highlighted != null &&
          cursor >= highlighted.documentStart &&
          until <= highlighted.documentEnd;
      children.add(
        TextSpan(
          text: fullText.substring(cursor, until),
          style: inside ? mark(style) : style,
        ),
      );
      cursor = until;
    }

    for (final fragment in fragments) {
      writePlain(fragment.documentStart, primaryStyle);
      final style = switch (fragment.role) {
        MusicLyricFragmentRole.main => primaryStyle,
        MusicLyricFragmentRole.background => backgroundStyle,
        MusicLyricFragmentRole.secondary => secondaryStyle,
        MusicLyricFragmentRole.romanization => romanizationStyle,
      };
      final playing = fragment.groupId == highlightedGroupId;
      children.add(
        TextSpan(text: fragment.text, style: playing ? mark(style) : style),
      );
      cursor = fragment.documentEnd;
    }
    writePlain(fullText.length, primaryStyle);
    final span = TextSpan(children: children, style: primaryStyle);
    assert(span.toPlainText() == fullText);
    return span;
  }

  MusicLyricReadingAnchor anchorForSelection(TextSelection selection) {
    final offset = selection.start.clamp(0, fullText.length);
    final fragment =
        _fragmentAt(offset) ?? (fragments.isEmpty ? null : fragments.first);
    return MusicLyricReadingAnchor(
      groupId: fragment?.groupId,
      time: fragment?.time ?? Duration.zero,
      documentOffset: offset,
      viewportFraction: 0.24,
    );
  }

  MusicLyricReadingAnchor anchorForTime(Duration time) {
    final group = _nearestGroup(time);
    return MusicLyricReadingAnchor(
      groupId: group?.groupId,
      time: group?.start ?? time,
      documentOffset: group?.documentStart ?? 0,
    );
  }

  /// Restores a selection only when every selected piece still exists and the
  /// pieces remain one continuous span. Anything else keeps the reading
  /// position and clears the range so hidden text is never copied.
  MusicLyricSelectionRestore restoreSelection({
    required TextSelection selection,
    required MusicLyricSelectionDocument next,
  }) {
    final snapped = snap(selection);
    final anchor = anchorForSelection(snapped);
    final nextAnchor = next.anchorForTime(anchor.time);
    if (snapped.isCollapsed || fragments.isEmpty) {
      return MusicLyricSelectionRestore(
        selection: const TextSelection.collapsed(offset: 0),
        cleared: true,
        anchor: nextAnchor,
      );
    }
    final pieces = _selectedPieces(snapped);
    if (pieces.isEmpty) {
      return MusicLyricSelectionRestore(
        selection: const TextSelection.collapsed(offset: 0),
        cleared: true,
        anchor: nextAnchor,
      );
    }
    final mapped =
        <({_SelectedPiece piece, MusicLyricTextFragment fragment})>[];
    for (final piece in pieces) {
      final candidates = next.fragments.where((fragment) {
        return fragment.source == piece.fragment.source &&
            fragment.role == piece.fragment.role &&
            fragment.text == piece.fragment.text;
      }).toList();
      final sameInstance = candidates
          .where((fragment) => fragment.instanceId == piece.fragment.instanceId)
          .toList();
      final MusicLyricTextFragment? chosen = sameInstance.length == 1
          ? sameInstance.single
          : candidates.length == 1
          ? candidates.single
          : null;
      if (chosen == null || piece.localEnd > chosen.text.length) {
        return MusicLyricSelectionRestore(
          selection: const TextSelection.collapsed(offset: 0),
          cleared: true,
          message: '显示内容已切换，请重新选择',
          anchor: nextAnchor,
        );
      }
      mapped.add((piece: piece, fragment: chosen));
    }
    final ordered = [...mapped]
      ..sort(
        (a, b) => a.fragment.documentStart.compareTo(b.fragment.documentStart),
      );
    if (!_sameOrder(mapped, ordered)) {
      return MusicLyricSelectionRestore(
        selection: const TextSelection.collapsed(offset: 0),
        cleared: true,
        message: '显示内容已切换，请重新选择',
        anchor: nextAnchor,
      );
    }
    final start =
        ordered.first.fragment.documentStart + ordered.first.piece.localStart;
    final end =
        ordered.last.fragment.documentStart + ordered.last.piece.localEnd;
    final covered = <MusicLyricTextFragment>{
      for (final item in ordered) item.fragment,
    };
    for (final fragment in next.fragments) {
      final overlaps =
          fragment.documentEnd > start && fragment.documentStart < end;
      if (overlaps && !covered.contains(fragment)) {
        return MusicLyricSelectionRestore(
          selection: const TextSelection.collapsed(offset: 0),
          cleared: true,
          message: '显示内容已切换，请重新选择',
          anchor: next.anchorForTime(anchor.time),
        );
      }
    }
    final forward = snapped.baseOffset <= snapped.extentOffset;
    return MusicLyricSelectionRestore(
      selection: TextSelection(
        baseOffset: forward ? start : end,
        extentOffset: forward ? end : start,
      ),
      cleared: false,
      anchor: MusicLyricReadingAnchor(
        groupId: ordered.first.fragment.groupId,
        time: ordered.first.fragment.time,
        documentOffset: start,
      ),
    );
  }

  MusicLyricTextGroup? _nearestGroup(Duration time) {
    if (groups.isEmpty) return null;
    MusicLyricTextGroup best = groups.first;
    var bestDistance = (best.start - time).inMicroseconds.abs();
    for (final group in groups.skip(1)) {
      final distance = (group.start - time).inMicroseconds.abs();
      if (distance < bestDistance ||
          (distance == bestDistance && group.start < best.start)) {
        best = group;
        bestDistance = distance;
      }
    }
    return best;
  }

  MusicLyricTextFragment? _fragmentAt(int offset) {
    for (final fragment in fragments) {
      if (offset >= fragment.documentStart && offset <= fragment.documentEnd) {
        return fragment;
      }
    }
    return null;
  }

  List<_SelectedPiece> _selectedPieces(TextSelection selection) {
    final start = selection.start;
    final end = selection.end;
    final pieces = <_SelectedPiece>[];
    for (final fragment in fragments) {
      if (fragment.documentEnd <= start || fragment.documentStart >= end) {
        continue;
      }
      final localStart = (start - fragment.documentStart).clamp(
        0,
        fragment.length,
      );
      final localEnd = (end - fragment.documentStart).clamp(0, fragment.length);
      if (localEnd <= localStart) continue;
      pieces.add(
        _SelectedPiece(
          fragment: fragment,
          localStart: localStart,
          localEnd: localEnd,
        ),
      );
    }
    return pieces;
  }
}

class _SelectedPiece {
  final MusicLyricTextFragment fragment;
  final int localStart;
  final int localEnd;
  const _SelectedPiece({
    required this.fragment,
    required this.localStart,
    required this.localEnd,
  });
}

bool _sameOrder(
  List<({_SelectedPiece piece, MusicLyricTextFragment fragment})> original,
  List<({_SelectedPiece piece, MusicLyricTextFragment fragment})> ordered,
) {
  if (original.length != ordered.length) return false;
  for (var index = 0; index < original.length; index++) {
    if (!identical(original[index].fragment, ordered[index].fragment)) {
      return false;
    }
  }
  return true;
}

int _snapGrapheme(String text, int offset, {required bool towardEnd}) {
  if (text.isEmpty) return 0;
  final clamped = offset.clamp(0, text.length);
  var cursor = 0;
  for (final grapheme in text.characters) {
    final next = cursor + grapheme.length;
    if (clamped == cursor || clamped == next) return clamped;
    if (clamped < next) return towardEnd ? next : cursor;
    cursor = next;
  }
  return text.length;
}
