import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/controllers/music_lyric_selection_controller.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';

SubtitleItem _cue(int index, String text) => SubtitleItem(
  index: index,
  startTime: Duration(seconds: index),
  endTime: Duration(seconds: index + 1),
  text: text,
);

void _begin(
  MusicLyricSelectionController controller, {
  String mediaId = 'old',
  List<SubtitleItem>? primary,
  List<SubtitleItem>? secondary,
}) => controller.begin(
  mediaId: mediaId,
  primary: primary ?? [_cue(0, 'old primary'), _cue(1, 'old next')],
  secondary: secondary ?? [_cue(0, 'old translation')],
  splitSubtitleByLine: false,
  mode: MusicLyricTrackDisplayMode.both,
  groupId: 'p:0',
  time: Duration.zero,
  awaitingPointer: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('finish releases source cues after the exiting notification', () {
    final controller = MusicLyricSelectionController();
    addTearDown(controller.dispose);
    _begin(controller);
    expect(controller.retainedSourceCueCount, 3);
    final transitions = <(MusicLyricSelectionPhase, int)>[];
    controller.addListener(() {
      transitions.add((controller.phase, controller.retainedSourceCueCount));
    });
    controller.finish();
    expect(transitions, [
      (MusicLyricSelectionPhase.exitingSelection, 3),
      (MusicLyricSelectionPhase.normal, 0),
    ]);
    expect(controller.document.isEmpty, isTrue);
    expect(controller.canCopy, isFalse);
  });

  test('cancel releases source cues and the next session uses new content', () {
    final controller = MusicLyricSelectionController();
    addTearDown(controller.dispose);
    _begin(controller);
    controller.cancel();
    expect(controller.retainedSourceCueCount, 0);
    expect(controller.document.isEmpty, isTrue);
    _begin(
      controller,
      mediaId: 'new',
      primary: [_cue(0, 'new text')],
      secondary: const [],
    );
    expect(controller.retainedSourceCueCount, 1);
    expect(controller.document.fullText, 'new text');
  });

  test('changing media cancels and releases the previous frozen track', () {
    final controller = MusicLyricSelectionController();
    addTearDown(controller.dispose);
    _begin(controller);
    controller.noteSource(
      mediaId: 'new',
      primary: [_cue(0, 'next track')],
      secondary: const [],
      splitSubtitleByLine: false,
    );
    expect(controller.isActive, isFalse);
    expect(controller.retainedSourceCueCount, 0);
    expect(controller.document.isEmpty, isTrue);
  });

  test('active streaming snapshot remains frozen until the session ends', () {
    final controller = MusicLyricSelectionController();
    addTearDown(controller.dispose);
    final buffer = SubtitleCueBuffer()..addAll([_cue(0, 'frozen text')]);
    _begin(controller, primary: buffer.snapshot, secondary: const []);
    buffer.addAll([_cue(1, 'newly appended text')]);
    controller.noteSource(
      mediaId: 'old',
      primary: buffer.snapshot,
      secondary: const [],
      splitSubtitleByLine: false,
    );
    expect(controller.contentStale, isTrue);
    expect(controller.retainedSourceCueCount, 1);
    expect(controller.document.fullText, 'frozen text');
    controller.switchMode(MusicLyricTrackDisplayMode.primary);
    expect(controller.document.fullText, 'frozen text');
    controller.finish();
    expect(controller.retainedSourceCueCount, 0);
  });

  test('back closes the text menu before releasing the selection snapshot', () {
    final controller = MusicLyricSelectionController();
    addTearDown(controller.dispose);
    _begin(controller);
    controller.setTextMenuOpen(true);
    expect(controller.handleBack(), isTrue);
    expect(controller.isActive, isTrue);
    expect(controller.retainedSourceCueCount, 3);
    expect(controller.handleBack(), isTrue);
    expect(controller.isActive, isFalse);
    expect(controller.retainedSourceCueCount, 0);
  });

  test(
    'disposing an active controller releases its document and cue sources',
    () {
      final controller = MusicLyricSelectionController();
      _begin(controller);
      controller.dispose();
      expect(controller.retainedSourceCueCount, 0);
      expect(controller.document.isEmpty, isTrue);
    },
  );
}
