import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/controllers/music_lyric_selection_controller.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/music_lyric_selection_document.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/music_lyric_content_resolver.dart';

SubtitleItem _cue(
  int index,
  int startMs,
  String text, {
  String translation = '',
  String romanization = '',
}) {
  return SubtitleItem(
    index: index,
    startTime: Duration(milliseconds: startMs),
    endTime: Duration(milliseconds: startMs + 1000),
    text: text,
    lyricTranslation: translation,
    lyricRomanization: romanization,
  );
}

MusicLyricSelectionDocument _document(
  List<SubtitleItem> primary,
  MusicLyricTrackDisplayMode mode, {
  List<SubtitleItem> secondary = const [],
  bool split = false,
}) {
  return MusicLyricSelectionDocument.fromProjection(
    resolveMusicLyricProjection(
      mediaId: 'song',
      primary: primary,
      secondary: secondary,
      splitSubtitleByLine: split,
      mode: mode,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bilingual document keeps exact newlines and copies the selection', () {
    final document = _document([
      _cue(1, 0, 'Hello', translation: '你好'),
      _cue(2, 2000, 'Stay with me', translation: '留在我身边'),
    ], MusicLyricTrackDisplayMode.both);
    expect(document.fullText, 'Hello\n你好\nStay with me\n留在我身边');
    final span = document.buildTextSpan(
      primaryStyle: const TextStyle(),
      secondaryStyle: const TextStyle(),
      backgroundStyle: const TextStyle(),
      romanizationStyle: const TextStyle(),
    );
    expect(span.toPlainText(), document.fullText);
    final hello = document.selectionForGroup('p:0');
    expect(document.textFor(hello), 'Hello\n你好');
    expect(
      document.textFor(hello),
      document.fullText.substring(hello.start, hello.end),
    );
  });

  test('emoji and combining marks stay on grapheme boundaries', () {
    final document = _document([
      _cue(1, 0, 'Hi 👋'),
      _cue(1, 1000, 'e\u0301'),
    ], MusicLyricTrackDisplayMode.both);
    final snapped = document.snap(
      const TextSelection(baseOffset: 3, extentOffset: 4),
    );
    expect(document.fullText.substring(snapped.start, snapped.end), '👋');
    expect(document.groups, hasLength(2));
    expect(document.groups.map((group) => group.groupId), ['p:0', 'p:1']);
  });

  test('repeated index and time stay distinct groups', () {
    final document = _document([
      _cue(7, 0, 'Again'),
      _cue(7, 0, 'Again'),
    ], MusicLyricTrackDisplayMode.both);
    expect(document.fullText, 'Again\nAgain');
    expect(document.groups, hasLength(2));
  });

  test('mode changes keep a continuous range and clear a broken one', () {
    final both = _document([
      _cue(1, 0, 'Hello', translation: '你好'),
      _cue(2, 2000, 'Stay', translation: '留'),
    ], MusicLyricTrackDisplayMode.both);
    final primary = _document([
      _cue(1, 0, 'Hello', translation: '你好'),
      _cue(2, 2000, 'Stay', translation: '留'),
    ], MusicLyricTrackDisplayMode.primary);
    final secondary = _document([
      _cue(1, 0, 'Hello', translation: '你好'),
      _cue(2, 2000, 'Stay', translation: '留'),
    ], MusicLyricTrackDisplayMode.secondary);
    final hello = TextSelection(baseOffset: 0, extentOffset: 'Hello'.length);
    final kept = both.restoreSelection(selection: hello, next: primary);
    expect(kept.cleared, isFalse);
    expect(primary.textFor(kept.selection), 'Hello');

    final pair = both.selectionForGroup('p:0');
    final cleared = both.restoreSelection(selection: pair, next: primary);
    expect(cleared.cleared, isTrue);
    expect(cleared.message, '显示内容已切换，请重新选择');
    expect(cleared.anchor.time, Duration.zero);

    final chinese = TextSelection(baseOffset: 6, extentOffset: 8);
    expect(both.textFor(chinese), '你好');
    final restored = both.restoreSelection(selection: chinese, next: secondary);
    expect(restored.cleared, isFalse);
    expect(secondary.textFor(restored.selection), '你好');

    final all = TextSelection(
      baseOffset: 0,
      extentOffset: both.fullText.length,
    );
    final notExpanded = both.restoreSelection(selection: all, next: primary);
    expect(notExpanded.cleared, isTrue);
    expect(primary.textFor(notExpanded.selection), isEmpty);
  });

  test('copy writes the selection once and refuses an empty range', () async {
    final controller = MusicLyricSelectionController();
    controller.begin(
      mediaId: 'song',
      primary: [_cue(1, 0, 'Hello', translation: '你好')],
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
      groupId: 'p:0',
      time: Duration.zero,
      awaitingPointer: false,
    );
    expect(await controller.copySelection(), isTrue);
    expect(controller.statusMessage, '已复制');
    expect(controller.document.textFor(controller.selection), 'Hello\n你好');

    controller.clearStatus();
    controller.updateSelection(const TextSelection.collapsed(offset: 0));
    expect(await controller.copySelection(), isFalse);
    expect(controller.statusMessage, isNull);

    controller.selectAll();
    expect(await controller.copySelection(), isTrue);
    expect(
      controller.document.textFor(controller.selection),
      controller.document.fullText,
    );
  });

  test('same content keeps the session and a new media id ends it', () {
    final controller = MusicLyricSelectionController();
    final primary = [_cue(1, 0, 'Hello', translation: '你好')];
    controller.begin(
      mediaId: 'song',
      primary: primary,
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
      groupId: 'p:0',
      time: Duration.zero,
      awaitingPointer: false,
    );
    final selection = controller.selection;
    controller.noteSource(
      mediaId: 'song',
      primary: [...primary],
      secondary: const [],
      splitSubtitleByLine: false,
    );
    expect(controller.contentStale, isFalse);
    expect(controller.selection, selection);

    controller.noteSource(
      mediaId: 'song',
      primary: [_cue(1, 0, 'Changed', translation: '变了')],
      secondary: const [],
      splitSubtitleByLine: false,
    );
    expect(controller.contentStale, isTrue);
    expect(controller.document.fullText, 'Hello\n你好');

    controller.reload(
      primary: [_cue(1, 0, 'Changed', translation: '变了')],
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
    );
    expect(controller.contentStale, isFalse);
    expect(controller.selection.isCollapsed, isTrue);
    expect(controller.document.fullText, contains('Changed'));

    controller.begin(
      mediaId: 'song',
      primary: primary,
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
      groupId: 'p:0',
      time: Duration.zero,
      awaitingPointer: false,
    );
    controller.noteSource(
      mediaId: 'next',
      primary: [_cue(1, 0, 'Other')],
      secondary: const [],
      splitSubtitleByLine: false,
    );
    expect(controller.isActive, isFalse);
  });

  test('back closes the text menu before leaving selection', () {
    final controller = MusicLyricSelectionController();
    controller.begin(
      mediaId: 'song',
      primary: [_cue(1, 0, 'Hello')],
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.primary,
      groupId: 'p:0',
      time: Duration.zero,
      awaitingPointer: false,
    );
    controller.setTextMenuOpen(true);
    expect(controller.handleBack(), isTrue);
    expect(controller.isActive, isTrue);
    expect(controller.textMenuOpen, isFalse);
    expect(controller.handleBack(), isTrue);
    expect(controller.isActive, isFalse);
    expect(controller.handleBack(), isFalse);
  });

  test('long documents keep every group and a middle selection', () {
    final primary = [
      for (var index = 0; index < 2000; index++)
        _cue(index, index * 1000, 'Line $index 🎵', translation: '第$index行'),
    ];
    final watch = Stopwatch()..start();
    final document = _document(primary, MusicLyricTrackDisplayMode.both);
    watch.stop();
    expect(document.groups, hasLength(2000));
    expect(document.fullText.length, greaterThan(20000));
    final middle = document.selectionForGroup('p:1000');
    expect(
      document.textFor(middle),
      document.fullText.substring(middle.start, middle.end),
    );
    expect(watch.elapsedMilliseconds, lessThan(5000));
  });

  test('playback focus highlights only the cue under the clock', () {
    final document = _document([
      _cue(1, 2000, 'Hello', translation: '你好'),
      _cue(2, 5000, 'Stay', translation: '留'),
    ], MusicLyricTrackDisplayMode.both);
    expect(document.groups[0].end, const Duration(milliseconds: 3000));
    expect(document.groups[1].end, const Duration(milliseconds: 6000));

    final playing = document.playbackFocusAt(
      const Duration(milliseconds: 2500),
    );
    expect(playing.place, MusicLyricPlaybackPlace.playing);
    expect(playing.highlightedGroupId, 'p:0');
    expect(playing.anchor.groupId, 'p:0');
    expect(playing.anchor.documentOffset, document.groups[0].documentStart);
    expect(playing.anchor.viewportFraction, 0.24);

    final before = document.playbackFocusAt(const Duration(milliseconds: 100));
    expect(before.place, MusicLyricPlaybackPlace.beforeFirst);
    expect(before.highlightedGroupId, isNull);
    expect(before.anchor.groupId, 'p:0');

    final gap = document.playbackFocusAt(const Duration(milliseconds: 4000));
    expect(gap.place, MusicLyricPlaybackPlace.between);
    expect(gap.highlightedGroupId, isNull);
    expect(gap.anchor.groupId, 'p:1');

    final after = document.playbackFocusAt(const Duration(milliseconds: 6000));
    expect(after.place, MusicLyricPlaybackPlace.afterLast);
    expect(after.highlightedGroupId, isNull);
    expect(after.anchor.groupId, 'p:1');

    final plain = document.fullText;
    final span = document.buildTextSpan(
      primaryStyle: const TextStyle(),
      secondaryStyle: const TextStyle(),
      backgroundStyle: const TextStyle(),
      romanizationStyle: const TextStyle(),
      highlightedGroupId: playing.highlightedGroupId,
    );
    expect(span.toPlainText(), plain);
    final painted = span.children!.whereType<TextSpan>().where(
      (child) =>
          child.style?.backgroundColor ==
          MusicLyricSelectionDocument.playingBackground,
    );
    expect(painted.map((child) => child.text).join(), 'Hello\n你好');
  });

  test(
    'long-press selection stays put while the viewport follows playback',
    () {
      final controller = MusicLyricSelectionController();
      controller.begin(
        mediaId: 'song',
        primary: [
          _cue(1, 0, 'Hello', translation: '你好'),
          _cue(2, 4000, 'Stay', translation: '留'),
        ],
        secondary: const [],
        splitSubtitleByLine: false,
        mode: MusicLyricTrackDisplayMode.both,
        groupId: 'p:1',
        time: const Duration(milliseconds: 200),
        awaitingPointer: false,
      );
      expect(controller.document.textFor(controller.selection), 'Stay\n留');
      expect(controller.playbackHighlightGroupId, 'p:0');
      expect(controller.anchor.groupId, 'p:0');
      expect(controller.document.fullText, 'Hello\n你好\nStay\n留');
    },
  );

  test('playback highlight follows the clock without moving the selection', () {
    final controller = MusicLyricSelectionController();
    controller.begin(
      mediaId: 'song',
      primary: [
        _cue(1, 0, 'Hello', translation: '你好'),
        _cue(2, 4000, 'Stay', translation: '留'),
      ],
      secondary: const [],
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
      groupId: 'p:1',
      time: const Duration(milliseconds: 200),
      awaitingPointer: false,
    );
    final selection = controller.selection;
    final anchor = controller.anchor;
    controller.syncPlaybackHighlight(const Duration(milliseconds: 250));
    expect(controller.playbackHighlightGroupId, 'p:0');
    expect(controller.selection, selection);
    expect(controller.anchor.groupId, anchor.groupId);
    expect(controller.anchor.documentOffset, anchor.documentOffset);

    controller.syncPlaybackHighlight(const Duration(milliseconds: 4500));
    expect(controller.playbackHighlightGroupId, 'p:1');
    expect(controller.document.textFor(controller.selection), 'Stay\n留');
    expect(controller.anchor.documentOffset, anchor.documentOffset);

    controller.syncPlaybackHighlight(const Duration(milliseconds: 2000));
    expect(controller.playbackHighlightGroupId, isNull);
    expect(controller.selection, selection);
    expect(controller.anchor.documentOffset, anchor.documentOffset);
  });
}
