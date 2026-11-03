import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

class _ReadCountingList extends ListBase<SubtitleItem> {
  _ReadCountingList(this.source, this.onRead);
  final List<SubtitleItem> source;
  final void Function() onRead;

  @override
  int get length => source.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  SubtitleItem operator [](int index) {
    onRead();
    return source[index];
  }

  @override
  void operator []=(int index, SubtitleItem value) =>
      throw UnsupportedError('immutable');
}

class _Playback extends MediaPlaybackService {
  _Playback() : super.forTesting();
  int subtitleReads = 0;

  @override
  List<SubtitleItem> get subtitles =>
      _ReadCountingList(super.subtitles, () => subtitleReads++);
}

SubtitleItem _cue(int index, {String? text}) => SubtitleItem(
  index: index,
  startTime: Duration(seconds: index * 3),
  endTime: Duration(seconds: index * 3 + 1),
  text: text ?? 'Cue $index',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('notification position samples reuse the long transcript index', () {
    final playback = _Playback();
    addTearDown(playback.dispose);
    playback.setSubtitleState(
      paths: const ['long.srt'],
      primary: List.generate(10000, _cue),
      secondary: const [],
    );
    final session = SystemMediaSessionService.instance;

    for (var index = 5000; index < 5100; index++) {
      // The intentional gap-filling rule also applies to system metadata.
      expect(
        session.resolveSubtitleTextForTesting(
          playbackService: playback,
          position: Duration(seconds: index * 3 + 2),
        ),
        'Cue $index',
      );
      expect(
        playback.nextSubtitleBoundaryAfter(Duration(seconds: index * 3 + 2)),
        Duration(seconds: (index + 1) * 3),
      );
    }
    expect(playback.subtitleReads, 0);
  });

  test('notification lookup follows same-size replacement and clearing', () {
    final playback = _Playback();
    addTearDown(playback.dispose);
    final session = SystemMediaSessionService.instance;
    String? text() => session.resolveSubtitleTextForTesting(
      playbackService: playback,
      position: const Duration(seconds: 3),
    );

    for (final value in ['First', 'Edited']) {
      playback.setSubtitleState(
        paths: const ['same.srt'],
        primary: [_cue(1, text: value)],
        secondary: const [],
      );
      expect(text(), value);
      expect(
        playback.nextSubtitleBoundaryAfter(const Duration(seconds: 3)),
        const Duration(seconds: 4),
      );
    }
    playback.clearSubtitleState();
    expect(text(), isNull);
    expect(
      playback.nextSubtitleBoundaryAfter(const Duration(seconds: 3)),
      isNull,
    );
  });
}
