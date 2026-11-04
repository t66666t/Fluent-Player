import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/music_lyric_display_mode.dart';
import '../models/music_lyric_selection_document.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';
import '../services/music_lyric_content_resolver.dart';

enum MusicLyricSelectionPhase {
  normal,
  enteringSelection,
  selecting,
  exitingSelection,
}

/// A long-press or explicit "select text" request. The group id is resolved
/// by the stable lyric parent, not by a row State that animation can dispose.
class MusicLyricSelectionRequest {
  final int displayIndex;
  final String groupId;
  final Duration time;

  /// True while the finger or button that opened selection is still down.
  /// The text field ignores that pointer until it is released.
  final bool awaitingPointer;

  const MusicLyricSelectionRequest({
    required this.displayIndex,
    required this.groupId,
    required this.time,
    this.awaitingPointer = false,
  });
}

/// Owns the selection session, the frozen lyric snapshot and the return
/// stack (text menu, then selection, then the player page).
class MusicLyricSelectionController extends ChangeNotifier {
  MusicLyricSelectionPhase phase = MusicLyricSelectionPhase.normal;
  MusicLyricSelectionDocument document = MusicLyricSelectionDocument.empty;
  TextSelection selection = const TextSelection.collapsed(offset: 0);
  MusicLyricReadingAnchor anchor = MusicLyricReadingAnchor.top;
  Duration playbackTime = Duration.zero;
  String? playbackHighlightGroupId;
  bool awaitingPointerRelease = false;
  bool contentStale = false;
  bool textMenuOpen = false;
  String? statusMessage;
  int generation = 0;

  String mediaId = '';
  String sourceVersion = '';
  bool splitSubtitleByLine = false;
  List<SubtitleItem> _frozenPrimary = const [];
  List<SubtitleItem> _frozenSecondary = const [];
  MusicLyricTrackDisplayMode mode = MusicLyricTrackDisplayMode.both;

  bool get isActive =>
      phase == MusicLyricSelectionPhase.enteringSelection ||
      phase == MusicLyricSelectionPhase.selecting ||
      phase == MusicLyricSelectionPhase.exitingSelection;

  bool get canCopy => !selection.isCollapsed && document.fullText.isNotEmpty;

  @visibleForTesting
  int get retainedSourceCueCount =>
      _frozenPrimary.length + _frozenSecondary.length;

  /// Freezes the current cues and waits until the original pointer is gone
  /// before the text field is allowed to take a drag.
  void begin({
    required String mediaId,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    required bool splitSubtitleByLine,
    required MusicLyricTrackDisplayMode mode,
    required String? groupId,
    required Duration time,
    required bool awaitingPointer,
  }) {
    generation++;
    this.mediaId = mediaId;
    this.splitSubtitleByLine = splitSubtitleByLine;
    this.mode = mode;
    _frozenPrimary = _freeze(primary);
    _frozenSecondary = _freeze(secondary);
    sourceVersion = musicLyricSourceVersion(
      primary: _frozenPrimary,
      secondary: _frozenSecondary,
      splitSubtitleByLine: splitSubtitleByLine,
    );
    document = _documentFor(mode);
    playbackTime = time;
    final pressed = groupId ?? document.initialGroupId(playing: time);
    selection = pressed == null
        ? const TextSelection.collapsed(offset: 0)
        : document.selectionForGroup(pressed);
    final focus = document.playbackFocusAt(time);
    playbackHighlightGroupId = focus.highlightedGroupId;
    anchor = focus.anchor;
    awaitingPointerRelease = awaitingPointer;
    contentStale = false;
    textMenuOpen = false;
    statusMessage = null;
    phase = awaitingPointer
        ? MusicLyricSelectionPhase.enteringSelection
        : MusicLyricSelectionPhase.selecting;
    notifyListeners();
  }

  /// Moves the playing-line wash with the clock. The entry scroll anchor and
  /// the text selection stay where they were.
  void syncPlaybackHighlight(Duration time) {
    if (!isActive || document.isEmpty) return;
    playbackTime = time;
    final next = document.playbackFocusAt(time).highlightedGroupId;
    if (next == playbackHighlightGroupId) return;
    playbackHighlightGroupId = next;
    notifyListeners();
  }

  void pointerReleased() {
    if (phase != MusicLyricSelectionPhase.enteringSelection) return;
    awaitingPointerRelease = false;
    phase = MusicLyricSelectionPhase.selecting;
    notifyListeners();
  }

  void updateSelection(TextSelection next) {
    if (!isActive) return;
    final snapped = document.snap(next);
    if (snapped == selection) return;
    selection = snapped;
    notifyListeners();
  }

  void selectAll() {
    if (document.isEmpty) return;
    selection = TextSelection(
      baseOffset: 0,
      extentOffset: document.fullText.length,
    );
    notifyListeners();
  }

  /// Writes the selected substring once. An empty range does not touch the
  /// clipboard. Returns false when the platform rejects the write.
  Future<bool> copySelection() async {
    final text = document.textFor(selection);
    if (text.isEmpty) return false;
    statusMessage = '已复制';
    notifyListeners();
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } catch (_) {
      statusMessage = '复制失败，请重试';
      notifyListeners();
      return false;
    }
  }

  void clearStatus() {
    if (statusMessage == null) return;
    statusMessage = null;
    notifyListeners();
  }

  void setTextMenuOpen(bool open) {
    if (textMenuOpen == open) return;
    textMenuOpen = open;
    notifyListeners();
  }

  /// Switches the frozen snapshot to another role. The preference write is
  /// the caller's job; this method only updates the open document.
  void switchMode(MusicLyricTrackDisplayMode next) {
    if (!isActive || next == mode) return;
    final previous = document;
    final previousSelection = selection;
    mode = next;
    document = _documentFor(next);
    final restored = previous.restoreSelection(
      selection: previousSelection,
      next: document,
    );
    selection = restored.selection;
    anchor = restored.anchor;
    playbackHighlightGroupId = document
        .playbackFocusAt(playbackTime)
        .highlightedGroupId;
    statusMessage = restored.message;
    notifyListeners();
  }

  void noteSource({
    required String mediaId,
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    required bool splitSubtitleByLine,
  }) {
    if (!isActive) return;
    if (mediaId != this.mediaId) {
      cancel();
      return;
    }
    final version = musicLyricSourceVersion(
      primary: primary,
      secondary: secondary,
      splitSubtitleByLine: splitSubtitleByLine,
    );
    if (!contentStale &&
        (version != sourceVersion ||
            primary.length != _frozenPrimary.length ||
            secondary.length != _frozenSecondary.length)) {
      contentStale = true;
      notifyListeners();
    }
  }

  void reload({
    required List<SubtitleItem> primary,
    required List<SubtitleItem> secondary,
    required bool splitSubtitleByLine,
    required MusicLyricTrackDisplayMode mode,
  }) {
    if (!isActive) return;
    _frozenPrimary = _freeze(primary);
    _frozenSecondary = _freeze(secondary);
    this.splitSubtitleByLine = splitSubtitleByLine;
    this.mode = mode;
    sourceVersion = musicLyricSourceVersion(
      primary: _frozenPrimary,
      secondary: _frozenSecondary,
      splitSubtitleByLine: splitSubtitleByLine,
    );
    document = _documentFor(mode);
    selection = const TextSelection.collapsed(offset: 0);
    final focus = document.playbackFocusAt(playbackTime);
    playbackHighlightGroupId = focus.highlightedGroupId;
    anchor = focus.anchor;
    contentStale = false;
    statusMessage = null;
    notifyListeners();
  }

  /// Text menu first, selection session second. The page itself is third.
  bool handleBack() {
    if (!isActive) return false;
    if (textMenuOpen) {
      textMenuOpen = false;
      notifyListeners();
      return true;
    }
    finish();
    return true;
  }

  void finish() {
    if (!isActive) return;
    phase = MusicLyricSelectionPhase.exitingSelection;
    textMenuOpen = false;
    notifyListeners();
    generation++;
    phase = MusicLyricSelectionPhase.normal;
    awaitingPointerRelease = false;
    _releaseFrozenSnapshot();
    selection = const TextSelection.collapsed(offset: 0);
    playbackHighlightGroupId = null;
    contentStale = false;
    statusMessage = null;
    notifyListeners();
  }

  void cancel() {
    generation++;
    phase = MusicLyricSelectionPhase.normal;
    awaitingPointerRelease = false;
    textMenuOpen = false;
    contentStale = false;
    _releaseFrozenSnapshot();
    selection = const TextSelection.collapsed(offset: 0);
    playbackHighlightGroupId = null;
    statusMessage = null;
    notifyListeners();
  }

  MusicLyricSelectionDocument _documentFor(MusicLyricTrackDisplayMode next) {
    final projection = resolveMusicLyricProjection(
      mediaId: mediaId,
      primary: _frozenPrimary,
      secondary: _frozenSecondary,
      splitSubtitleByLine: splitSubtitleByLine,
      mode: next,
    );
    return MusicLyricSelectionDocument.fromProjection(projection);
  }

  void _releaseFrozenSnapshot() {
    // No inactive-session path reuses these sources: begin() captures the
    // current tracks again. A streaming view also retains its entire owner,
    // including later appends, until this reference is released.
    _frozenPrimary = const [];
    _frozenSecondary = const [];
    document = MusicLyricSelectionDocument.empty;
  }

  @override
  void dispose() {
    _releaseFrozenSnapshot();
    super.dispose();
  }

  // A streaming snapshot already has an immutable length. Keeping it preserves
  // cue identities without copying or hashing the whole transcript on entry.
  static List<SubtitleItem> _freeze(List<SubtitleItem> cues) =>
      cues is SubtitleCueSnapshot
      ? cues
      : List<SubtitleItem>.unmodifiable(cues);
}
