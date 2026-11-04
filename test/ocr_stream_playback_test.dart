import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/subtitle_stream_source.dart';
import 'package:video_player_app/services/transcription_manager.dart';

class _Source extends TranscriptionManager {
  _Source(this.key);
  final String key;
  final events = StreamController<SubtitleStreamUpdate>.broadcast(sync: true);
  final starts = StreamController<SubtitleGenerationStart>.broadcast(
    sync: true,
  );
  SubtitleStreamUpdate? latest;
  bool suppressed = false;
  int stops = 0, resumes = 0;
  @override
  Stream<SubtitleStreamUpdate> get subtitleUpdates => events.stream;
  @override
  Stream<SubtitleGenerationStart> get subtitleGenerationStarts => starts.stream;
  @override
  Iterable<SubtitleStreamUpdate> get subtitleStreams => [?latest];
  @override
  void preserveSubtitleSelection(String path, {String? videoId}) {
    suppressed = true;
  }

  @override
  bool subtitleSelectionOverridden(String mediaKey) =>
      mediaKey == key && suppressed;
  @override
  SubtitleStreamUpdate? streamForPath(String path) =>
      latest?.paths.contains(path) == true ? latest : null;
  @override
  bool hasSubtitleStreamForVideo(String path, {String? videoId}) =>
      latest != null;
  @override
  Future<void> stopStreamForPath(String path) async {
    stops++;
  }

  @override
  void resumeStreamForPath(String path) {
    resumes++;
  }

  void emit(SubtitleStreamUpdate update) {
    latest = update;
    events.add(update);
    subtitleFilesRevision.value++;
  }

  @override
  void dispose() {
    unawaited(events.close());
    unawaited(starts.close());
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Source asr, ocr;
  late SubtitleStreamHub hub;
  late MediaPlaybackService playback;
  late SubtitleCueBuffer chinese, english;
  setUp(() {
    asr = _Source('id:media');
    ocr = _Source('ocr:run:0');
    hub = SubtitleStreamHub([asr, ocr]);
    playback = MediaPlaybackService.forTesting();
    playback.debugSeedCurrentItem(
      VideoItem(
        id: 'media',
        path: '/media.mp4',
        title: 'Media',
        durationMs: 60000,
        lastUpdated: 0,
      ),
    );
    playback.bindSubtitleStreams(hub);
    chinese = SubtitleCueBuffer();
    english = SubtitleCueBuffer();
    ocr.starts.add((mediaKey: ocr.key, runId: 'run:0'));
  });
  tearDown(() {
    playback.dispose();
    hub.dispose();
    asr.dispose();
    ocr.dispose();
  });

  test(
    'file registration changes from either source reach the shared list',
    () {
      final before = hub.subtitleFilesRevision.value;
      asr.subtitleFilesRevision.value++;
      ocr.subtitleFilesRevision.value++;
      expect(hub.subtitleFilesRevision.value, before + 2);
    },
  );

  SubtitleItem cue(int index, String text) => SubtitleItem(
    index: index,
    text: text,
    startTime: Duration(seconds: index),
    endTime: Duration(seconds: index + 1),
  );
  SubtitleStreamUpdate update({
    SubtitleStreamPhase phase = SubtitleStreamPhase.generating,
  }) => SubtitleStreamUpdate(
    generationId: 'run:0',
    mediaKey: ocr.key,
    videoId: 'media',
    videoPath: '/media.mp4',
    revision: chinese.snapshot.length + english.snapshot.length,
    primaryPath: '/中文.srt',
    secondaryPath: '/English.srt',
    primary: chinese.snapshot,
    secondary: english.snapshot,
    addedPrimary: const [],
    addedSecondary: const [],
    primaryBytes: 100,
    secondaryBytes: 100,
    processedThrough: const Duration(seconds: 20),
    phase: phase,
    autoSelectSuppressed: ocr.suppressed,
  );
  Future<void> flush() =>
      Future<void>.delayed(const Duration(milliseconds: 280));

  test(
    'English may arrive first and unequal regional batches retain both tracks',
    () async {
      english.addAll([cue(1, 'English')]);
      ocr.emit(update());
      await flush();
      expect(playback.subtitlePaths, ['/中文.srt', '/English.srt']);
      expect(playback.subtitles, isEmpty);
      expect(playback.secondarySubtitles.single.text, 'English');
      chinese.addAll([cue(1, '中文'), cue(2, '中文二')]);
      ocr.emit(update());
      await flush();
      expect(playback.subtitles.length, 2);
      expect(playback.secondarySubtitles.length, 1);
      expect(playback.subtitleWasAppend, isTrue);
      expect(hub.streamForPath('/English.srt'), isNotNull);
      await hub.stopStreamForPath('/English.srt');
      hub.resumeStreamForPath('/English.srt');
      expect(ocr.stops, 1);
      expect(ocr.resumes, 1);
      expect(asr.stops, 0);
    },
  );

  test(
    'a manual choice survives late OCR publication and final reconciliation',
    () async {
      playback.setSubtitleState(
        paths: ['/manual.srt'],
        primary: [cue(1, 'Manual')],
        secondary: const [],
      );
      chinese.addAll([cue(1, 'OCR')]);
      ocr.emit(update());
      await flush();
      expect(playback.subtitlePaths, ['/manual.srt']);
      chinese = SubtitleCueBuffer()..addAll([cue(1, 'Final OCR')]);
      ocr.emit(update(phase: SubtitleStreamPhase.complete));
      expect(playback.subtitles.single.text, 'Manual');
      expect(hub.subtitleSelectionOverridden(ocr.key), isTrue);
    },
  );

  test(
    'final cleanup replaces an already selected prefix without changing track selection',
    () async {
      chinese.addAll([cue(1, '水印'), cue(2, '字幕')]);
      ocr.emit(update());
      await flush();
      chinese = SubtitleCueBuffer()..addAll([cue(1, '字幕')]);
      ocr.emit(update(phase: SubtitleStreamPhase.complete));
      expect(playback.subtitlePaths, ['/中文.srt', '/English.srt']);
      expect(playback.subtitles.map((cue) => cue.text), ['字幕']);
      expect(playback.subtitleWasAppend, isFalse);
    },
  );

  test(
    'an unselected extra OCR region cannot swallow the selected pair update',
    () async {
      chinese.addAll([cue(1, '区域一')]);
      ocr.emit(update());
      ocr.emit(
        SubtitleStreamUpdate(
          generationId: 'run:2',
          mediaKey: 'ocr:run:2',
          videoId: 'media',
          videoPath: '/media.mp4',
          revision: 1,
          primaryPath: '/third.srt',
          secondaryPath: null,
          primary: (SubtitleCueBuffer()..addAll([cue(1, '区域三')])).snapshot,
          secondary: SubtitleCueBuffer().snapshot,
          addedPrimary: const [],
          addedSecondary: const [],
          primaryBytes: 10,
          secondaryBytes: 0,
          processedThrough: const Duration(seconds: 20),
          phase: SubtitleStreamPhase.generating,
          autoSelectSuppressed: true,
        ),
      );
      await flush();
      expect(playback.subtitlePaths, ['/中文.srt', '/English.srt']);
      expect(playback.subtitles.single.text, '区域一');
    },
  );
}
