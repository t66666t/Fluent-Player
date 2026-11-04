import '../models/subtitle_stream.dart';
import '../utils/append_buffer.dart';
import '../models/music_lyric_display_mode.dart';
import '../models/subtitle_model.dart';
import '../utils/subtitle_display_resolver.dart';
import '../widgets/music_timed_lyric_text.dart';

/// Role of one visible piece inside a lyric group. Background vocals and
/// romanization stay attached to the main lyric; they are not translations.
enum MusicLyricFragmentRole { main, background, secondary, romanization }

/// Stable identity of a source cue. Index, timestamp and text are each
/// allowed to repeat, so the ordinal is the position in the input list.
class MusicLyricSourceKey {
  final String mediaId;
  final String sourceVersion;
  final String track;
  final int ordinal;

  const MusicLyricSourceKey({
    required this.mediaId,
    required this.sourceVersion,
    required this.track,
    required this.ordinal,
  });

  @override
  bool operator ==(Object other) =>
      other is MusicLyricSourceKey &&
      other.mediaId == mediaId &&
      other.sourceVersion == sourceVersion &&
      other.track == track &&
      other.ordinal == ordinal;

  @override
  int get hashCode => Object.hash(mediaId, sourceVersion, track, ordinal);
}

class MusicLyricFragmentDraft {
  final MusicLyricSourceKey source;
  final MusicLyricFragmentRole role;
  final String instanceId;
  final String text;

  const MusicLyricFragmentDraft({
    required this.source,
    required this.role,
    required this.instanceId,
    required this.text,
  });
}

/// One visible lyric group. Display fields feed the animated lyric list;
/// [fragments] feed the continuous selection document.
class MusicLyricDisplayRow {
  final String groupId;
  final Duration start;
  final Duration end;
  final SubtitleItem followCue;
  final SubtitleItem main;
  final List<SubtitleItem> background;
  final String translation;
  final List<SubtitleTimedSpan> translationSpans;
  final String romanization;
  final List<SubtitleTimedSpan> romanizationSpans;
  final bool independentSecondary;
  final int? primaryOrdinal;
  final int? secondaryOrdinal;
  final List<MusicLyricFragmentDraft> fragments;

  const MusicLyricDisplayRow({
    required this.groupId,
    required this.start,
    required this.end,
    required this.followCue,
    required this.main,
    required this.background,
    required this.translation,
    required this.translationSpans,
    required this.romanization,
    required this.romanizationSpans,
    required this.independentSecondary,
    required this.primaryOrdinal,
    required this.secondaryOrdinal,
    required this.fragments,
  });

  bool get hasVisibleText =>
      main.text.trim().isNotEmpty ||
      background.any((item) => item.text.trim().isNotEmpty) ||
      translation.trim().isNotEmpty ||
      romanization.trim().isNotEmpty;
}

class MusicLyricProjection {
  final int primaryCount, secondaryCount;
  final List<SubtitleItem>? sourcePrimary, sourceSecondary;
  final String mediaId;
  final String sourceVersion;
  final bool splitSubtitleByLine;
  final MusicLyricTrackDisplayMode mode;
  final List<MusicLyricDisplayRow> rows;
  final MusicLyricTrackAvailability availability;

  const MusicLyricProjection({
    required this.mediaId,
    required this.sourceVersion,
    required this.splitSubtitleByLine,
    required this.mode,
    required this.rows,
    required this.availability,
    this.primaryCount = 0,
    this.secondaryCount = 0,
    this.sourcePrimary,
    this.sourceSecondary,
  });

  String get documentKey =>
      '$mediaId|$sourceVersion|${mode.storageValue}|$splitSubtitleByLine';
}

bool musicLyricTextIsVisible(String text) => text.trim().isNotEmpty;

/// Fingerprint of the lyric source. Font size, viewport and playback position
/// are not part of the content version.
String musicLyricSourceVersion({
  required List<SubtitleItem> primary,
  required List<SubtitleItem> secondary,
  required bool splitSubtitleByLine,
}) {
  if (primary is SubtitleCueSnapshot &&
      (secondary.isEmpty || secondary is SubtitleCueSnapshot)) {
    final secondaryIdentity = secondary is SubtitleCueSnapshot
        ? identityHashCode(secondary.sourceIdentity)
        : 0;
    return 'stream:${identityHashCode(primary.sourceIdentity)}:'
        '$secondaryIdentity:$splitSubtitleByLine';
  }
  String cue(SubtitleItem item) =>
      '${item.index}|${item.startTime.inMilliseconds}|${item.endTime.inMilliseconds}|'
      '${item.text}|${item.lyricTranslation}|${item.lyricRomanization}|'
      '${item.lyricAgent}|${item.isStructuredLyric}|${item.imageLoader != null}|'
      '${item.timedSpans.map((span) => '${span.role}:${span.textStart}:${span.textEnd}').join(',')}';
  return Object.hash(
    splitSubtitleByLine,
    Object.hashAll(primary.map(cue)),
    Object.hashAll(secondary.map(cue)),
  ).toString();
}

MusicLyricProjection resolveMusicLyricProjection({
  required String mediaId,
  required List<SubtitleItem> primary,
  required List<SubtitleItem> secondary,
  required bool splitSubtitleByLine,
  required MusicLyricTrackDisplayMode mode,
  MusicLyricProjection? previous,
}) {
  final version = musicLyricSourceVersion(
    primary: primary,
    secondary: secondary,
    splitSubtitleByLine: splitSubtitleByLine,
  );
  final append =
      previous != null &&
      previous.mediaId == mediaId &&
      previous.mode == mode &&
      previous.splitSubtitleByLine == splitSubtitleByLine &&
      previous.sourceVersion == version &&
      previous.sourcePrimary != null &&
      isSubtitleAppend(previous.sourcePrimary!, primary) &&
      (identical(previous.sourceSecondary, secondary) ||
          previous.sourceSecondary != null &&
              isSubtitleAppend(previous.sourceSecondary!, secondary));
  if (append && previous.rows is AppendSnapshot<MusicLyricDisplayRow>) {
    final offset = previous.primaryCount;
    final suffix = _buildRows(
      mediaId: mediaId,
      sourceVersion: version,
      primary: primary.skip(offset).toList(),
      secondary: secondary.skip(previous.secondaryCount).toList(),
      splitSubtitleByLine: splitSubtitleByLine,
      mode: mode,
    ).map((row) => _offsetStreamRow(row, offset, previous.secondaryCount));
    final buffer =
        (previous.rows as AppendSnapshot<MusicLyricDisplayRow>).owner;
    buffer.addAll(suffix);
    return MusicLyricProjection(
      mediaId: mediaId,
      sourceVersion: version,
      splitSubtitleByLine: splitSubtitleByLine,
      mode: mode,
      rows: buffer.snapshot,
      availability: previous.availability,
      primaryCount: primary.length,
      secondaryCount: secondary.length,
      sourcePrimary: primary,
      sourceSecondary: secondary,
    );
  }
  final bilingual = _buildRows(
    mediaId: mediaId,
    sourceVersion: version,
    primary: primary,
    secondary: secondary,
    splitSubtitleByLine: splitSubtitleByLine,
    mode: MusicLyricTrackDisplayMode.both,
  );
  final availability = _availabilityOf(
    primary: primary,
    secondary: secondary,
    rows: bilingual,
  );
  final rows = mode == MusicLyricTrackDisplayMode.both
      ? bilingual
      : _buildRows(
          mediaId: mediaId,
          sourceVersion: version,
          primary: primary,
          secondary: secondary,
          splitSubtitleByLine: splitSubtitleByLine,
          mode: mode,
        );
  final streamRows = primary is SubtitleCueSnapshot
      ? (AppendBuffer<MusicLyricDisplayRow>()..addAll(rows)).snapshot
      : rows;
  return MusicLyricProjection(
    mediaId: mediaId,
    sourceVersion: version,
    splitSubtitleByLine: splitSubtitleByLine,
    mode: mode,
    rows: streamRows,
    availability: availability,
    primaryCount: primary.length,
    secondaryCount: secondary.length,
    sourcePrimary: primary,
    sourceSecondary: secondary,
  );
}

MusicLyricDisplayRow _offsetStreamRow(
  MusicLyricDisplayRow row,
  int primary,
  int secondary,
) {
  final groupId = row.independentSecondary
      ? 's:${(row.secondaryOrdinal ?? 0) + secondary}'
      : 'p:${(row.primaryOrdinal ?? 0) + primary}';
  return MusicLyricDisplayRow(
    groupId: groupId,
    start: row.start,
    end: row.end,
    followCue: row.followCue,
    main: row.main,
    background: row.background,
    translation: row.translation,
    translationSpans: row.translationSpans,
    romanization: row.romanization,
    romanizationSpans: row.romanizationSpans,
    independentSecondary: row.independentSecondary,
    primaryOrdinal: row.primaryOrdinal == null
        ? null
        : row.primaryOrdinal! + primary,
    secondaryOrdinal: row.secondaryOrdinal == null
        ? null
        : row.secondaryOrdinal! + secondary,
    fragments: [
      for (final fragment in row.fragments)
        MusicLyricFragmentDraft(
          source: MusicLyricSourceKey(
            mediaId: fragment.source.mediaId,
            sourceVersion: fragment.source.sourceVersion,
            track: fragment.source.track,
            ordinal:
                fragment.source.ordinal +
                (fragment.source.track == 'primary' ? primary : secondary),
          ),
          role: fragment.role,
          instanceId:
              '$groupId:${fragment.role.name}:${fragment.source.track}:${fragment.source.ordinal + (fragment.source.track == 'primary' ? primary : secondary)}',
          text: fragment.text,
        ),
    ],
  );
}

MusicLyricTrackAvailability _availabilityOf({
  required List<SubtitleItem> primary,
  required List<SubtitleItem> secondary,
  required List<MusicLyricDisplayRow> rows,
}) {
  final hasPrimary = rows.any(
    (row) =>
        !row.independentSecondary &&
        (row.main.text.trim().isNotEmpty ||
            row.background.any((item) => item.text.trim().isNotEmpty) ||
            row.romanization.trim().isNotEmpty),
  );
  final hasSecondary = rows.any(
    (row) => row.independentSecondary || row.translation.trim().isNotEmpty,
  );
  final imageOnly =
      !hasPrimary &&
      !hasSecondary &&
      (primary.any(
            (item) => item.imageLoader != null && item.text.trim().isEmpty,
          ) ||
          secondary.any(
            (item) => item.imageLoader != null && item.text.trim().isEmpty,
          ));
  return MusicLyricTrackAvailability(
    hasPrimaryText: hasPrimary,
    hasSecondaryText: hasSecondary,
    imageOnly: imageOnly,
  );
}

List<MusicLyricDisplayRow> _buildRows({
  required String mediaId,
  required String sourceVersion,
  required List<SubtitleItem> primary,
  required List<SubtitleItem> secondary,
  required bool splitSubtitleByLine,
  required MusicLyricTrackDisplayMode mode,
}) {
  final trackExists = secondary.any(
    (item) => musicLyricTextIsVisible(item.text),
  );
  if (mode == MusicLyricTrackDisplayMode.secondary && trackExists) {
    return _secondaryTrackRows(
      mediaId: mediaId,
      sourceVersion: sourceVersion,
      secondary: secondary,
    );
  }

  final matches = matchSubtitleTracks(
    primarySubtitles: primary,
    secondarySubtitles: secondary,
  );
  final consumedSecondary = <int>{};
  final groups = <_TimedRow>[];
  for (var index = 0; index < primary.length; index++) {
    final row = _primaryRow(
      mediaId: mediaId,
      sourceVersion: sourceVersion,
      cue: primary[index],
      ordinal: index,
      matches: matches,
      secondary: secondary,
      splitSubtitleByLine: splitSubtitleByLine,
      independentTrackExists: trackExists,
      mode: mode,
    );
    if (row == null) continue;
    for (final ordinal in row.consumedSecondary) {
      consumedSecondary.add(ordinal);
    }
    groups.add(row);
  }

  if (mode != MusicLyricTrackDisplayMode.primary) {
    for (var index = 0; index < secondary.length; index++) {
      if (consumedSecondary.contains(index)) continue;
      final cue = secondary[index];
      if (!musicLyricTextIsVisible(cue.text)) continue;
      groups.add(
        _independentSecondary(
          mediaId: mediaId,
          sourceVersion: sourceVersion,
          cue: cue,
          ordinal: index,
        ),
      );
    }
  }

  groups.sort((a, b) {
    final byTime = a.start.compareTo(b.start);
    if (byTime != 0) return byTime;
    // Equal start times keep the primary group ahead of an orphan secondary.
    final byKind = (a.row.independentSecondary ? 1 : 0).compareTo(
      b.row.independentSecondary ? 1 : 0,
    );
    if (byKind != 0) return byKind;
    return a.order.compareTo(b.order);
  });
  return [for (final group in groups) group.row];
}

class _TimedRow {
  final MusicLyricDisplayRow row;
  final Duration start;
  final int order;
  final List<int> consumedSecondary;
  const _TimedRow(this.row, this.start, this.order, this.consumedSecondary);
}

_TimedRow? _primaryRow({
  required String mediaId,
  required String sourceVersion,
  required SubtitleItem cue,
  required int ordinal,
  required SubtitleTrackMatchResult matches,
  required List<SubtitleItem> secondary,
  required bool splitSubtitleByLine,
  required bool independentTrackExists,
  required MusicLyricTrackDisplayMode mode,
}) {
  final visual = musicLyricVisualCues(cue);
  var main = visual.main;
  final matched = _matchedSecondary(
    ordinal: ordinal,
    matches: matches,
    secondary: secondary,
  );
  var translation = matched.text;
  var translationSpans = matched.spans;
  final usedEmbedded =
      translation.isEmpty && musicLyricTextIsVisible(cue.lyricTranslation);
  if (usedEmbedded) {
    translation = cue.lyricTranslation.trim();
    translationSpans = cue.lyricTranslationSpans;
  }
  // Embedded translation wins over newline splitting. Splitting is only the
  // fallback when this cue has no secondary text and no independent track.
  if (translation.isEmpty &&
      !independentTrackExists &&
      splitSubtitleByLine &&
      main.text.contains('\n')) {
    final lines = main.text.split('\n');
    final head = lines.first;
    translation = lines.skip(1).join('\n');
    main = main.copyWith(
      text: head,
      timedSpans: main.timedSpans
          .where((span) => span.textEnd <= head.length)
          .toList(),
    );
    translationSpans = const [];
  }

  final showSecondary = mode != MusicLyricTrackDisplayMode.primary;
  final showPrimary = mode != MusicLyricTrackDisplayMode.secondary;
  if (mode == MusicLyricTrackDisplayMode.secondary &&
      translation.trim().isEmpty) {
    return null;
  }

  final source = MusicLyricSourceKey(
    mediaId: mediaId,
    sourceVersion: sourceVersion,
    track: 'primary',
    ordinal: ordinal,
  );
  final groupId = 'p:$ordinal';
  final fragments = <MusicLyricFragmentDraft>[];
  void add(
    MusicLyricFragmentRole role,
    String text,
    String track,
    int sourceOrdinal,
  ) {
    if (!musicLyricTextIsVisible(text)) return;
    fragments.add(
      MusicLyricFragmentDraft(
        source: MusicLyricSourceKey(
          mediaId: mediaId,
          sourceVersion: sourceVersion,
          track: track,
          ordinal: sourceOrdinal,
        ),
        role: role,
        instanceId: '$groupId:${role.name}:$track:$sourceOrdinal',
        text: text,
      ),
    );
  }

  if (showPrimary && main.text.isNotEmpty) {
    add(MusicLyricFragmentRole.main, main.text, 'primary', ordinal);
  }
  if (showPrimary) {
    for (var part = 0; part < visual.background.length; part++) {
      final background = visual.background[part];
      if (background.text.isEmpty) continue;
      fragments.add(
        MusicLyricFragmentDraft(
          source: source,
          role: MusicLyricFragmentRole.background,
          instanceId: '$groupId:background:$part',
          text: background.text,
        ),
      );
    }
  }
  if (showSecondary && translation.isNotEmpty) {
    if (matched.pieces.isNotEmpty && !usedEmbedded) {
      for (final piece in matched.pieces) {
        add(
          MusicLyricFragmentRole.secondary,
          piece.text,
          'secondary',
          piece.ordinal,
        );
      }
    } else {
      add(
        MusicLyricFragmentRole.secondary,
        translation,
        usedEmbedded ? 'embedded' : 'primary',
        ordinal,
      );
    }
  }
  if (showPrimary && cue.lyricRomanization.isNotEmpty) {
    add(
      MusicLyricFragmentRole.romanization,
      cue.lyricRomanization,
      'primary',
      ordinal,
    );
  }
  if (fragments.isEmpty) return null;

  final displayMain = showPrimary
      ? main
      : SubtitleItem(
          index: cue.index,
          startTime: cue.startTime,
          endTime: cue.endTime,
          text: translation,
          timedSpans: translationSpans,
        );
  return _TimedRow(
    MusicLyricDisplayRow(
      groupId: groupId,
      start: cue.startTime,
      end: cue.endTime,
      followCue: cue,
      main: displayMain,
      background: showPrimary ? visual.background : const [],
      translation: showPrimary && showSecondary ? translation : '',
      translationSpans: showPrimary && showSecondary
          ? translationSpans
          : const [],
      romanization: showPrimary ? cue.lyricRomanization : '',
      romanizationSpans: showPrimary ? cue.lyricRomanizationSpans : const [],
      independentSecondary: false,
      primaryOrdinal: ordinal,
      secondaryOrdinal: null,
      fragments: fragments,
    ),
    cue.startTime,
    ordinal,
    matched.ordinals,
  );
}

class _MatchedSecondary {
  final String text;
  final List<SubtitleTimedSpan> spans;
  final List<int> ordinals;
  final List<({int ordinal, String text})> pieces;
  const _MatchedSecondary(this.text, this.spans, this.ordinals, this.pieces);
}

_MatchedSecondary _matchedSecondary({
  required int ordinal,
  required SubtitleTrackMatchResult matches,
  required List<SubtitleItem> secondary,
}) {
  final indices =
      matches.primaryToSecondaryIndices[ordinal] ??
      (matches.primaryToSecondary.containsKey(ordinal)
          ? <int>[matches.primaryToSecondary[ordinal]!]
          : const <int>[]);
  final pieces = <({int ordinal, String text})>[];
  final spans = <SubtitleTimedSpan>[];
  final ordinals = <int>[];
  var length = 0;
  String? previous;
  for (final index in indices) {
    if (index < 0 || index >= secondary.length) continue;
    final cue = secondary[index].trimmed();
    if (cue.text.isEmpty) continue;
    final normalized = cue.text.replaceAll(RegExp(r'\s+'), ' ');
    // Keep the resolver's adjacent-OCR collapse. Repeated lyrics at
    // different times stay as separate cues and are not removed here.
    if (normalized == previous) {
      ordinals.add(index);
      previous = normalized;
      continue;
    }
    if (length > 0) length++;
    spans.addAll(
      cue.timedSpans.map(
        (span) => span.shifted(Duration.zero, textOffset: length),
      ),
    );
    length += cue.text.length;
    pieces.add((ordinal: index, text: cue.text));
    ordinals.add(index);
    previous = normalized;
  }
  return _MatchedSecondary(
    pieces.map((piece) => piece.text).join('\n'),
    spans,
    ordinals,
    pieces,
  );
}

List<MusicLyricDisplayRow> _secondaryTrackRows({
  required String mediaId,
  required String sourceVersion,
  required List<SubtitleItem> secondary,
}) {
  final rows = <MusicLyricDisplayRow>[];
  for (var index = 0; index < secondary.length; index++) {
    final cue = secondary[index];
    if (!musicLyricTextIsVisible(cue.text)) continue;
    rows.add(
      _independentSecondary(
        mediaId: mediaId,
        sourceVersion: sourceVersion,
        cue: cue,
        ordinal: index,
      ).row,
    );
  }
  return rows;
}

_TimedRow _independentSecondary({
  required String mediaId,
  required String sourceVersion,
  required SubtitleItem cue,
  required int ordinal,
}) {
  final trimmed = cue.trimmed();
  final groupId = 's:$ordinal';
  final fragment = MusicLyricFragmentDraft(
    source: MusicLyricSourceKey(
      mediaId: mediaId,
      sourceVersion: sourceVersion,
      track: 'secondary',
      ordinal: ordinal,
    ),
    role: MusicLyricFragmentRole.secondary,
    instanceId: '$groupId:secondary:secondary:$ordinal',
    text: trimmed.text,
  );
  return _TimedRow(
    MusicLyricDisplayRow(
      groupId: groupId,
      start: cue.startTime,
      end: cue.endTime,
      followCue: cue,
      main: SubtitleItem(
        index: cue.index,
        startTime: cue.startTime,
        endTime: cue.endTime,
        text: trimmed.text,
        timedSpans: trimmed.timedSpans,
      ),
      background: const [],
      translation: '',
      translationSpans: const [],
      romanization: '',
      romanizationSpans: const [],
      independentSecondary: true,
      primaryOrdinal: null,
      secondaryOrdinal: ordinal,
      fragments: [fragment],
    ),
    cue.startTime,
    100000 + ordinal,
    const [],
  );
}
