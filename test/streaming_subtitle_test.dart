import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/controllers/music_lyric_selection_controller.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/streaming_subtitle_assembler.dart';
import 'package:video_player_app/features/model_center/local_asr_boundary.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/music_lyric_display_mode.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/music_lyric_content_resolver.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_timeline_resolver.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';

SubtitleItem cue(int id, {String? text}) => SubtitleItem(
  index: id,
  startTime: Duration(seconds: id * 3),
  endTime: Duration(seconds: id * 3 + 2),
  text: text ?? 'Sentence $id.',
);

class _Translator extends SubtitleTranslationService {
  bool fail = false;
  bool block = false;
  final pending = <Completer<void>>[];
  final received = <List<int>>[];
  final sourceTexts = <List<String>>[];
  final contexts = <String>[];
  String suffix = '';
  @override
  Future<List<String>> translateCueBatch({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    void Function(int, String)? onTranslated,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    ModelJobSpec? localSpecification,
    ModelCenterService? modelCenter,
    LocalTranslationSession? localSession,
    InferenceReservation? reservation,
    String precedingContext = '',
    String checkpointScope = '',
    Future<void>? cancelSignal,
    SmartTranslationPolicy? smartPolicy,
  }) async {
    received.add(items.map((item) => item.index).toList());
    sourceTexts.add(items.map((item) => item.text).toList());
    contexts.add(precedingContext);
    if (block) {
      final gate = Completer<void>();
      pending.add(gate);
      await gate.future;
    }
    if (fail) {
      onTranslated?.call(0, '成功译文 ${items.first.index}');
      throw StateError('second line failed');
    }
    return items.map((item) => '成功译文 ${item.index}$suffix').toList();
  }
}

class _FaultJournal implements File {
  _FaultJournal(this.file, {required this.wholeRecord});
  final File file;
  final bool wholeRecord;
  bool fail = false;
  @override
  String get path => file.path;
  @override
  Directory get parent => file.parent;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      file.open(mode: mode);
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    if (!fail) return file.writeAsBytes(bytes, mode: mode, flush: flush);
    fail = false;
    await file.writeAsBytes(
      wholeRecord ? bytes : bytes.sublist(0, bytes.length ~/ 2),
      mode: mode,
      flush: true,
    );
    throw FileSystemException('simulated write/flush failure', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StreamingSubtitleStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('streaming-cues-');
    store = await StreamingSubtitleStore.create(
      File(p.join(root.path, 'stream.jsonl')),
      {
        'generationId': 'generation',
        'primaryPath': p.join(root.path, 'original.srt'),
        'secondaryPath': p.join(root.path, 'translated.srt'),
      },
    );
  });
  tearDown(() async {
    await store.drained;
    await root.delete(recursive: true);
  });

  for (final wholeRecord in [false, true]) {
    test(
      'same-process resume repairs ${wholeRecord ? 'unacknowledged' : 'partial'} journal writes',
      () async {
        final journal = _FaultJournal(store.journal, wholeRecord: wholeRecord);
        store = await StreamingSubtitleStore.open(journal);
        await store.append(
          [cue(1)],
          [cue(1, text: '译文一')],
          const Duration(seconds: 30),
        );
        final primaryBytes = store.primaryBytes,
            secondaryBytes = store.secondaryBytes;
        journal.fail = true;
        await expectLater(
          store.append(
            [cue(2)],
            [cue(2, text: '译文二')],
            const Duration(seconds: 58),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(store.primary.snapshot, hasLength(1));
        expect(await File(store.primaryPath).length(), primaryBytes);
        expect(await File(store.secondaryPath!).length(), secondaryBytes);
        await store.setPhase(SubtitleStreamPhase.failed);
        await store.recoverOutputs();
        await store.append(
          [cue(2)],
          [cue(2, text: '译文二')],
          const Duration(seconds: 58),
        );
        final restored = await StreamingSubtitleStore.open(File(journal.path));
        expect(restored.primary.snapshot.map((cue) => cue.index), [1, 2]);
        expect(restored.secondary.snapshot.map((cue) => cue.text), [
          '译文一',
          '译文二',
        ]);
        expect(restored.primaryBytes, await File(store.primaryPath).length());
      },
    );
  }

  test('snapshots are immutable without copying an existing prefix', () {
    final buffer = SubtitleCueBuffer()..addAll([cue(1)]);
    final first = buffer.snapshot;
    buffer.addAll(List.generate(10000, (i) => cue(i + 2)));
    final next = buffer.snapshot;
    expect(first, hasLength(1));
    expect(next, hasLength(10001));
    expect(identical(first.first, next.first), isTrue);
    expect(isSubtitleAppend(first, next), isTrue);
    expect(() => next[0] = cue(5), throwsUnsupportedError);
    expect(() => first[1], throwsRangeError);
  });

  for (final mode in [
    SubtitlePunctuation.removeAll,
    SubtitlePunctuation.removeTrailingFullStopsAndCommas,
  ]) {
    test(
      'paired output is cleaned after translation and raw context survives restart: $mode',
      () async {
        final translator = _Translator()..suffix = '，';
        final original = cue(1, text: 'Hello, world,').copyWith(
          timedSpans: const [
            SubtitleTimedSpan(
              textStart: 7,
              textEnd: 12,
              startTime: Duration(seconds: 3),
              endTime: Duration(seconds: 4),
            ),
          ],
        );
        final published = <List<SubtitleItem>>[];
        LocalTranscriptionStream session() => LocalTranscriptionStream(
          openStore: () async => store,
          choice: const TranscriptTranslateChoice.automatic(),
          center: ModelCenterService(),
          translator: translator,
          punctuation: mode,
          cancelSignal: Completer<void>().future,
          checkCancelled: () {},
          onCommitted: (_, primary, secondary) async {
            published.add(primary);
            published.add(secondary);
          },
          onActivity: (_, _) {},
          onFailure: () {},
        );
        final first = session();
        await first.accept(
          StableAsrBatch([original], const Duration(seconds: 30), null),
        );
        await first.drain();
        await first.close();
        final expectedFirst = mode == SubtitlePunctuation.removeAll
            ? 'Hello world'
            : 'Hello, world';
        expect(store.primary.snapshot.single.text, expectedFirst);
        expect(store.secondary.snapshot.single.text, '成功译文 1');
        expect(published.map((batch) => batch.single.text), [
          expectedFirst,
          '成功译文 1',
        ]);
        final span = store.primary.snapshot.single.timedSpans.single;
        expect(
          store.primary.snapshot.single.text.substring(
            span.textStart,
            span.textEnd,
          ),
          'world',
        );
        expect(
          await File(store.primaryPath).readAsString(),
          contains('$expectedFirst\n'),
        );
        store = await StreamingSubtitleStore.open(store.journal);
        final resumed = session();
        await resumed.accept(
          StableAsrBatch(
            [original, cue(2, text: 'Next, sentence!')],
            const Duration(seconds: 58),
            null,
          ),
        );
        await resumed.drain();
        await resumed.close();
        expect(translator.sourceTexts, [
          ['Hello, world,'],
          ['Next, sentence!'],
        ]);
        expect(translator.contexts, ['', 'Hello, world,']);
        expect(store.primary.snapshot.map((c) => c.text), [
          expectedFirst,
          mode == SubtitlePunctuation.removeAll
              ? 'Next sentence'
              : 'Next, sentence!',
        ]);
        expect(store.primary.snapshot.map((c) => c.index), [1, 2]);
      },
    );
  }

  test(
    'streaming selection keeps its document, range and anchor on append',
    () {
      final source = SubtitleCueBuffer()..addAll([cue(1)]);
      final controller = MusicLyricSelectionController();
      controller.begin(
        mediaId: 'media',
        primary: source.snapshot,
        secondary: const [],
        splitSubtitleByLine: false,
        mode: MusicLyricTrackDisplayMode.primary,
        groupId: 'p:0',
        time: const Duration(seconds: 3),
        awaitingPointer: false,
      );
      final document = controller.document;
      final selection = controller.selection;
      final anchor = controller.anchor;
      controller.noteSource(
        mediaId: 'media',
        primary: source.snapshot,
        secondary: const [],
        splitSubtitleByLine: false,
      );
      expect(controller.contentStale, isFalse);
      source.addAll([cue(2)]);
      controller.noteSource(
        mediaId: 'media',
        primary: source.snapshot,
        secondary: const [],
        splitSubtitleByLine: false,
      );
      expect(controller.contentStale, isTrue);
      expect(identical(controller.document, document), isTrue);
      expect(controller.selection, selection);
      expect(controller.anchor, same(anchor));
      expect(controller.document.textFor(selection), 'Sentence 1.');
      controller.dispose();
    },
  );

  test(
    'paired append grows files and restores timings and partial translations',
    () async {
      final first = cue(1).copyWith(
        timedSpans: [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 8,
            startTime: const Duration(seconds: 3),
            endTime: const Duration(seconds: 4),
          ),
        ],
      );
      await store.direction('en', 'zh-CN');
      await store.append(
        [first],
        [cue(1, text: '第一句')],
        const Duration(seconds: 30),
      );
      final bytes = store.primaryBytes;
      await store.rememberTranslations({2: '第二句'});
      await store.append(
        [cue(2)],
        [cue(2, text: '第二句')],
        const Duration(seconds: 58),
      );
      expect(store.primaryBytes, greaterThan(bytes));
      expect(await File(store.primaryPath).length(), store.primaryBytes);
      final restored = await StreamingSubtitleStore.open(store.journal);
      expect(restored.primary.snapshot, hasLength(2));
      expect(restored.primary.snapshot.first.timedSpans, hasLength(1));
      expect(restored.secondary.snapshot.last.text, '第二句');
      expect(restored.pendingTranslations, isEmpty);
      expect(restored.targetLanguage, 'zh-CN');
    },
  );

  test(
    'recovery trims only unfinished suffixes and can rebuild a deleted SRT',
    () async {
      await store.append(
        [cue(1)],
        [cue(1, text: '译文')],
        const Duration(seconds: 30),
      );
      await File(
        store.primaryPath,
      ).writeAsString('uncommitted', mode: FileMode.append);
      await store.journal.writeAsString('{"type":', mode: FileMode.append);
      var restored = await StreamingSubtitleStore.open(store.journal);
      expect(await File(restored.primaryPath).length(), restored.primaryBytes);
      await File(restored.secondaryPath!).delete();
      restored = await StreamingSubtitleStore.open(store.journal);
      expect(
        await File(restored.secondaryPath!).readAsString(),
        contains('译文'),
      );
      await restored.append(
        [cue(2)],
        [cue(2, text: '下一句')],
        const Duration(seconds: 58),
      );
      expect(
        (await StreamingSubtitleStore.open(store.journal)).primary.snapshot,
        hasLength(2),
      );
    },
  );

  test(
    'a missing translation cannot be committed or advance the prefix',
    () async {
      await expectLater(
        store.append([cue(1)], [], const Duration(seconds: 30)),
        throwsStateError,
      );
      expect(store.primaryBytes, 0);
      expect(await File(store.primaryPath).length(), 0);
    },
  );

  test(
    'translation failure retains successful rows and resumes only missing rows',
    () async {
      final translator = _Translator()..fail = true;
      var emitted = 0;
      LocalTranscriptionStream session() => LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice.automatic(),
        center: ModelCenterService(),
        translator: translator,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, _, _) async {
          emitted++;
        },
        onActivity: (_, _) {},
        onFailure: () {},
      );
      var stream = session();
      await stream.accept(
        StableAsrBatch([cue(1), cue(2)], const Duration(seconds: 30), null),
      );
      await expectLater(stream.drain(), throwsStateError);
      await stream.close();
      expect(emitted, 0);
      expect(store.primary.snapshot, isEmpty);
      expect(store.pendingTranslations, {1: '成功译文 1'});
      translator.fail = false;
      stream = session();
      await stream.accept(
        StableAsrBatch([cue(1), cue(2)], const Duration(seconds: 30), null),
      );
      await stream.drain();
      await stream.close();
      expect(translator.received, [
        [1, 2],
        [2],
      ]);
      expect(store.primary.snapshot, hasLength(2));
      expect(store.secondary.snapshot, hasLength(2));
      expect(emitted, 1);
      stream = session();
      await stream.accept(
        StableAsrBatch([cue(1), cue(2)], const Duration(seconds: 30), null),
      );
      await stream.drain();
      await stream.close();
      expect(
        emitted,
        1,
        reason: 'replayed ASR checkpoints must not duplicate published cues',
      );
    },
  );

  test(
    'a borrowed native reservation completes without reacquiring its own lock',
    () async {
      final scheduler = InferenceScheduler();
      InferenceReservation? expired;
      await scheduler
          .run(() async {
            expired = scheduler.currentReservation;
            await scheduler.run(() async {
              expect(scheduler.waiting, 1);
            }, reservation: expired);
          })
          .timeout(const Duration(seconds: 1));
      expect(scheduler.busy, isFalse);
      await expectLater(
        scheduler.run(() async {}, reservation: expired),
        throwsStateError,
      );
    },
  );

  test(
    'network backpressure blocks recognition and a failed batch blocks later publication',
    () async {
      final translator = _Translator()..block = true;
      var aborted = false;
      final published = <int>[];
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice(
          enabled: true,
          provider: SubtitleTranslateProvider.ai,
          direction: TranscriptTranslateDirection.auto,
          aiOptions: AiSubtitleTranslationSettings.defaults,
        ),
        center: ModelCenterService(),
        translator: translator,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, cues, _) async => published.add(cues.first.index),
        onActivity: (_, _) {},
        onFailure: () => aborted = true,
      );
      Future<void> started(int count) async {
        while (translator.pending.length < count) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      await stream.accept(
        StableAsrBatch([cue(1)], const Duration(seconds: 30), null),
      );
      await started(1);
      var secondAccepted = false;
      final second = stream
          .accept(StableAsrBatch([cue(2)], const Duration(seconds: 58), null))
          .then((_) => secondAccepted = true);
      await Future<void>.delayed(Duration.zero);
      expect(secondAccepted, isFalse);
      expect(translator.received, [
        [1],
      ]);
      translator.pending[0].complete();
      await second;
      await started(2);
      final third = stream.accept(
        StableAsrBatch([cue(3)], const Duration(seconds: 80), null),
      );
      final failed = expectLater(third, throwsStateError);
      translator.fail = true;
      translator.pending[1].complete();
      await failed;
      await expectLater(stream.drain(), throwsStateError);
      await stream.close();
      expect(aborted, isTrue);
      expect(published, [1]);
      expect(translator.received, [
        [1],
        [2],
      ]);
      expect(store.primary.snapshot, hasLength(1));
      expect(store.secondary.snapshot, hasLength(1));
    },
  );

  test(
    'native pipeline owns the backlog while AI network translation awaits paired commit',
    () async {
      final translator = _Translator()..block = true;
      final published = <int>[];
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice(
          enabled: true,
          provider: SubtitleTranslateProvider.ai,
          direction: TranscriptTranslateDirection.auto,
          aiOptions: AiSubtitleTranslationSettings.defaults,
        ),
        center: ModelCenterService(),
        translator: translator,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, cues, _) async => published.add(cues.first.index),
        onActivity: (_, _) {},
        onFailure: () {},
      );
      var accepted = false;
      final first = stream
          .accept(
            StableAsrBatch(
              [cue(1)],
              const Duration(seconds: 30),
              null,
              nativePipeline: true,
            ),
          )
          .then((_) => accepted = true);
      while (translator.pending.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(accepted, isFalse);
      expect(store.primary.snapshot, isEmpty);
      expect(store.secondary.snapshot, isEmpty);
      translator.pending.single.complete();
      await first;
      expect(published, [1]);
      translator.block = false;
      await stream.accept(
        StableAsrBatch(
          [cue(2)],
          const Duration(seconds: 58),
          null,
          nativePipeline: true,
        ),
      );
      await stream.drain();
      await stream.close();
      expect(translator.contexts, ['', 'Sentence 1.']);
      expect(published, [1, 2]);
      expect(store.primary.snapshot, hasLength(2));
      expect(store.secondary.snapshot, hasLength(2));
    },
  );

  for (final provider in SubtitleTranslateProvider.values) {
    test('transcription only never calls the $provider translator', () async {
      store = await StreamingSubtitleStore.create(
        File(p.join(root.path, 'only-source.jsonl')),
        {
          'generationId': 'only-source',
          'primaryPath': p.join(root.path, 'only-source.srt'),
        },
      );
      final translator = _Translator()..fail = true;
      var commits = 0;
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: TranscriptTranslateChoice(
          enabled: false,
          provider: provider,
          direction: TranscriptTranslateDirection.auto,
          aiOptions: AiSubtitleTranslationSettings.defaults,
        ),
        center: ModelCenterService(),
        translator: translator,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, source, translated) async {
          expect(source, hasLength(2));
          expect(translated, isEmpty);
          commits++;
        },
        onActivity: (_, _) => fail('transcription must not start translation'),
        onFailure: () => fail('transcription must not fail on translation'),
      );
      await stream.accept(
        StableAsrBatch(
          [cue(1, text: '咱还能谈谈吗？'), cue(2, text: '接着说。')],
          const Duration(seconds: 58),
          null,
          nativePipeline: true,
        ),
      );
      await stream.close();
      expect(translator.received, isEmpty);
      expect(commits, 1);
      expect(store.primary.snapshot, hasLength(2));
      expect(store.secondary.snapshot, isEmpty);
      expect(store.secondaryPath, isNull);
      expect(store.targetLanguage, isNull);
    });
  }

  test(
    'stop during translation saves successful work without publishing a late batch',
    () async {
      final translator = _Translator()..block = true;
      var cancelled = false;
      var commits = 0;
      final signal = Completer<void>();
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice.automatic(),
        center: ModelCenterService(),
        translator: translator,
        cancelSignal: signal.future,
        checkCancelled: () {
          if (cancelled) throw StateError('stopped');
        },
        onCommitted: (_, _, _) async => commits++,
        onActivity: (_, _) {},
        onFailure: () {},
      );
      await stream.accept(
        StableAsrBatch(
          [cue(1)],
          const Duration(seconds: 30),
          null,
          nativePipeline: true,
        ),
      );
      final stopped = expectLater(stream.drain(), throwsStateError);
      while (translator.pending.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      cancelled = true;
      signal.complete();
      translator.pending.single.complete();
      await stopped;
      await stream.close();
      expect(commits, 0);
      expect(store.primary.snapshot, isEmpty);
      expect(store.secondary.snapshot, isEmpty);
      expect(store.pendingTranslations, {1: '成功译文 1'});
    },
  );

  test(
    'incremental interval coverage equals a fresh resolver including overlaps',
    () {
      final buffer = SubtitleCueBuffer();
      var resolver = SubtitleTimelineResolver(buffer.snapshot);
      for (var i = 1; i <= 100; i++) {
        buffer.addAll([
          cue(i),
          cue(i).copyWith(endTime: Duration(seconds: i * 3 + 4)),
        ]);
        resolver.append(buffer.snapshot);
        final full = SubtitleTimelineResolver(buffer.snapshot);
        for (var ms = i * 3000 - 1000; ms < i * 3000 + 5000; ms += 200) {
          expect(
            resolver.activeIndicesAtMs(ms, extendToNextStart: true),
            full.activeIndicesAtMs(ms, extendToNextStart: true),
          );
        }
      }
    },
  );

  test('streamed lyric projections reuse old rows and stable source IDs', () {
    final primary = SubtitleCueBuffer()..addAll([cue(1)]);
    final secondary = SubtitleCueBuffer()..addAll([cue(1, text: '第一句')]);
    final old = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: primary.snapshot,
      secondary: secondary.snapshot,
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
    );
    primary.addAll([cue(2)]);
    secondary.addAll([cue(2, text: '第二句')]);
    final next = resolveMusicLyricProjection(
      mediaId: 'song',
      primary: primary.snapshot,
      secondary: secondary.snapshot,
      splitSubtitleByLine: false,
      mode: MusicLyricTrackDisplayMode.both,
      previous: old,
    );
    expect(old.rows, hasLength(1));
    expect(next.rows, hasLength(2));
    expect(identical(old.rows.first, next.rows.first), isTrue);
    expect(next.rows.last.groupId, 'p:1');
    expect(next.rows.last.translation, '第二句');
    expect(next.sourceVersion, old.sourceVersion);
  });

  test(
    'natural segmentation holds only the mutable tail and keeps published IDs stable',
    () async {
      final assembler = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.natural,
        version: 2,
      );
      final output = await assembler.add([
        cue(1),
        cue(2),
        cue(3),
      ], stableBefore: const Duration(seconds: 8));
      expect(output, isNotEmpty);
      final prefix = output.map((item) => item.toTimingJson()).toList();
      final tail = await assembler.add(
        [cue(3), cue(4)],
        stableBefore: const Duration(seconds: 30),
        endOfInput: true,
      );
      expect(output.map((item) => item.toTimingJson()).toList(), prefix);
      expect(tail.first.index, output.length + 1);
      expect(
        [...output, ...tail].map((item) => item.index).toList(),
        List.generate(output.length + tail.length, (i) => i + 1),
      );
    },
  );

  test(
    'an ambiguous overlap is resolved before any translation or paired publication',
    () async {
      final translator = _Translator();
      final assembler = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.original,
      );
      final committed = <List<SubtitleItem>>[];
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: const TranscriptTranslateChoice.automatic(),
        center: ModelCenterService(),
        translator: translator,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onCommitted: (_, source, translated) async {
          expect(source.length, translated.length);
          committed.add(source);
        },
        onActivity: (_, _) {},
        onFailure: () {},
      );
      SubtitleItem sentence(int from, int to, String text) => SubtitleItem(
        index: 0,
        startTime: Duration(milliseconds: from),
        endTime: Duration(milliseconds: to),
        text: text,
      );
      try {
        final pending = await assembler.add(
          [sentence(26000, 29400, '咱还能谈谈吗？')],
          stableBefore: const Duration(seconds: 28),
          windowStart: Duration.zero,
          windowEnd: const Duration(seconds: 30),
        );
        expect(pending, isEmpty);
        expect(translator.received, isEmpty);
        expect(store.primary.snapshot, isEmpty);
        final resolved = await assembler.add(
          [sentence(28100, 34000, '看忙，接着说。')],
          stableBefore: const Duration(seconds: 56),
          windowStart: const Duration(seconds: 28),
          windowEnd: const Duration(seconds: 58),
          recognizeBoundary: (_, _) async => [
            sentence(26000, 29400, '咱还能谈谈吗？'),
            sentence(30200, 34000, '接着说。'),
          ],
        );
        await stream.accept(
          StableAsrBatch(resolved, const Duration(seconds: 58), null),
        );
        await stream.drain();
        expect(translator.sourceTexts.single, ['咱还能谈谈吗？', '接着说。']);
        expect(committed.single.map((c) => c.text), ['咱还能谈谈吗？', '接着说。']);
        expect(store.primary.snapshot, hasLength(2));
        expect(store.secondary.snapshot, hasLength(2));
        expect(
          SubtitleTimelineResolver(
            store.primary.snapshot,
          ).activeIndicesAtMs(28900),
          [0],
        );
        expect(
          SubtitleTimelineResolver(
            store.secondary.snapshot,
          ).activeIndicesAtMs(28900),
          [0],
        );
      } finally {
        await stream.close();
      }
    },
  );

  for (final options in [
    SubtitleSegmentationOptions.original,
    SubtitleSegmentationOptions.natural.copyWith(allowEstimatedTiming: true),
    SubtitleSegmentationOptions.short.copyWith(allowEstimatedTiming: true),
  ]) {
    test(
      'stable-prefix output equals full-file merge with ${options.preset} segmentation',
      () async {
        final all = [
          for (var i = 0; i < 37; i++)
            SubtitleItem(
              index: i + 1,
              startTime: Duration(seconds: i * 2),
              endTime: Duration(
                milliseconds: i == 36 ? 73000 : i * 2000 + 1700,
              ),
              text: i % 7 == 0
                  ? '这一段包含中文、多语言和标点，保留字幕的自然边界。'
                  : 'A continuation across the audio boundary ${i % 4 == 0 ? 'ends here.' : 'keeps going'}',
            ),
        ];
        final chunks = [
          all
              .where((cue) => cue.startTime < const Duration(seconds: 30))
              .toList(),
          all
              .where(
                (cue) =>
                    cue.startTime >= const Duration(seconds: 28) &&
                    cue.startTime < const Duration(seconds: 58),
              )
              .toList(),
          all
              .where((cue) => cue.startTime >= const Duration(seconds: 56))
              .toList(),
        ];
        var merged = <SubtitleItem>[];
        for (final chunk in chunks) {
          merged = stitchLocalAsrBoundary(merged, chunk);
        }
        final full = normalizeLocalAsrTimeline(
          options.enabled
              ? await segmentAsrSubtitlesAsync(merged, options)
              : merged,
        );
        final assembler = StreamingSubtitleAssembler(options, version: 2);
        final streamed = <SubtitleItem>[];
        for (var i = 0; i < chunks.length; i++) {
          streamed.addAll(
            await assembler.add(
              chunks[i],
              stableBefore: Duration(seconds: [28, 56, 71][i]),
              endOfInput: i == chunks.length - 1,
            ),
          );
        }
        final baseline = [
          for (var i = 0; i < full.length; i++)
            full[i].copyWith(index: i + 1).toTimingJson(),
        ];
        expect(streamed.map((cue) => cue.toTimingJson()).toList(), baseline);
      },
    );
  }
}
